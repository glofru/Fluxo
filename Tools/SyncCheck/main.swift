//
//  main.swift
//  SyncCheck
//
//  Scenarios of iCloud sync between simulated devices: the app's reconciler and records, a `FakeLibrary` per
//  device, and one simulated cloud (`MemoryCloudBackend`) that refuses stale saves like CloudKit does.
//

import Foundation

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

    /// The app relaunched: a new reconciler reads the saved ledger.
    func relaunch() {
        connect()
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
    await scenario("A playlist added on the iPhone reaches a new Apple TV after the user adds it, with its favorites and progress") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        tv.library.acceptsCloudPlaylists = false
        let living = phone.library.addPlaylist("Living Room", "https://provider.example/get.php?username=me&password=secret")
        phone.library.favorite("Rai 1", in: living)
        phone.library.watch("Movie", in: living, position: 1_200, duration: 6_000)
        phone.library.preferences["player.skipForwardSeconds"] = .int(15)
        await settle([phone, tv])
        check(tv.library.playlists.isEmpty, "the TV waits for the user before adding playlists")
        check(tv.library.preferences["player.skipForwardSeconds"] == .int(15), "settings are applied at once")
        let offered = tv.reconciler.pendingRecords(of: .playlist).compactMap { record -> String? in
            if case .playlist(let playlist) = record.payload { return playlist.name }
            return nil
        }
        check(offered == ["Living Room"], "the TV offers the iPhone's playlist (offered: \(offered))")
        tv.library.acceptsCloudPlaylists = true
        await settle([phone, tv])
        let tvLiving = tv.library.playlist(named: "Living Room")
        check(tvLiving != nil, "the TV added the playlist")
        check(tv.library.bookmark("Rai 1", in: tvLiving)?.isFavorite == true, "the favorite came along")
        check(tv.library.bookmark("Movie", in: tvLiving)?.resumePosition == 1_200, "the resume position came along")
        check(converged([phone, tv]), "both devices agree")
        let recordNames = cloud.allRecords.map(\.id.name).joined()
        check(!recordNames.contains("secret") && !recordNames.contains("provider"), "record names never contain the address")
    }

    await scenario("Renames, address changes and settings made on either device converge; an edited address keeps the playlist") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let mac = Device("mac", cloud: cloud)
        let id = phone.library.addPlaylist("Sports", "https://sports.example/list.m3u")
        await settle([phone, mac])
        let macID = mac.library.playlist(named: "Sports")
        check(macID != nil, "the Mac has the playlist")
        if let macID {
            mac.library.playlists[macID]?.name = "Sports HD"
        }
        await settle([phone, mac])
        check(phone.library.playlists[id]?.name == "Sports HD", "the rename reached the iPhone")
        phone.library.playlists[id]?.url = URL(string: "https://sports.example/new-token/list.m3u")!
        await settle([phone, mac])
        check(mac.library.playlists.count == 1, "no duplicate after the address changed (\(mac.library.playlists.count) playlists)")
        check(macID.flatMap { mac.library.playlists[$0]?.url.absoluteString } == "https://sports.example/new-token/list.m3u", "the Mac updated the address of the same playlist")
        check(cloud.allRecords.filter { $0.id.kind == .playlist }.count == 1, "one playlist record in the cloud")
        check(converged([phone, mac]), "both devices agree")
    }

    await scenario("The same playlist added on two devices before sync becomes one") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let ipad = Device("ipad", cloud: cloud)
        phone.library.addPlaylist("Family", "HTTPS://Family.Example/tv.m3u")
        world.advance(60)
        ipad.library.addPlaylist("Family TV", "https://family.example/tv.m3u")
        await settle([phone, ipad])
        check(phone.library.playlists.count == 1 && ipad.library.playlists.count == 1, "one playlist each (\(phone.library.playlists.count), \(ipad.library.playlists.count))")
        check(converged([phone, ipad]), "both devices agree on its name")
    }

    await scenario("A favorite added on the iPhone and a movie watched on the TV at the same time both survive") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let phoneID = phone.library.addPlaylist("Cinema", "https://cinema.example/vod.m3u")
        await settle([phone, tv])
        let tvID = tv.library.playlist(named: "Cinema")!
        tv.library.finishImports()
        phone.library.favorite("Dune", in: phoneID)
        tv.library.watch("Dune", in: tvID, position: 3_000, duration: 9_000)
        await settle([phone, tv])
        check(phone.library.bookmark("Dune", in: phoneID)?.resumePosition == 3_000, "the iPhone got the TV's position")
        check(tv.library.bookmark("Dune", in: tvID)?.isFavorite == true, "the TV got the iPhone's favorite")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("Offline edits of the same playlist: the later one wins on every device") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let mac = Device("mac", cloud: cloud)
        let phoneID = phone.library.addPlaylist("News", "https://news.example/a.m3u")
        await settle([phone, mac])
        let macID = mac.library.playlist(named: "News")!
        phone.transport.isOnline = false
        mac.transport.isOnline = false
        phone.library.playlists[phoneID]?.name = "News (phone)"
        await phone.sync()
        world.advance(30)
        mac.library.playlists[macID]?.name = "News (mac)"
        await mac.sync()
        // The iPhone comes online first, so the Mac's later change meets a server that has the iPhone's.
        phone.transport.isOnline = true
        await phone.sync()
        mac.transport.isOnline = true
        await settle([phone, mac])
        check(phone.library.playlists[phoneID]?.name == "News (mac)", "the later rename won (\(phone.library.playlists[phoneID]?.name ?? "-"))")
        check(converged([phone, mac]), "both devices agree")
    }

    await scenario("A change made after receiving a newer one wins, even with a device clock an hour behind") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        tv.skew = -3_600
        let phoneID = phone.library.addPlaylist("Kids", "https://kids.example/k.m3u")
        await settle([phone, tv])
        let tvID = tv.library.playlist(named: "Kids")!
        tv.library.playlists[tvID]?.name = "Kids Corner"
        await settle([phone, tv])
        check(phone.library.playlists[phoneID]?.name == "Kids Corner", "the TV's rename won despite its clock")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("Deleting a playlist deletes it everywhere with its favorites, without a deletion record per favorite") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Old", "https://old.example/o.m3u")
        for channel in ["A", "B", "C", "D"] {
            phone.library.favorite(channel, in: id)
            phone.library.watch(channel, in: id, position: 100, duration: 1_000)
        }
        await settle([phone, tv])
        check(tv.library.bookmarks.count == 4, "the TV has the 4 bookmarks")
        let before = cloud.allRecords.count
        phone.library.deletePlaylist(id)
        await settle([phone, tv])
        check(tv.library.playlists.isEmpty && tv.library.bookmarks.isEmpty, "the TV deleted the playlist and its bookmarks")
        let deletions = cloud.allRecords.filter(\.isDeletion)
        check(deletions.count == 1 && deletions.first?.id.kind == .playlist, "one deletion record (\(deletions.map(\.id.kind.rawValue)))")
        check(cloud.allRecords.count == before, "no new records")
        // An older device that comes back later does not bring it back.
        let ipad = Device("ipad", cloud: cloud)
        await settle([phone, tv, ipad])
        check(ipad.library.playlists.isEmpty, "a new device does not get the deleted playlist")
        check(converged([phone, tv, ipad]), "every device agrees")
    }

    await scenario("Favorites removed and history cleared on one device are removed on the others") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Live", "https://live.example/l.m3u")
        phone.library.favorite("BBC One", in: id)
        phone.library.favorite("CNN", in: id)
        await settle([phone, tv])
        let tvID = tv.library.playlist(named: "Live")!
        tv.library.unfavorite("CNN", in: tvID)
        await settle([phone, tv])
        check(phone.library.bookmark("CNN", in: id) == nil, "CNN is no longer a favorite on the iPhone")
        check(phone.library.bookmark("BBC One", in: id)?.isFavorite == true, "BBC One still is")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("A guide added on the Mac reaches the TV; turning it off on the TV reaches the Mac") {
        let cloud = MemoryCloudBackend()
        let mac = Device("mac", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let guideID = UUID()
        mac.library.guides[guideID] = FakeLibrary.Guide(name: "Italy", url: URL(string: "https://epg.example/it.xml.gz")!, isEnabled: true, addedOn: world.now.syncRounded)
        await settle([mac, tv])
        check(tv.library.guides.count == 1, "the TV has the guide")
        if let tvGuide = tv.library.guides.keys.first {
            tv.library.guides[tvGuide]?.isEnabled = false
        }
        await settle([mac, tv])
        check(mac.library.guides[guideID]?.isEnabled == false, "the Mac turned it off too")
        check(converged([mac, tv]), "both devices agree")
    }

    await scenario("Turning sync on with history on both devices: the item's own watch date decides") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let ipad = Device("ipad", cloud: cloud)
        let phoneID = phone.library.addPlaylist("Films", "https://films.example/f.m3u")
        let ipadID = ipad.library.addPlaylist("Films", "https://films.example/f.m3u")
        // Watched on the iPad yesterday, on the iPhone a week ago; the iPhone syncs last.
        world.advance(-86_400 * 7)
        phone.library.watch("Heat", in: phoneID, position: 600, duration: 10_000)
        world.advance(86_400 * 6)
        ipad.library.watch("Heat", in: ipadID, position: 4_000, duration: 10_000)
        world.advance(86_400)
        await ipad.sync()
        world.advance()
        await phone.sync()
        await settle([phone, ipad])
        check(phone.library.bookmark("Heat", in: phoneID)?.resumePosition == 4_000, "the iPad's newer position won (\(phone.library.bookmark("Heat", in: phoneID)?.resumePosition ?? -1))")
        check(converged([phone, ipad]), "both devices agree")
    }

    await scenario("A relaunch sends nothing, and idle syncs change nothing") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Stable", "https://stable.example/s.m3u")
        phone.library.favorite("One", in: id)
        phone.library.watch("Two", in: id, position: 31.5, duration: 1_000.25)
        phone.library.preferences["player.subtitleMode"] = .string("on")
        await settle([phone, tv])
        let records = cloud.allRecords
        phone.relaunch()
        tv.relaunch()
        let sentBefore = phone.sentCount + tv.sentCount
        await settle([phone, tv])
        check(phone.sentCount + tv.sentCount == sentBefore, "nothing was sent again (\(phone.sentCount + tv.sentCount - sentBefore) records)")
        check(cloud.allRecords == records, "the cloud is unchanged")
        check(phone.reconciler.unsentRecordIDs.isEmpty && tv.reconciler.unsentRecordIDs.isEmpty, "nothing is left to send")
        let writes = phone.storage.saveCount + tv.storage.saveCount
        await settle([phone, tv])
        check(phone.storage.saveCount + tv.storage.saveCount == writes, "idle passes do not write the ledger (\(phone.storage.saveCount + tv.storage.saveCount - writes) writes)")
    }

    await scenario("A save the cloud refuses for good (iCloud storage full) reaches the other devices once there is space") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        phone.transport.rejectsSaves = true
        let id = phone.library.addPlaylist("Quota", "https://quota.example/q.m3u")
        phone.library.favorite("Channel", in: id)
        await settle([phone, tv])
        check(cloud.allRecords.isEmpty, "the cloud refused the saves (\(cloud.allRecords.count) records)")
        check(tv.library.playlists.isEmpty, "the TV has nothing yet")
        check(phone.reconciler.unsentRecordIDs.count == 2, "the iPhone keeps the playlist and the favorite to send (\(phone.reconciler.unsentRecordIDs.count))")
        // The user frees space; nothing changes on the iPhone, it only comes to the foreground again.
        phone.transport.rejectsSaves = false
        await settle([phone, tv])
        let tvID = tv.library.playlist(named: "Quota")
        check(tvID != nil, "the TV got the playlist")
        check(tv.library.bookmark("Channel", in: tvID)?.isFavorite == true, "and its favorite")
        check(phone.reconciler.unsentRecordIDs.isEmpty, "nothing is left to send")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("A change queued just before the app was quit is sent at the next launch") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let mac = Device("mac", cloud: cloud)
        let id = phone.library.addPlaylist("Late", "https://late.example/l.m3u")
        await settle([phone, mac])
        phone.library.playlists[id]?.name = "Late Night"
        // The pass recorded the rename; the app was quit before the engine saved its queue.
        await phone.reconciler.localStateMayHaveChanged()
        phone.transport.dropPendingChanges()
        phone.relaunch()
        await settle([phone, mac])
        check(mac.library.playlist(named: "Late Night") != nil, "the Mac got the rename")
        check(converged([phone, mac]), "both devices agree")
    }

    await scenario("A refused change that another device overrides meanwhile is not sent again") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let ipad = Device("ipad", cloud: cloud)
        let id = phone.library.addPlaylist("Shared List", "https://shared-list.example/s.m3u")
        await settle([phone, ipad])
        let ipadID = ipad.library.playlist(named: "Shared List")!
        phone.transport.rejectsSaves = true
        phone.library.playlists[id]?.name = "Phone Name"
        await phone.sync()
        world.advance(60)
        ipad.library.playlists[ipadID]?.name = "iPad Name"
        await ipad.sync()
        phone.transport.rejectsSaves = false
        await settle([phone, ipad])
        check(phone.library.playlists[id]?.name == "iPad Name", "the later rename won (\(phone.library.playlists[id]?.name ?? "-"))")
        check(phone.reconciler.unsentRecordIDs.isEmpty, "the overridden change was dropped")
        check(converged([phone, ipad]), "both devices agree")
    }

    await scenario("Another Apple Account: the library is sent to it again and nothing is deleted on the device") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let id = phone.library.addPlaylist("Mine", "https://mine.example/m.m3u")
        phone.library.favorite("X", in: id)
        await settle([phone])
        let otherAccount = MemoryCloudBackend()
        let moved = Device("iphone", cloud: otherAccount)
        moved.library.playlists = phone.library.playlists
        moved.library.bookmarks = phone.library.bookmarks
        moved.reconciler.resetSyncState()
        await settle([moved])
        check(moved.library.playlists.count == 1 && moved.library.bookmarks.count == 1, "the library is intact")
        check(otherAccount.allRecords.filter { !$0.isDeletion }.count == 2, "the new account got the playlist and the favorite")
    }

    await scenario("Three devices, many random edits, eventually agree") {
        let cloud = MemoryCloudBackend()
        let devices = [Device("iphone", cloud: cloud), Device("mac", cloud: cloud), Device("appletv", cloud: cloud)]
        let first = devices[0].library.addPlaylist("Shared", "https://shared.example/s.m3u")
        _ = first
        await settle(devices)
        var generator = SystemRandomNumberGenerator()
        for step in 0..<200 {
            let device = devices[Int.random(in: 0..<devices.count, using: &generator)]
            guard let playlist = device.library.playlist(named: "Shared") ?? device.library.playlists.keys.first else {
                continue
            }
            let channel = "C\(Int.random(in: 0..<6, using: &generator))"
            switch Int.random(in: 0..<5, using: &generator) {
            case 0: device.library.favorite(channel, in: playlist)
            case 1: device.library.unfavorite(channel, in: playlist)
            case 2: device.library.watch(channel, in: playlist, position: Double(step * 10), duration: 9_000)
            case 3: device.library.preferences["player.skipBackwardSeconds"] = .int([5, 10, 15][step % 3])
            default: device.library.playlists[playlist]?.name = "Shared \(step % 4)"
            }
            world.advance(Double.random(in: 0.5...20, using: &generator))
            if Bool.random(using: &generator) {
                await device.sync()
            }
        }
        await settle(devices)
        check(converged(devices), "every device agrees")
    }
}

await run()
print("\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
