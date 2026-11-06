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
}

/// Names the playlists and guide sources of a snapshot: the record linked to the row, else a record of another
/// device with the same address (so the same playlist added on two devices becomes one), else a new name.
struct SyncIdentityResolver {
    private(set) var links: SyncLinks
    private var playlistsByURL: [String: String] = [:]
    private var guidesByURL: [String: String] = [:]

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

    mutating func playlistName(localID: UUID, url: URL) -> String {
        if let linked = links.playlistName(forLocalID: localID) {
            return linked
        }
        var name = playlistsByURL[SyncIdentity.normalized(url)] ?? SyncIdentity.playlistName(for: url)
        if links.playlists[name] != nil {
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
        if links.guideSources[name] != nil {
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

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, records, lastSeenLocal, links, lastSyncedOn, unsent
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
    func transportDidFail(_ error: Error)
}

// MARK: - Reconciler

@MainActor
final class CloudSyncReconciler {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "CloudSync")

    let deviceID: String
    private let store: CloudSyncLocalStore
    private let storage: SyncLedgerStorage
    private let clock: () -> Date
    private(set) var ledger: SyncLedger

    /// Records received while a pass runs, merged by the next one.
    private var inbox: [SyncRecord] = []
    private var isRunning = false
    private var needsPass = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The ledger as last written: a pass that changed nothing does not write it again.
    private var savedLedger: SyncLedger?

    /// Called with the IDs of records that changed in the ledger (to send them).
    var onRecordsChanged: (([SyncRecordID]) -> Void)?
    /// Called after every pass.
    var onPassFinished: (() -> Void)?

    init(deviceID: String, store: CloudSyncLocalStore, storage: SyncLedgerStorage, clock: @escaping () -> Date = Date.init) {
        self.deviceID = deviceID
        self.store = store
        self.storage = storage
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
    /// nothing is deleted from the device.
    func resetSyncState() {
        ledger = SyncLedger()
        inbox = []
        storage.save(ledger)
        savedLedger = ledger
    }

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

        // 3. Apply every record the device does not match.
        let pending = ledger.records.values
            .filter { ledger.lastSeenLocal[$0.id.recordName] != $0.payload }
            .sorted { $0.id < $1.id }
        if !pending.isEmpty {
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

    /// Compares the device with `lastSeenLocal` and turns each difference into a record of this device.
    private func foldLocalChanges() -> [SyncRecordID] {
        var identity = SyncIdentityResolver(links: ledger.links, records: ledger.records.values)
        let snapshot: [SyncRecordID: SyncPayload]
        do {
            snapshot = try store.snapshot(identity: &identity)
        } catch {
            Self.logger.error("Could not read the library for sync: \(error.localizedDescription, privacy: .public)")
            return []
        }
        ledger.links = identity.links
        var ids = Set(snapshot.keys)
        for key in ledger.lastSeenLocal.keys {
            if let id = SyncRecordID(recordName: key) {
                ids.insert(id)
            }
        }
        let now = clock().syncRounded
        var changed: [SyncRecordID] = []
        for id in ids.sorted() {
            let key = id.recordName
            let value = snapshot[id]
            let before = ledger.lastSeenLocal[key]
            guard value != before else {
                continue
            }
            let current = ledger.records[key]
            if current?.payload == value {
                // The device reached the synced value on its own (or a deferred record was applied by a refresh).
                ledger.lastSeenLocal[key] = value
                continue
            }
            if value == nil, let playlist = before?.playlistName, !isLivePlaylist(playlist) {
                // A favorite or progress gone with its playlist: the playlist's deletion says it all, and the
                // records stay for the day the playlist comes back.
                ledger.lastSeenLocal[key] = nil
                continue
            }
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
                continue
            }
            ledger.records[key] = record
            changed.append(id)
        }
        return changed
    }

    private func isLivePlaylist(_ name: String) -> Bool {
        guard ledger.links.playlists[name] != nil else {
            return false
        }
        return ledger.records[SyncRecordID(.playlist, name).recordName]?.isDeletion != true
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
