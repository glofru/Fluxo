//
//  SimulatedCloud.swift
//  Fluxo
//
//  A stand-in for CloudKit, for `Tools/SyncCheck` and Debug builds (`-FluxoDebugCloud`): the "server" keeps the
//  newest record of each item and refuses an older one the way CloudKit refuses a stale change tag (the device gets
//  the server's copy back and merges it). It lives in memory, or in a folder of JSON files that several simulators
//  share (they run on the same Mac), so two clones can sync with each other without an iCloud account.
//

#if DEBUG
import Foundation

/// The server side.
@MainActor
protocol SimulatedCloudBackend: AnyObject {
    /// Every record with its sequence number (increasing with each accepted save).
    func records(after sequence: Int) -> (records: [SyncRecord], sequence: Int)
    /// Stores `record` unless the server has a newer one, which it returns instead.
    func save(_ record: SyncRecord) -> SyncRecord?
    func removeAll()
}

@MainActor
final class MemoryCloudBackend: SimulatedCloudBackend {
    private var stored: [String: (record: SyncRecord, sequence: Int)] = [:]
    private var sequence = 0

    init() {}

    var allRecords: [SyncRecord] {
        stored.values.map(\.record).sorted { $0.id < $1.id }
    }

    func records(after sequence: Int) -> (records: [SyncRecord], sequence: Int) {
        let changed = stored.values.filter { $0.sequence > sequence }.sorted { $0.sequence < $1.sequence }.map(\.record)
        return (changed, self.sequence)
    }

    func save(_ record: SyncRecord) -> SyncRecord? {
        if let current = stored[record.id.recordName]?.record, current != record, !record.supersedes(current) {
            return current
        }
        sequence += 1
        stored[record.id.recordName] = (record, sequence)
        return nil
    }

    func removeAll() {
        stored = [:]
        sequence += 1
    }
}

/// One JSON file per record in a folder (`<folder>/<record name>.json`); the sequence is the file's modification
/// time in milliseconds.
@MainActor
final class DirectoryCloudBackend: SimulatedCloudBackend {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func records(after sequence: Int) -> (records: [SyncRecord], sequence: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var newest = sequence
        var records: [SyncRecord] = []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let fileSequence = Int(modified.timeIntervalSince1970 * 1_000)
            guard fileSequence >= sequence, let data = try? Data(contentsOf: file), let record = try? SyncCoding.decoder.decode(SyncRecord.self, from: data) else {
                continue
            }
            newest = max(newest, fileSequence)
            records.append(record)
        }
        return (records.sorted { $0.id < $1.id }, newest)
    }

    func save(_ record: SyncRecord) -> SyncRecord? {
        let file = directory.appendingPathComponent(record.id.recordName + ".json")
        if let data = try? Data(contentsOf: file), let current = try? SyncCoding.decoder.decode(SyncRecord.self, from: data), current != record, !record.supersedes(current) {
            return current
        }
        try? SyncCoding.encoder.encode(record).write(to: file, options: .atomic)
        return nil
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// A device's connection to the simulated server. `sendChanges()` and `fetchChanges()` do what CKSyncEngine does
/// when it syncs; with `automaticallySyncs`, a change is sent at once and the server is polled while the app runs.
@MainActor
final class SimulatedCloudTransport: CloudSyncTransport {
    weak var events: CloudSyncTransportEvents?

    let backend: SimulatedCloudBackend
    private var pending: Set<SyncRecordID> = []
    private var sequence = 0
    private var isStarted = false
    private let automaticallySyncs: Bool
    private var pollTask: Task<Void, Never>?
    /// Off: the device is offline (changes wait).
    var isOnline = true
    /// The server refuses every save with an error the engine does not retry (CloudKit's `quotaExceeded`: iCloud
    /// storage is full): the changes are dropped from the queue, as CKSyncEngine drops them.
    var rejectsSaves = false

    /// Simulated error of a refused save.
    struct RejectedSave: LocalizedError {
        var errorDescription: String? {
            "iCloud storage is full (simulated)."
        }
    }

    init(backend: SimulatedCloudBackend, automaticallySyncs: Bool = false) {
        self.backend = backend
        self.automaticallySyncs = automaticallySyncs
    }

    func start() {
        isStarted = true
        guard automaticallySyncs, pollTask == nil else {
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await self?.fetchChanges()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        isStarted = false
        pollTask?.cancel()
        pollTask = nil
    }

    func recordsChanged(_ ids: [SyncRecordID]) {
        pending.formUnion(ids)
        if automaticallySyncs {
            Task { [weak self] in
                try? await self?.sendChanges()
            }
        }
    }

    /// The app was quit before the engine saved its queue: the changes queued since are forgotten.
    func dropPendingChanges() {
        pending = []
    }

    func fetchChanges() async throws {
        guard isStarted, isOnline else {
            return
        }
        let (records, sequence) = backend.records(after: sequence)
        self.sequence = sequence
        if !records.isEmpty {
            await events?.transportDidFetch(records)
        }
        events?.transportDidSend([:])
    }

    func sendChanges() async throws {
        guard isStarted, isOnline, !pending.isEmpty else {
            return
        }
        let ids = pending.sorted()
        pending = []
        if rejectsSaves {
            events?.transportDidFail(RejectedSave())
            return
        }
        var conflicts: [SyncRecord] = []
        var sent: [SyncRecordID: Date] = [:]
        for id in ids {
            guard let record = events?.transportRecord(for: id) else {
                continue
            }
            if let newer = backend.save(record) {
                conflicts.append(newer)
            } else {
                sent[id] = record.modifiedAt
            }
        }
        events?.transportDidSend(sent)
        if !conflicts.isEmpty {
            await events?.transportDidFetch(conflicts)
        }
    }

    func deleteAllRemoteData() async throws {
        guard isOnline else {
            throw URLError(.notConnectedToInternet)
        }
        pending = []
        backend.removeAll()
    }
}
#endif
