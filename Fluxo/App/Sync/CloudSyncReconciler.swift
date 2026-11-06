//
//  CloudSyncReconciler.swift
//  Fluxo
//
//  The sync algorithm, independent of CloudKit and SwiftData: it compares what the device has now with what it had
//  at the last sync, publishes the differences as records, merges the records other devices published (last writer
//  wins, per record) and applies the winners to the device. The library side is a `CloudSyncLocalStore`, the cloud
//  side a `CloudSyncTransport`; `Tools/SyncCheck` runs it with an in-memory cloud and several simulated devices.
//

import Foundation
import os

/// The device's library, as sync sees it.
@MainActor
protocol CloudSyncLocalStore: AnyObject {
    /// Everything this device syncs, now, by record. Playlists and guide sources are named through `identity`,
    /// which remembers the link between a record and the local row.
    func snapshot(identity: inout SyncIdentityResolver) throws -> [SyncRecordID: SyncPayload]

    /// Makes the device match `records` (sorted: playlists first). Returns the records it could not apply yet: a
    /// favorite whose playlist is not on the device, a playlist waiting for the user's go-ahead. They are tried again
    /// at every sync.
    func apply(_ records: [SyncRecord], links: inout SyncLinks) async -> Set<SyncRecordID>

    /// The deletions the user asked for on this device and that sync has not folded yet: the playlists and guide
    /// sources deleted (local IDs; also a synced row that still exists but can no longer sync), and Clear History.
    /// Only these become deletions on the other devices: an item that is merely gone (a store recreated after it
    /// could not be opened, a migration that lost rows) is kept in iCloud (see `CloudSyncReconciler`).
    func deletionIntents() -> SyncDeletionIntents

    /// Sync folded these intents (or they can never matter again).
    func forgetDeletionIntents(_ intents: SyncDeletionIntents)
}

/// What the user deleted on purpose (`CloudSyncLocalStore.deletionIntents()`).
struct SyncDeletionIntents: Equatable, Sendable {
    /// Playlists and guide sources, by local ID.
    var localIDs: Set<UUID> = []
    /// Clear History was used: the watch history may go everywhere at once.
    var clearedHistory = false

    var isEmpty: Bool {
        localIDs.isEmpty && !clearedHistory
    }
}

/// When favorites or watch history vanish from the device in large numbers at once, without the user saying so
/// (Clear History), the removals are held until the user confirms them: that is what an emptied or damaged store
/// looks like, and publishing it would empty every other device.
struct SyncMassDeletionPolicy: Sendable {
    /// Fewer removals than this in one pass are always published (removing a few favorites in a row).
    var minimumCount = 3
    /// The share of the items of the group (favorites, or history) this device had that makes a mass removal.
    var fraction = 0.5

    func isMass(removed: Int, known: Int) -> Bool {
        removed >= minimumCount && Double(removed) >= Double(max(known, 1)) * fraction
    }
}

/// Names the playlists and guide sources of a snapshot: the record linked to the row, else a record of another
/// device with the same address (so the same playlist added on two devices becomes one), else a new name.
struct SyncIdentityResolver {
    private(set) var links: SyncLinks
    private var playlistsByURL: [String: String] = [:]
    private var guidesByURL: [String: String] = [:]
    /// The local playlists and guide sources that exist now (`setPresent`): a link to a row that is gone does not
    /// keep its record from the row that replaces it (the same playlist added again after the store was recreated).
    private var presentPlaylists: Set<UUID>?
    private var presentGuideSources: Set<UUID>?

    init(links: SyncLinks, records: some Sequence<SyncRecord>) {
        self.links = links
        for record in records {
            switch record.payload {
            case .playlist(let playlist):
                playlistsByURL[SyncIdentity.normalized(playlist.url)] = record.id.name
            case .guideSource(let source):
                guidesByURL[SyncIdentity.normalized(source.url)] = record.id.name
            default:
                break
            }
        }
    }

    /// Says which local rows exist, before the snapshot names them.
    mutating func setPresent(playlists: Set<UUID>, guideSources: Set<UUID>) {
        presentPlaylists = playlists
        presentGuideSources = guideSources
    }

