//
//  CloudKitSyncTransport.swift
//  Fluxo
//
//  iCloud sync through CloudKit: the user's private database, one zone ("Fluxo"), one record per synced item, sent
//  and fetched by `CKSyncEngine` (batching, retries, push notifications, account changes). The item itself (the
//  playlist address, names, logos: everything that can carry account credentials) is a JSON blob in an encrypted
//  field (`CKRecord.encryptedValues`): encrypted on the device before it is sent, and end-to-end encrypted when the
//  user turns on Advanced Data Protection. Only the time of the change, the device ID and a deletion flag are plain
//  fields.
//
//  `CKContainer` traps when the app is not signed with the CloudKit entitlement, so `CloudSync` creates this
//  transport only when the build says it has it (`FluxoCloudKitContainer` in Info.plist; see "iCloud sync" in the
//  README).
//

import CloudKit
import Foundation
import os

@MainActor
final class CloudKitSyncTransport: CloudSyncTransport, nonisolated CKSyncEngineDelegate {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "CloudSync")

    static let zoneName = "Fluxo"

    private enum Field {
        static let payload = "payload"
        static let modifiedAt = "modifiedAt"
        static let deviceID = "deviceID"
        static let deleted = "deleted"
    }

    /// What survives a relaunch: the engine's state and the server's system fields of every record (its change
    /// tag), so the next save of a record is not refused as a conflict.
    private struct PersistedState: Codable {
        var engineState: CKSyncEngine.State.Serialization?
        var systemFields: [String: Data] = [:]
        var zoneSaved = false
        /// The iCloud user the synced state belongs to (the record name of the user record), to tell signing back
        /// in to the same account from signing in to another one.
        var userRecordName: String?
    }

    /// Delete iCloud Data did not complete.
    struct ZoneDeletionError: LocalizedError {
        var underlying: (any Error)?

        var errorDescription: String? {
            underlying?.localizedDescription
                ?? String(localized: "iCloud did not confirm the deletion. Check your connection and try again.", comment: "Delete iCloud Data failed: the server did not confirm that the data was deleted.")
        }
    }

    weak var events: (any CloudSyncTransportEvents)?

    private let container: CKContainer
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitSyncTransport.zoneName, ownerName: CKCurrentUserDefaultName)
    private let stateURL: URL
    private var state: PersistedState
    /// The one engine that syncs. CloudKit forbids two engines on the same database in production
    /// (`CKSyncEngine.Configuration.database`), so an engine is created only once the previous one was detached and
    /// its operations cancelled (`lifecycle`).
    private var engine: CKSyncEngine?
    /// The engine Delete iCloud Data creates while sync is off (it only sends).
    private var deletionEngine: CKSyncEngine?
    /// Start, stop, forgetting the fetch position and Delete iCloud Data, one after the other in the order they were
    /// asked for: each waits for the previous one, so a new engine never runs next to one still cancelling.
    private let lifecycle = SerialTaskQueue()
    /// Records changed while a step had no engine to give them to (between stopping one engine and creating the
    /// next): given to the engine that step creates.
    private var waitingRecordIDs: [SyncRecordID] = []
    /// The fetch running now could not read the zone: it does not complete the reconciler's baseline.
    private var zoneFetchFailed = false
    /// Fetches the current engine finished (`didFetchChanges`), and whether the last one read the zone without an
    /// error: `fetchChanges()` completes the baseline only after a fetch it saw finish that way.
    private var finishedFetches = 0
    private var lastFetchReadZone = false
    /// The outcome of the zone deletion Delete iCloud Data asked for (set by the `sentDatabaseChanges` event).
    private var zoneDeletion: Result<Void, any Error>?

    init(containerIdentifier: String, directory: URL) {
        container = CKContainer(identifier: containerIdentifier)
        stateURL = directory.appendingPathComponent("cloudkit-state.json")
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = saved
        } else {
            state = PersistedState()
        }
    }

    // MARK: - CloudSyncTransport

    func start() {
        lifecycle.enqueue { [self] in
            guard engine == nil else {
                return
            }
            installEngine()
        }
    }

    /// Creates the engine that syncs, and gives it the records changed while there was none.
    private func installEngine() {
        engine = makeEngine(automaticallySyncs: true)
        let waiting = waitingRecordIDs
        waitingRecordIDs = []
        recordsChanged(waiting)
    }

    private func makeEngine(automaticallySyncs: Bool) -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: state.engineState,
            delegate: self
        )
        configuration.automaticallySync = automaticallySyncs
        return CKSyncEngine(configuration)
    }

    func stop() {
        lifecycle.enqueue { [self] in
            await retireEngine()
            // Sent at the next sync, by the reconciler (they are still unsent there).
            waitingRecordIDs = []
        }
    }

    /// Detaches the engine (its late events are ignored, see `isCurrent`) and waits until its operations are
    /// cancelled. Returns whether there was one.
    @discardableResult
    private func retireEngine() async -> Bool {
        guard let retired = engine else {
            return false
        }
        engine = nil
        finishedFetches = 0
        lastFetchReadZone = false
        await retired.cancelOperations()
        return true
    }

    func recordsChanged(_ ids: [SyncRecordID]) {
        guard !ids.isEmpty else {
            return
        }
        guard let engine else {
            if lifecycle.pendingCount > 0 {
                waitingRecordIDs.append(contentsOf: ids)
            }
            return
        }
        if !state.zoneSaved {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(recordID(for: $0)) })
    }

    func fetchChanges() async throws {
        // A send or fetch asked for after Turn On (or Restore) uses the new engine.
        await lifecycle.settled()
        guard let engine else {
            return
        }
        let finishedBefore = finishedFetches
        // Throws when the fetch failed at the database level: `didFetchChanges` has no error to tell it, so only a
        // fetch that returns here (and read the zone without an error) gives the reconciler its baseline. One that
        // the engine skipped (no account) finishes no fetch, and does not count either.
        try await engine.fetchChanges()
        if engine === self.engine, finishedFetches > finishedBefore, lastFetchReadZone {
            await events?.transportDidFinishFetching()
        }
    }

    func sendChanges() async throws {
        // A send or fetch asked for after Turn On (or Restore) uses the new engine.
        await lifecycle.settled()
        try await engine?.sendChanges()
    }

    func forgetFetchPosition() async {
        await lifecycle.enqueue { [self] in
            // An engine created without a state serialization fetches the zone from the start. The running one is
            // detached and cancelled first (never two engines at once); its state is cleared only after, so a late
            // state update of it cannot bring the old position back. The system fields (change tags) stay, so the
            // next saves are not refused as conflicts.
            let wasRunning = await retireEngine()
            state.engineState = nil
            persist()
            if wasRunning {
                installEngine()
            }
        }.value
    }

    func deleteAllRemoteData() async throws {
        let outcome = await lifecycle.enqueue { [self] () async -> Result<Void, any Error> in
            // With sync off there is no engine: one that only sends (it never fetches, so nothing of the cloud is
            // applied to the device on the way), cancelled before the next lifecycle step can create another.
            if let engine {
                return await deleteZoneResult(with: engine)
            }
            let temporary = makeEngine(automaticallySyncs: false)
            deletionEngine = temporary
            let result = await deleteZoneResult(with: temporary)
            deletionEngine = nil
            await temporary.cancelOperations()
            return result
        }.value
        try outcome.get()
    }

    private func deleteZoneResult(with engine: CKSyncEngine) async -> Result<Void, any Error> {
        do {
            try await deleteZone(with: engine)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func deleteZone(with engine: CKSyncEngine) async throws {
        // Pending saves would create the zone again.
        waitingRecordIDs = []
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
        zoneDeletion = nil
        do {
            try await engine.sendChanges()
        } catch {
            engine.state.remove(pendingDatabaseChanges: [.deleteZone(zoneID)])
            throw error
        }
        let outcome = zoneDeletion
        zoneDeletion = nil
        switch outcome {
        case .success:
            break
        case .failure(let error):
            throw ZoneDeletionError(underlying: error)
        case nil:
            // Not sent (offline, or the account is not available): a deletion left pending would run later, maybe
            // after the user uploaded their library again.
            engine.state.remove(pendingDatabaseChanges: [.deleteZone(zoneID)])
            throw ZoneDeletionError()
        }
        state.systemFields = [:]
        state.zoneSaved = false
        persist()
    }

    /// Whether the device has an iCloud account CloudKit can use.
    func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    // MARK: - CKSyncEngineDelegate

    /// Whether events of this engine are applied: an engine stopped or replaced may still deliver some (its
    /// cancellation is asynchronous).
    private func isCurrent(_ syncEngine: CKSyncEngine) -> Bool {
        syncEngine === engine || syncEngine === deletionEngine
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard isCurrent(syncEngine) else {
            if case .sentRecordZoneChanges(let sent) = event {
                // A send that completed after the engine was cancelled: what the server now has is still true, so
                // keep its change tags (the next save of these records would be refused as a conflict otherwise).
                // Retries, its state and everything else belong to the current engine.
                keepSystemFields(of: sent)
            }
            return
        }
        switch event {
        case .stateUpdate(let update):
            state.engineState = update.stateSerialization
            persist()

        case .accountChange(let change):
            switch change.changeType {
            case .signIn(let currentUser):
                // Signing out and in again to the same account keeps what was synced; another account starts over.
                let previous = state.userRecordName
                state.userRecordName = currentUser.recordName
                if let previous, previous != currentUser.recordName {
                    resetServerState()
                    await events?.transportAccountDidChange(.switched)
                } else {
                    persist()
                    await events?.transportAccountDidChange(.signedIn)
                }
            case .signOut(let previousUser):
                state.userRecordName = previousUser.recordName
                persist()
                await events?.transportAccountDidChange(.signedOut)
            case .switchAccounts(_, let currentUser):
                state.userRecordName = currentUser.recordName
                resetServerState()
                await events?.transportAccountDidChange(.switched)
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == zoneID {
                // Deleted with Delete iCloud Data on a device, or from the iCloud storage settings; or reset with the
                // account's encryption keys (the encrypted fields are lost: send everything again).
                resetServerState()
                await events?.transportAccountDidChange(deletion.reason == .encryptedDataReset ? .switched : .remoteDataDeleted)
            }

        case .fetchedRecordZoneChanges(let changes):
            var records: [SyncRecord] = []
            for modification in changes.modifications {
                if let record = syncRecord(from: modification.record) {
                    records.append(record)
                }
            }
            persist()
            if !records.isEmpty {
                await events?.transportDidFetch(records)
            }

        case .sentDatabaseChanges(let sent):
            if sent.savedZones.contains(where: { $0.zoneID == zoneID }) {
                state.zoneSaved = true
                persist()
            }
            for failure in sent.failedZoneSaves {
                Self.logger.error("Could not create the sync zone: \(failure.error.localizedDescription, privacy: .public)")
                events?.transportDidFail(failure.error)
            }
            if sent.deletedZoneIDs.contains(zoneID) {
                zoneDeletion = .success(())
            } else if let error = sent.failedZoneDeletes[zoneID] {
                Self.logger.error("Could not delete the sync zone: \(error.localizedDescription, privacy: .public)")
                zoneDeletion = .failure(error)
            }

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                state.systemFields[record.recordID.recordName] = Self.encodeSystemFields(of: record)
            }
            var conflicts: [SyncRecord] = []
            var retry: [CKRecord.ID] = []
            // Changes the engine dropped stay in the reconciler's `unsent` list, and are queued again at the next
            // sync (the app coming to the foreground, Sync Now, signing in).
            for failure in sent.failedRecordSaves {
                let recordName = failure.record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    // Another device saved it first: keep the server's change tag, and let the reconciler decide
                    // which version wins (it sends ours again when it is newer).
                    if let server = failure.error.serverRecord, let record = syncRecord(from: server) {
                        conflicts.append(record)
                    }
                case .zoneNotFound, .userDeletedZone:
                    state.zoneSaved = false
                    state.systemFields[recordName] = nil
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    retry.append(failure.record.recordID)
                case .unknownItem:
                    // The change tag refers to a record that is gone: save it as new.
                    state.systemFields[recordName] = nil
                    retry.append(failure.record.recordID)
                case .batchRequestFailed:
                    // Refused only because another record of its batch was: send it again now.
                    retry.append(failure.record.recordID)
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                     .requestRateLimited, .accountTemporarilyUnavailable:
                    // Retried by the engine (CKSyncEngine.h, "Error Handling"): it keeps the change pending.
                    break
                case .operationCancelled:
                    // Sync was turned off or the app is quitting: sent again at the next sync.
                    break
                case .quotaExceeded:
                    Self.logger.error("Could not save a sync record: iCloud storage is full")
                    events?.transportDidFail(QuotaExceededError())
                default:
                    Self.logger.error("Could not save a sync record: \(failure.error.localizedDescription, privacy: .public)")
                    events?.transportDidFail(failure.error)
                }
            }
            if !retry.isEmpty {
                syncEngine.state.add(pendingRecordZoneChanges: retry.map { .saveRecord($0) })
            }
            persist()
            var saved: [SyncRecordID: Date] = [:]
            for record in sent.savedRecords {
                if let id = SyncRecordID(recordName: record.recordID.recordName), let modifiedAt = record[Field.modifiedAt] as? Date {
                    saved[id] = modifiedAt.syncRounded
                }
            }
            if !saved.isEmpty {
                events?.transportDidSend(saved)
            }
            if !conflicts.isEmpty {
                await events?.transportDidFetch(conflicts)
            }

        case .willFetchChanges:
            zoneFetchFailed = false

        case .didFetchRecordZoneChanges(let fetched):
            if fetched.zoneID == zoneID, let error = fetched.error {
                Self.logger.error("Could not fetch the sync zone: \(error.localizedDescription, privacy: .public)")
                zoneFetchFailed = true
            }

        case .didFetchChanges:
            finishedFetches += 1
            lastFetchReadZone = !zoneFetchFailed
            events?.transportDidSend([:])

        case .willFetchRecordZoneChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard isCurrent(syncEngine) else {
            // Stopped or replaced while it was cancelling: only the current engine sends (the reconciler queues its
            // unsent records again).
            return nil
        }
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else {
            return nil
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            await self?.ckRecord(for: recordID, engine: syncEngine)
        }
    }

    /// iCloud storage is full: the changes wait until the user frees space (they are sent at the next sync).
    struct QuotaExceededError: LocalizedError {
        var errorDescription: String? {
            String(localized: "Your iCloud storage is full. Changes on this device are sent once there is space.", comment: "Settings › iCloud status: the iCloud account has no storage left, so changes cannot be synced.")
        }
    }

    // MARK: - Records

    private func recordID(for id: SyncRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.recordName, zoneID: zoneID)
    }

    /// The record to send, built from the reconciler's newest value and the server's last system fields.
    private func ckRecord(for recordID: CKRecord.ID, engine: CKSyncEngine) -> CKRecord? {
        guard let id = SyncRecordID(recordName: recordID.recordName), let value = events?.transportRecord(for: id) else {
            // Nothing to send any more.
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        let record = state.systemFields[recordID.recordName].flatMap(Self.decodeRecord(systemFields:))
            ?? CKRecord(recordType: id.kind.recordType, recordID: recordID)
        do {
            record.encryptedValues[Field.payload] = try value.encodedPayload() as NSData
        } catch {
            Self.logger.error("Could not encode a sync record: \(error.localizedDescription, privacy: .public)")
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        record[Field.modifiedAt] = value.modifiedAt as NSDate
        record[Field.deviceID] = value.deviceID as NSString
        record[Field.deleted] = NSNumber(value: value.isDeletion ? 1 : 0)
        return record
    }

    private func syncRecord(from record: CKRecord) -> SyncRecord? {
        guard record.recordID.zoneID == zoneID, let id = SyncRecordID(recordName: record.recordID.recordName) else {
            return nil
        }
        state.systemFields[record.recordID.recordName] = Self.encodeSystemFields(of: record)
        guard let modifiedAt = record[Field.modifiedAt] as? Date, let deviceID = record[Field.deviceID] as? String else {
            return nil
        }
        let payload: SyncPayload?
        if (record[Field.deleted] as? NSNumber)?.intValue == 1 {
            payload = nil
        } else {
            guard let data = record.encryptedValues[Field.payload] as? Data else {
                return nil
            }
            do {
                payload = try SyncRecord.decodePayload(data)
            } catch {
                // A newer version of the app wrote it: leave it alone.
                Self.logger.notice("Skipped a sync record this version cannot read: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard payload == nil || payload?.kind == id.kind else {
            return nil
        }
        return SyncRecord(id: id, payload: payload, modifiedAt: modifiedAt.syncRounded, deviceID: deviceID)
    }

    /// The change tags of a send of an engine no longer current (see `handleEvent`).
    private func keepSystemFields(of sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        var saved: [SyncRecordID: Date] = [:]
        for record in sent.savedRecords where record.recordID.zoneID == zoneID {
            state.systemFields[record.recordID.recordName] = Self.encodeSystemFields(of: record)
            if let id = SyncRecordID(recordName: record.recordID.recordName), let modifiedAt = record[Field.modifiedAt] as? Date {
                saved[id] = modifiedAt.syncRounded
            }
        }
        for failure in sent.failedRecordSaves where failure.error.code == .serverRecordChanged {
            if let server = failure.error.serverRecord, server.recordID.zoneID == zoneID {
                state.systemFields[server.recordID.recordName] = Self.encodeSystemFields(of: server)
            }
        }
        persist()
        if !saved.isEmpty {
            events?.transportDidSend(saved)
        }
    }

    private func resetServerState() {
        state.systemFields = [:]
        state.zoneSaved = false
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Self.logger.error("Could not save the sync engine state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func encodeSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func decodeRecord(systemFields: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }
}
