//
//  main.swift
//  SyncCheck
//
//  Scenarios of iCloud sync between simulated devices: the app's reconciler and records, a `FakeLibrary` per
//  device, and one simulated cloud (`MemoryCloudBackend`) that refuses stale saves like CloudKit does.
//
//  This file has the devices and the checks; the scenarios are in ConvergenceScenarios.swift,
//  DataSafetyScenarios.swift and HistoryRemovalScenarios.swift.
//

import Foundation

/// The journal's default defaults: never used here (every fake library passes its own).
extension UserDefaults {
    static var fluxo: UserDefaults {
        fatalError("SyncCheck passes the defaults of each fake library")
    }
}

/// A manual clock per device (devices may disagree on the time).
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var skew: TimeInterval = 0

    func advance(_ seconds: TimeInterval = 1) {
        now = now.addingTimeInterval(seconds)
    }
}

let world = TestClock()

@MainActor
final class Device {
    let label: String
    let library: FakeLibrary
    let transport: SimulatedCloudTransport
    let storage = MemorySyncLedgerStorage()
    private(set) var reconciler: CloudSyncReconciler
    private var events: Events!
    var skew: TimeInterval = 0
    /// Records this device sent, in total.
    var sentCount = 0

    init(_ label: String, cloud: MemoryCloudBackend) {
        self.label = label
        let clock = { world.now }
        library = FakeLibrary(label: label, clock: clock)
        transport = SimulatedCloudTransport(backend: cloud)
        reconciler = CloudSyncReconciler(deviceID: label, store: library, storage: storage, clock: clock)
        connect()
        transport.start()
    }

    private func connect() {
        let skewed = { [unowned self] in world.now.addingTimeInterval(self.skew) }
        library.clock = skewed
        reconciler = CloudSyncReconciler(deviceID: label, store: library, storage: storage, clock: skewed)
        events = Events(device: self)
        transport.events = events
        reconciler.onRecordsChanged = { [unowned self] ids in
            self.transport.recordsChanged(ids)
        }
    }

    /// The app relaunched: a new reconciler reads the saved ledger (as `CloudSync.startTransport` does, a new or
    /// lost ledger makes the next fetch read everything).
    func relaunch() async {
        connect()
        if reconciler.needsBaseline {
            await transport.forgetFetchPosition()
        }
    }

    /// The ledger file was lost or could not be read (the library stays); the app relaunches.
    func loseLedger() async {
        storage.remove()
        await relaunch()
    }

    /// One sync: compare the library, queue again what the cloud never confirmed, send, fetch (what `CloudSync`
    /// and CKSyncEngine do when the app comes to the foreground).
    func sync() async {
        await reconciler.localStateMayHaveChanged()
        transport.recordsChanged(reconciler.unsentRecordIDs)
        try? await transport.sendChanges()
        try? await transport.fetchChanges()
    }

    @MainActor
    final class Events: CloudSyncTransportEvents {
        unowned let device: Device

        init(device: Device) {
            self.device = device
        }

        func transportRecord(for id: SyncRecordID) -> SyncRecord? {
            device.reconciler.record(for: id)
        }

        func transportDidFetch(_ records: [SyncRecord]) async {
            await device.reconciler.receive(records)
        }

        func transportAccountDidChange(_ change: CloudAccountChange) async {
            device.reconciler.resetSyncState()
        }

        func transportDidSend(_ sent: [SyncRecordID: Date]) {
            device.sentCount += sent.count
            device.reconciler.recordsSent(sent)
        }

        func transportDidFinishFetching() async {
            await device.reconciler.fetchDidFinish()
        }

        func transportDidFail(_ error: Error) {}
    }
}

var failures = 0
var passes = 0

@MainActor
func check(_ condition: Bool, _ message: String) {
    if condition {
        passes += 1
    } else {
        failures += 1
        print("    FAIL: \(message)")
    }
}

@MainActor
func scenario(_ title: String, _ body: () async -> Void) async {
    let before = failures
    await body()
    print("\(failures == before ? "PASS" : "FAIL")  \(title)")
}

/// Syncs every device until nothing changes (at most 6 rounds), as devices do over time.
@MainActor
func settle(_ devices: [Device]) async {
    for _ in 0..<6 {
        world.advance()
        for device in devices {
            await device.sync()
        }
    }
}

@MainActor
func converged(_ devices: [Device]) -> Bool {
    let states = devices.map(\.library.comparable)
    return Set(states).count == 1
}

@MainActor
func run() async {
    await runConvergenceScenarios()
    await runDataSafetyScenarios()
    await runHistoryRemovalScenarios()
}

await run()
FakeLibrary.removeDefaults()
print("\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