    mutating func playlistName(localID: UUID, url: URL) -> String {
        if let linked = links.playlistName(forLocalID: localID) {
            return linked
        }
        var name = playlistsByURL[SyncIdentity.normalized(url)] ?? SyncIdentity.playlistName(for: url)
        if let other = links.playlists[name], presentPlaylists?.contains(other) ?? true {
            // Another playlist of this device has the same address: a playlist of its own.
            name = SyncIdentity.playlistName(forLocalID: localID)
        }
        links.playlists[name] = localID
        return name
    }

    mutating func guideSourceName(localID: UUID, url: URL) -> String {
        if let linked = links.guideSourceName(forLocalID: localID) {
            return linked
        }
        var name = guidesByURL[SyncIdentity.normalized(url)] ?? SyncIdentity.guideSourceName(for: url)
        if let other = links.guideSources[name], presentGuideSources?.contains(other) ?? true {
            name = "l" + localID.uuidString.lowercased()
        }
        links.guideSources[name] = localID
        return name
    }

    /// The playlist record of a local playlist that is already synced (favorites of other playlists are not).
    func linkedPlaylistName(localID: UUID) -> String? {
        links.playlistName(forLocalID: localID)
    }
}

/// What this device knows of the synced state, kept on disk between launches.
struct SyncLedger: Codable, Equatable {
    static let currentVersion = 1

    var version = SyncLedger.currentVersion
    /// The newest record of every item, from this device or another one, by record name.
    var records: [String: SyncRecord] = [:]
    /// The device's own value of every item when it was last compared, by record name: a difference with the
    /// snapshot is a change made on this device.
    var lastSeenLocal: [String: SyncPayload] = [:]
    var links = SyncLinks()
    var lastSyncedOn: Date?
    /// Records of this device the cloud has not confirmed yet, with the time of the change sent (record name →
    /// `modifiedAt`). Saved with the change itself, so a save the cloud refused for good (iCloud storage full), or a
    /// change queued when the app was quit, is sent again at the next sync instead of being lost.
    var unsent: [String: Date] = [:]
    /// Whether this ledger has read the whole cloud once (a new device, a ledger that was lost or reset, another
    /// account). Until then the device publishes nothing of its own: what it has is first compared with what iCloud
    /// has, so a stale or empty library cannot override or delete what the other devices synced.
    var hasBaseline = false
    /// Playlists and guide sources this device had that are gone without the user deleting them (an empty or
    /// recreated store): they stay in iCloud and on the other devices, and come back here only when the user
    /// restores them (record names).
    var awaitingRestore: Set<String> = []
    /// Favorites and history that vanished in large numbers at once (`SyncMassDeletionPolicy`): not published until
    /// the user confirms the removal or restores them (record names).
    var heldDeletions: Set<String> = []
    /// Whether the device's library was compared with the cloud since the baseline. That first comparison (the
    /// baseline pass) treats what both sides have as iCloud's: the playlists, guides and settings take iCloud's value,
    /// and favorites and history are decided by their own date (`CloudSyncReconciler.foldLocalChanges`).
    var hasMatchedBaseline = false
    /// Playlists and guide sources deleted on another device that this device still had at its baseline pass (it
    /// was away with a lost ledger, or never synced): kept here as rows of this device only, neither deleted here nor
    /// brought back on the others, until the user changes them here (record name → the `modifiedAt` of the deletion
    /// record; a newer record of the item ends it).
    var keptDespiteDeletion: [String: Date] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, records, lastSeenLocal, links, lastSyncedOn, unsent, hasBaseline, awaitingRestore, heldDeletions
        case hasMatchedBaseline, keptDespiteDeletion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        records = try container.decode([String: SyncRecord].self, forKey: .records)
        lastSeenLocal = try container.decode([String: SyncPayload].self, forKey: .lastSeenLocal)
        links = try container.decode(SyncLinks.self, forKey: .links)
        lastSyncedOn = try container.decodeIfPresent(Date.self, forKey: .lastSyncedOn)
        // Ledgers written before it was kept.
        unsent = try container.decodeIfPresent([String: Date].self, forKey: .unsent) ?? [:]
        // Ledgers written before these were kept: one that synced has its baseline.
        hasBaseline = try container.decodeIfPresent(Bool.self, forKey: .hasBaseline) ?? (lastSyncedOn != nil && !records.isEmpty)
        awaitingRestore = try container.decodeIfPresent(Set<String>.self, forKey: .awaitingRestore) ?? []
        heldDeletions = try container.decodeIfPresent(Set<String>.self, forKey: .heldDeletions) ?? []
        hasMatchedBaseline = try container.decodeIfPresent(Bool.self, forKey: .hasMatchedBaseline) ?? hasBaseline
        keptDespiteDeletion = try container.decodeIfPresent([String: Date].self, forKey: .keptDespiteDeletion) ?? [:]
    }
}

/// Reads and writes the ledger (a JSON file; `Tools/SyncCheck` keeps it in memory).
protocol SyncLedgerStorage: AnyObject {
    func load() -> SyncLedger?
    func save(_ ledger: SyncLedger)
    func remove()
}

final class FileSyncLedgerStorage: SyncLedgerStorage {
    private let url: URL
    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "CloudSync")

    init(url: URL) {
        self.url = url
    }

    func load() -> SyncLedger? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            let ledger = try SyncCoding.decoder.decode(SyncLedger.self, from: data)
            return ledger.version == SyncLedger.currentVersion ? ledger : nil
        } catch {
            Self.logger.error("Could not read the sync ledger: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ ledger: SyncLedger) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Complete protection: the ledger holds the playlist addresses, like the library store.
            #if os(macOS)
            try SyncCoding.encoder.encode(ledger).write(to: url, options: .atomic)
            #else
            try SyncCoding.encoder.encode(ledger).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #endif
        } catch {
            Self.logger.error("Could not write the sync ledger: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

final class MemorySyncLedgerStorage: SyncLedgerStorage {
    private(set) var ledger: SyncLedger?
    /// How many times the ledger was written (`Tools/SyncCheck`).
    private(set) var saveCount = 0

    init(_ ledger: SyncLedger? = nil) {
        self.ledger = ledger
    }

    func load() -> SyncLedger? {
        ledger
    }

    func save(_ ledger: SyncLedger) {
        self.ledger = ledger
        saveCount += 1
    }

    func remove() {
        ledger = nil
    }
}

// MARK: - Transport

enum CloudAccountChange: Sendable, Equatable {
    case signedIn
    case signedOut
    /// Another Apple Account: what was synced belongs to the previous one. Also after the account's encryption keys
    /// were reset (the encrypted fields are lost): everything is sent again.
    case switched
    /// The synced data was deleted (Delete iCloud Data on a device, or the iCloud storage settings): sync turns off
    /// on this device, and its library stays as it is.
    case remoteDataDeleted
}

/// The cloud side: CloudKit (`CloudKitSyncTransport`), or a simulated cloud in Debug builds and `Tools/SyncCheck`.
@MainActor
protocol CloudSyncTransport: AnyObject {
    var events: CloudSyncTransportEvents? { get set }
    func start()
    func stop()
    /// These records changed in the ledger: send them (the transport reads them with `transportRecord(for:)` when
    /// it sends, so it always sends the newest value).
    func recordsChanged(_ ids: [SyncRecordID])
    func fetchChanges() async throws
    func sendChanges() async throws
    /// The next fetch reads everything the cloud has, not only what changed since the last one (a ledger that is
    /// new, lost or reset; Restore from iCloud). Pending sends may be dropped: the reconciler queues its unsent
    /// records again at every sync. Returns once a fetch made after it reads from the start.
    func forgetFetchPosition() async
    /// Deletes everything this app stored in the user's iCloud (Settings › iCloud › Delete iCloud Data). Works
    /// whether or not the transport is started, and never fetches or applies anything; throws unless the cloud
    /// confirmed the deletion.
    func deleteAllRemoteData() async throws
}

@MainActor
protocol CloudSyncTransportEvents: AnyObject {
    func transportRecord(for id: SyncRecordID) -> SyncRecord?
    func transportDidFetch(_ records: [SyncRecord]) async
    func transportAccountDidChange(_ change: CloudAccountChange) async
    /// The cloud saved these records (record ID → the `modifiedAt` of the version saved); empty after a fetch.
    func transportDidSend(_ sent: [SyncRecordID: Date])
    /// A fetch read everything up to now (after its `transportDidFetch`).
    func transportDidFinishFetching() async
    func transportDidFail(_ error: Error)
}

// MARK: - Reconciler

/// Compares, merges and applies (see the file comment), with these safeguards against losing the library:
/// - A device publishes and applies nothing before it has read the whole cloud once (`SyncLedger.hasBaseline`): a
///   new device, a lost or reset ledger, another account. Then what it has is matched with what iCloud has (the
///   baseline pass): iCloud's playlists, guides and settings win over the device's copy, favorites and history are
///   decided by their own date, and a playlist deleted elsewhere is neither deleted here nor brought back there.
/// - Only a deletion the user asked for on this device (`CloudSyncLocalStore.deletionIntents()`) deletes a playlist
///   or guide source on the other devices. One that is merely gone (an empty or recreated store, a migration that
///   lost rows) stays in iCloud and waits for the user to restore it (`SyncLedger.awaitingRestore`).
/// - Favorites and history that vanish in large numbers at once are held until the user confirms the removal
///   (`SyncMassDeletionPolicy`, `SyncLedger.heldDeletions`); Clear History is the user saying so.
/// - Deletions are published only for records this device knew (`lastSeenLocal`), never for ones it never had.
@MainActor
final class CloudSyncReconciler {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "CloudSync")

    let deviceID: String
    private let store: CloudSyncLocalStore
    private let storage: SyncLedgerStorage
    private let clock: () -> Date
    private let policy: SyncMassDeletionPolicy
    private(set) var ledger: SyncLedger

    /// Records received while a pass runs, merged by the next one.
    private var inbox: [SyncRecord] = []
    private var isRunning = false
    private var needsPass = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The ledger as last written: a pass that changed nothing does not write it again.
    private var savedLedger: SyncLedger?
    /// Held removals the user confirmed: the next pass publishes them.
    private var confirmedHeldDeletions: Set<String> = []
    /// The next pass publishes the kept items again (`syncKeptAgain`).
    private var republishesKept = false

    /// Called with the IDs of records that changed in the ledger (to send them).
    var onRecordsChanged: (([SyncRecordID]) -> Void)?
    /// Called after every pass.
    var onPassFinished: (() -> Void)?

    init(deviceID: String, store: CloudSyncLocalStore, storage: SyncLedgerStorage, policy: SyncMassDeletionPolicy = SyncMassDeletionPolicy(), clock: @escaping () -> Date = Date.init) {
        self.deviceID = deviceID
        self.store = store
        self.storage = storage
        self.policy = policy
        self.clock = clock
        ledger = storage.load() ?? SyncLedger()
        savedLedger = ledger
    }

    // MARK: Queries

    func record(for id: SyncRecordID) -> SyncRecord? {
        ledger.records[id.recordName]
    }

    /// Every record that is not a deletion.
    func liveRecords(of kind: SyncKind) -> [SyncRecord] {
        ledger.records.values.filter { $0.id.kind == kind && !$0.isDeletion }.sorted { $0.id < $1.id }
    }

    /// Records of this device the cloud has not confirmed (to send again at each sync until it does).
    var unsentRecordIDs: [SyncRecordID] {
        ledger.unsent.keys.compactMap { key -> SyncRecordID? in
            guard ledger.records[key]?.deviceID == deviceID else {
                return nil
            }
            return SyncRecordID(recordName: key)
        }
        .sorted()
    }

    /// Records the device does not match yet (deferred), by kind.
    func pendingRecords(of kind: SyncKind) -> [SyncRecord] {
        ledger.records.values
            .filter { $0.id.kind == kind && ledger.lastSeenLocal[$0.id.recordName] != $0.payload }
            .sorted { $0.id < $1.id }
    }

    /// The whole cloud was not read yet: the next fetch must read everything (`CloudSyncTransport.forgetFetchPosition`).
    var needsBaseline: Bool {
        !ledger.hasBaseline
    }

    /// Playlists and guide sources this device lost (not deleted by the user) that iCloud still has.
    var recordsAwaitingRestore: [SyncRecord] {
        ledger.awaitingRestore.compactMap { ledger.records[$0] }.filter { !$0.isDeletion }.sorted { $0.id < $1.id }
    }

    /// Favorites and history removed in large numbers at once, waiting for the user's confirmation.
    var heldDeletionIDs: [SyncRecordID] {
        ledger.heldDeletions.compactMap(SyncRecordID.init(recordName:)).sorted()
    }

    /// Playlists and guide sources deleted on another device that this device kept (`SyncLedger.keptDespiteDeletion`):
    /// on this device only, with what is added to them here, until the user syncs them again (`syncKeptAgain`).
    var keptDespiteDeletionIDs: [SyncRecordID] {
        ledger.keptDespiteDeletion.keys.compactMap(SyncRecordID.init(recordName:)).sorted()
    }

    // MARK: Passes

    /// Something changed on the device (a save of the library, a setting): publish what differs.
    func localStateMayHaveChanged() async {
        await runPass()
    }

    /// Records fetched from the cloud (or the server's copy after a conflict).
    func receive(_ records: [SyncRecord]) async {
        inbox.append(contentsOf: records)
        await runPass()
    }

    /// A fetch finished: the first one gives the ledger its baseline, and the device's own changes are compared.
    func fetchDidFinish() async {
        guard !ledger.hasBaseline else {
            return
        }
        ledger.hasBaseline = true
        await runPass()
    }

    /// The cloud saved these records (record ID → the `modifiedAt` it saved): they are no longer sent again.
    func recordsSent(_ sent: [SyncRecordID: Date]) {
        var changed = false
        for (id, modifiedAt) in sent {
            let key = id.recordName
            if let queued = ledger.unsent[key], modifiedAt >= queued {
                ledger.unsent[key] = nil
                changed = true
            }
        }
        if changed {
            storage.save(ledger)
            savedLedger = ledger
        }
    }

    /// Forgets what was synced (another Apple Account): every item of the device is published again as new, and
    /// nothing is deleted from the device. Nothing is published before the cloud was read again.
    func resetSyncState() {
        ledger = SyncLedger()
        inbox = []
        confirmedHeldDeletions = []
        storage.save(ledger)
        savedLedger = ledger
    }

    // MARK: Recovery

    /// Brings back what is awaiting restore: these playlists (nil: all of them) and every guide source. They are
    /// added through the store (`CloudSyncLocalStore.apply`), with their favorites and history.
    func restore(playlists names: Set<String>? = nil) async {
        let released = ledger.awaitingRestore.filter { key in
            guard let names, let id = SyncRecordID(recordName: key), id.kind == .playlist else {
                return true
            }
            return names.contains(id.name)
        }
        ledger.awaitingRestore.subtract(released)
        await runPass()
    }

    /// The held removals were not meant: the favorites and history come back from iCloud.
    func restoreHeldDeletions() async {
        for key in ledger.heldDeletions {
            ledger.lastSeenLocal[key] = nil
        }
        ledger.heldDeletions = []
        await runPass()
    }

    /// The user confirmed the held removals: they are published to the other devices.
    func confirmHeldDeletions() async {
        confirmedHeldDeletions = ledger.heldDeletions
        await runPass()
    }

    /// Settings › iCloud › Kept on This Device: the playlists and guides kept despite their deletion elsewhere are
    /// published again, as the newer action, so they come back on the other devices with their favorites and history.
    func syncKeptAgain() async {
        republishesKept = true
        await runPass()
    }

    /// Restore from iCloud: after the user's own changes are folded, every item this device had and no longer has
    /// is taken from iCloud again (the favorites, history and settings at once; the playlists and guide sources wait
    /// in `awaitingRestore` for the user to pick them). Held removals are restored too.
    func prepareFullRestore() async {
        await runPass()
        var identity = SyncIdentityResolver(links: ledger.links, records: ledger.records.values)
        let snapshot: [SyncRecordID: SyncPayload]
        do {
            snapshot = try store.snapshot(identity: &identity)
        } catch {
            Self.logger.error("Could not read the library to restore it: \(error.localizedDescription, privacy: .public)")
            return
        }
        ledger.links = identity.links
        for key in Array(ledger.lastSeenLocal.keys) {
            guard let id = SyncRecordID(recordName: key), snapshot[id] == nil, ledger.records[key]?.isDeletion == false else {
                continue
            }
            ledger.lastSeenLocal[key] = nil
            if id.kind == .playlist || id.kind == .guideSource {
                unlink(id)
                ledger.awaitingRestore.insert(key)
            }
        }
        ledger.heldDeletions = []
        await runPass()
    }

    // MARK: The pass

    /// Runs one pass, or waits for the running one and runs another (passes never overlap: applying is async).
    private func runPass() async {
        if isRunning {
            needsPass = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isRunning = true
        repeat {
            needsPass = false
            await pass()
        } while needsPass
        isRunning = false
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter.resume()
        }
        onPassFinished?()
    }

    private func pass() async {
        var changed: [SyncRecordID] = []
        // 1. What changed on the device since the last pass becomes a record of this device.
        changed += foldLocalChanges()

        // 2. Records of other devices: keep the newer of each.
        let received = inbox
        inbox = []
        for remote in received {
            let key = remote.id.recordName
            if let current = ledger.records[key] {
                if remote == current {
                    continue
                }
                if !remote.supersedes(current) {
                    // Ours is newer (an edit not sent yet, or a conflict the server reported): send it again.
                    changed.append(current.id)
                    continue
                }
            }
            ledger.records[key] = remote
            // Another device's newer change replaces ours: nothing of ours is left to send.
            ledger.unsent[key] = nil
        }

        // 3. Apply every record the device does not match (except what waits for the user to restore it, and a
        // deletion this device declined at its baseline). Nothing before the baseline: the device's own values are
        // compared with the whole cloud first (`foldLocalChanges`), so a newer watch position here is not
        // overwritten by an older one that happened to sync first.
        let pending = ledger.records.values
            .filter { record in
                let key = record.id.recordName
                return ledger.lastSeenLocal[key] != record.payload && !ledger.awaitingRestore.contains(key)
                    && !(record.isDeletion && ledger.keptDespiteDeletion[key] == record.modifiedAt)
            }
            .sorted { $0.id < $1.id }
        if ledger.hasBaseline, !pending.isEmpty {
            var links = ledger.links
            let deferred = await store.apply(pending, links: &links)
            ledger.links = links
            // What the device has now, for the next comparison (the store may have normalized a value).
            var identity = SyncIdentityResolver(links: ledger.links, records: ledger.records.values)
            if let snapshot = try? store.snapshot(identity: &identity) {
                ledger.links = identity.links
                for record in pending where !deferred.contains(record.id) {
                    ledger.lastSeenLocal[record.id.recordName] = snapshot[record.id]
                }
            }
        }

        let toSend = Array(Set(changed)).sorted()
        for id in toSend {
            if let record = ledger.records[id.recordName], record.deviceID == deviceID {
                ledger.unsent[id.recordName] = record.modifiedAt
            }
        }
        ledger.lastSyncedOn = clock()
        // Written only when the pass changed something (besides the time): passes are frequent, the ledger is not
        // small. The change and its place in `unsent` are written together, before they are handed to the cloud.
        var comparable = ledger
        comparable.lastSyncedOn = savedLedger?.lastSyncedOn
        if comparable != savedLedger {
            storage.save(ledger)
            savedLedger = ledger
        }
        if !toSend.isEmpty {
            onRecordsChanged?(toSend)
        }
    }

    /// Compares the device with `lastSeenLocal` and turns each difference into a record of this device, except
    /// what the safeguards keep back (see the class comment).
    private func foldLocalChanges() -> [SyncRecordID] {
        guard ledger.hasBaseline else {
            // Nothing of this device is published before it knows what the cloud has.
            return []
        }
        let previousLinks = ledger.links
        var identity = SyncIdentityResolver(links: ledger.links, records: ledger.records.values)
        let snapshot: [SyncRecordID: SyncPayload]
        do {
            snapshot = try store.snapshot(identity: &identity)
        } catch {
            Self.logger.error("Could not read the library for sync: \(error.localizedDescription, privacy: .public)")
            return []
        }
        ledger.links = identity.links
        let intents = store.deletionIntents()
        // The first comparison since the baseline: what the device has and has never compared is matched with iCloud.
        let isBaselinePass = !ledger.hasMatchedBaseline
        // A newer record of a kept item (added again elsewhere, deleted again) ends the exception.
        ledger.keptDespiteDeletion = ledger.keptDespiteDeletion.filter { key, deletedOn in
            ledger.records[key].map { $0.isDeletion && $0.modifiedAt == deletedOn } ?? false
        }
        if republishesKept {
            // As if this device had never compared them: still here, they are published below (newer than the
            // deletion), and their favorites and history after them.
            republishesKept = false
            for key in ledger.keptDespiteDeletion.keys {
                ledger.lastSeenLocal[key] = nil
            }
            ledger.keptDespiteDeletion = [:]
        }
        var ids = Set(snapshot.keys)
        for key in ledger.lastSeenLocal.keys {
            if let id = SyncRecordID(recordName: key) {
                ids.insert(id)
            }
        }
        let now = clock().syncRounded
        var changed: [SyncRecordID] = []
        let sorted = ids.sorted()
        var lost = 0

        // Playlists and guide sources first: whether one is gone decides what its favorites do.
        for id in sorted where id.kind.isContainer {
            let key = id.recordName
            let value = snapshot[id]
            if value != nil {
                // On the device again (added back by the user with the same address, or restored).
                ledger.awaitingRestore.remove(key)
            }
            let before = ledger.lastSeenLocal[key]
            guard value != before else {
                continue
            }
            // Changed here: no longer kept back (an edit publishes it, a deletion or a loss is handled below).
            ledger.keptDespiteDeletion[key] = nil
            let current = ledger.records[key]
            if current?.payload == value {
                // The device reached the synced value on its own (or a deferred record was applied by a refresh).
                ledger.lastSeenLocal[key] = value
                continue
            }
            if isBaselinePass, before == nil, let current, let value {
                if !current.isDeletion {
                    // Both sides have it: iCloud's name, address and state win over the copy of a device that was
                    // away or never synced (applied in this pass), so it overrides no rename made elsewhere.
                    continue
                }
                if Self.creationDate(of: value).map({ $0 <= current.modifiedAt }) ?? true {
                    // Deleted on another device, but this device had it (its ledger was lost, or it never synced):
                    // kept here, and not brought back on the others, until the user changes it here.
                    ledger.lastSeenLocal[key] = value
                    ledger.keptDespiteDeletion[key] = current.modifiedAt
                    continue
                }
                // Added here after it was deleted elsewhere: the newer action, published below.
            }
            if value == nil {
                let localID = id.kind == .playlist ? previousLinks.playlists[id.name] : previousLinks.guideSources[id.name]
                if localID.map({ !intents.localIDs.contains($0) }) ?? true {
                    // Gone, but not deleted by the user: the store was emptied or recreated. iCloud and the other
                    // devices keep it; it comes back here when the user restores it.
                    ledger.lastSeenLocal[key] = nil
                    unlink(id)
                    if current?.isDeletion == false {
                        ledger.awaitingRestore.insert(key)
                    }
                    lost += 1
                    continue
                }
            }
            if publish(id, value: value, before: before, now: now) {
                changed.append(id)
            }
        }
        if lost > 0 {
            Self.logger.notice("\(lost, privacy: .public) synced playlists or guides are gone without being deleted: kept in iCloud for a restore")
        }
        // Playlists whose record now stands for another local row (the same playlist added again after the store
        // was lost): the favorites and history of the old row are not removals, they come back to the new one.
        let relinked = Set(previousLinks.playlists.compactMap { name, localID in
            ledger.links.playlists[name].flatMap { $0 != localID ? name : nil }
        })

        // Mass removals of favorites or history (of playlists still on the device).
        var removedFavorites = 0
        var knownFavorites = 0
        var removedHistory = 0
        var knownHistory = 0
        for (key, before) in ledger.lastSeenLocal {
            guard let id = SyncRecordID(recordName: key), id.kind.isFavorite || id.kind.isHistory else {
                continue
            }
            let isRemoval = snapshot[id] == nil && ledger.records[key]?.payload != nil
                && before.playlistName.map { isLivePlaylist($0) && !relinked.contains($0) } == true
            if id.kind.isFavorite {
                knownFavorites += 1
                removedFavorites += isRemoval ? 1 : 0
            } else {
                knownHistory += 1
                removedHistory += isRemoval ? 1 : 0
            }
        }
        let holdsFavorites = policy.isMass(removed: removedFavorites, known: knownFavorites)
        let holdsHistory = !intents.clearedHistory && policy.isMass(removed: removedHistory, known: knownHistory)

        for id in sorted where !id.kind.isContainer {
            let key = id.recordName
            let value = snapshot[id]
            if value != nil {
                ledger.heldDeletions.remove(key)
            }
            let before = ledger.lastSeenLocal[key]
            guard value != before else {
                continue
            }
            let current = ledger.records[key]
            if current?.payload == value {
                ledger.lastSeenLocal[key] = value
                ledger.heldDeletions.remove(key)
                continue
            }
            if before == nil, let playlist = value?.playlistName,
               ledger.keptDespiteDeletion[SyncRecordID(.playlist, playlist).recordName] != nil {
                // A favorite or progress of a playlist kept despite its deletion elsewhere: not published while the
                // playlist is not (compared again when it is).
                continue
            }
            if isBaselinePass, before == nil, current != nil, Self.naturalDate(of: value) == nil {
                // A setting (or an item without a date) both sides have: iCloud's value wins, applied in this pass.
                continue
            }
            if value == nil, let playlist = before?.playlistName, !isLivePlaylist(playlist) || relinked.contains(playlist) {
                // A favorite or progress gone with its playlist: the playlist's deletion says it all (or the
                // playlist waits for a restore, or was added again), and the records stay for the day the playlist
                // comes back.
                ledger.lastSeenLocal[key] = nil
                ledger.heldDeletions.remove(key)
                continue
            }
            if value == nil, (id.kind.isFavorite && holdsFavorites) || (id.kind.isHistory && holdsHistory),
               !confirmedHeldDeletions.contains(key) {
                // Kept back until the user confirms (`lastSeenLocal` keeps the item, so it is compared again).
                ledger.heldDeletions.insert(key)
                continue
            }
            ledger.heldDeletions.remove(key)
            if publish(id, value: value, before: before, now: now) {
                changed.append(id)
            }
        }
        confirmedHeldDeletions = []
        ledger.hasMatchedBaseline = true

        // The intents are folded, except deletions still running (their row is still in the snapshot).
        var present: Set<UUID> = []
        for id in snapshot.keys where id.kind.isContainer {
            if let localID = id.kind == .playlist ? ledger.links.playlists[id.name] : ledger.links.guideSources[id.name] {
                present.insert(localID)
            }
        }
        if !intents.isEmpty {
            store.forgetDeletionIntents(SyncDeletionIntents(localIDs: intents.localIDs.subtracting(present), clearedHistory: intents.clearedHistory))
        }
        return changed
    }

    /// Turns the device's value of `id` into a record of this device (false: another device's newer record wins).
    private func publish(_ id: SyncRecordID, value: SyncPayload?, before: SyncPayload?, now: Date) -> Bool {
        let key = id.recordName
        let current = ledger.records[key]
        var modifiedAt = now
        if before == nil, let natural = Self.naturalDate(of: value) {
            // An item this device never compared (new, or there before sync was on): its own date decides, so a
            // movie watched last week on the iPhone does not override the same movie watched yesterday on the iPad
            // when sync turns on, whichever device syncs first.
            modifiedAt = min(now, natural)
        }
        if let current, modifiedAt <= current.modifiedAt, before != nil || Self.naturalDate(of: value) == nil {
            // An edit made after the device received `current` always wins over it, whatever the clocks say.
            modifiedAt = Date(syncMilliseconds: current.modifiedAt.syncMilliseconds + 1)
        }
        let record = SyncRecord(id: id, payload: value, modifiedAt: modifiedAt, deviceID: deviceID)
        ledger.lastSeenLocal[key] = value
        if let current, !record.supersedes(current) {
            // Older than what another device synced: that one is applied in this pass.
            return false
        }
        ledger.records[key] = record
        return true
    }

    private func unlink(_ id: SyncRecordID) {
        switch id.kind {
        case .playlist: ledger.links.playlists[id.name] = nil
        case .guideSource: ledger.links.guideSources[id.name] = nil
        default: break
        }
    }

    private func isLivePlaylist(_ name: String) -> Bool {
        guard ledger.links.playlists[name] != nil else {
            return false
        }
        return ledger.records[SyncRecordID(.playlist, name).recordName]?.isDeletion != true
    }

    /// When a playlist or a guide source was added (on the device that added it first).
    private static func creationDate(of payload: SyncPayload) -> Date? {
        switch payload {
        case .playlist(let value): value.createdOn
        case .guideSource(let value): value.addedOn
        default: nil
        }
    }

    /// When a favorite was added or an item was last watched.
    private static func naturalDate(of payload: SyncPayload?) -> Date? {
        switch payload {
        case .channelFavorite(let value): value.favoritedOn
        case .channelProgress(let value): value.lastWatchedAt
        case .seriesFavorite(let value): value.favoritedOn
        case .seriesProgress(let value): value.lastWatchedAt
        default: nil
        }
    }
}

private extension SyncKind {
    /// Playlists and guide sources: rows of their own, deleted only on the user's word.
    var isContainer: Bool {
        self == .playlist || self == .guideSource
    }

    var isFavorite: Bool {
        self == .channelFavorite || self == .seriesFavorite
    }

    var isHistory: Bool {
        self == .channelProgress || self == .seriesProgress
    }
}
