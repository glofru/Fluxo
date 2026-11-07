//
//  main.swift
//  SyncCheck
//
//  Scenarios of iCloud sync between simulated devices: the app's reconciler and records, a `FakeLibrary` per
//  device, and one simulated cloud (`MemoryCloudBackend`) that refuses stale saves like CloudKit does.
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
        await phone.relaunch()
        await tv.relaunch()
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
        await phone.relaunch()
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

    // MARK: Data safety: an empty, recreated or stale library never empties the other devices.

    await scenario("A recreated (empty) store on the Apple TV deletes nothing anywhere, and Restore brings everything back") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let living = phone.library.addPlaylist("Living Room", "https://provider.example/get.php?username=me&password=secret")
        let sports = phone.library.addPlaylist("Sports", "https://sports.example/s.m3u")
        phone.library.favorite("Rai 1", in: living)
        phone.library.favorite("ESPN", in: sports)
        phone.library.watch("Movie", in: living, position: 1_200, duration: 6_000)
        phone.library.guides[UUID()] = FakeLibrary.Guide(name: "Italy", url: URL(string: "https://epg.example/it.xml.gz")!, isEnabled: true, addedOn: world.now.syncRounded)
        await settle([phone, tv])
        tv.library.finishImports()
        check(tv.library.playlists.count == 2 && tv.library.favoriteCount == 2 && tv.library.guides.count == 1, "the TV has the library")
        tv.library.loseEverything()
        await settle([phone, tv])
        let deletions = cloud.allRecords.filter(\.isDeletion)
        check(deletions.isEmpty, "no deletion reached the cloud (\(deletions.map(\.id.kind.rawValue)))")
        check(phone.library.playlists.count == 2 && phone.library.favoriteCount == 2 && phone.library.historyCount == 1 && phone.library.guides.count == 1, "the iPhone keeps its playlists, favorites, history and guide")
        check(tv.library.playlists.isEmpty && tv.library.guides.isEmpty, "the TV does not add them back on its own")
        check(tv.reconciler.recordsAwaitingRestore.count == 3, "the TV offers the 2 playlists and the guide for a restore (\(tv.reconciler.recordsAwaitingRestore.count))")
        await tv.reconciler.restore()
        await settle([phone, tv])
        tv.library.finishImports()
        await settle([phone, tv])
        let tvLiving = tv.library.playlist(named: "Living Room")
        check(tv.library.playlists.count == 2 && tv.library.guides.count == 1, "the TV restored the playlists and the guide")
        check(tv.library.bookmark("Rai 1", in: tvLiving)?.isFavorite == true && tv.library.bookmark("Movie", in: tvLiving)?.resumePosition == 1_200, "with their favorites and history")
        check(tv.reconciler.recordsAwaitingRestore.isEmpty, "nothing is left to restore")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("A store recreated at launch with an unsent rename: the rename is still sent, and nothing is deleted") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Movies", "https://movies.example/m.m3u")
        phone.library.favorite("Film", in: id)
        await settle([phone, tv])
        let tvID = tv.library.playlist(named: "Movies")!
        tv.library.finishImports()
        tv.transport.isOnline = false
        tv.library.playlists[tvID]?.name = "Movies HD"
        await tv.sync()
        // The store fails to open at the next launch and is recreated empty; the ledger stays.
        tv.library.loseEverything()
        await tv.relaunch()
        tv.transport.isOnline = true
        await settle([phone, tv])
        check(phone.library.playlists[id]?.name == "Movies HD", "the iPhone got the rename made before the store was lost (\(phone.library.playlists[id]?.name ?? "-"))")
        check(phone.library.bookmark("Film", in: id)?.isFavorite == true, "and keeps the favorite")
        check(cloud.allRecords.filter(\.isDeletion).isEmpty, "no deletion reached the cloud")
        check(tv.reconciler.recordsAwaitingRestore.count == 1, "the TV offers the playlist for a restore")
    }

    await scenario("A lost ledger (library kept): the device reads iCloud first, so its stale copy overrides and deletes nothing") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("News", "https://news.example/n.m3u")
        phone.library.favorite("BBC", in: id)
        phone.library.favorite("CNN", in: id)
        await settle([phone, tv])
        tv.library.finishImports()
        // While the TV is away, the iPhone renames the playlist and removes a favorite.
        phone.library.playlists[id]?.name = "News HD"
        phone.library.unfavorite("CNN", in: id)
        await settle([phone])
        world.advance(60)
        await tv.loseLedger()
        let sentBefore = tv.sentCount
        await settle([phone, tv])
        let tvID = tv.library.playlist(named: "News HD")
        check(tvID != nil, "the TV took the iPhone's rename (\(tv.library.playlists.values.map(\.name)))")
        check(phone.library.playlists[id]?.name == "News HD", "the TV's old name did not override the iPhone's")
        check(tv.library.bookmark("CNN", in: tvID) == nil && tv.library.bookmark("BBC", in: tvID)?.isFavorite == true, "the TV applied the removed favorite and kept the other")
        check(phone.library.bookmark("BBC", in: id)?.isFavorite == true, "the iPhone keeps BBC")
        check(tv.sentCount == sentBefore, "the TV sent nothing of its stale copy (\(tv.sentCount - sentBefore) records)")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("Turning sync on with history on both devices, the older device first: the item's own watch date still decides") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let ipad = Device("ipad", cloud: cloud)
        let phoneID = phone.library.addPlaylist("Films", "https://films.example/f.m3u")
        let ipadID = ipad.library.addPlaylist("Films", "https://films.example/f.m3u")
        // Watched on the iPhone a week ago, on the iPad yesterday; this time the iPhone syncs and publishes first.
        world.advance(-86_400 * 7)
        phone.library.watch("Heat", in: phoneID, position: 600, duration: 10_000)
        world.advance(86_400 * 6)
        ipad.library.watch("Heat", in: ipadID, position: 4_000, duration: 10_000)
        ipad.library.favorite("Ran", in: ipadID)
        world.advance(86_400)
        phone.library.preferences["player.skipForwardSeconds"] = .int(30)
        ipad.library.preferences["player.skipForwardSeconds"] = .int(10)
        await settle([phone])
        let published = cloud.allRecords.contains { record in
            if case .channelProgress(let progress) = record.payload { return progress.resumePosition == 600 }
            return false
        }
        check(published, "the iPhone's older position is in iCloud first")
        await settle([phone, ipad])
        check(ipad.library.bookmark("Heat", in: ipadID)?.resumePosition == 4_000, "the iPad keeps its newer position (\(ipad.library.bookmark("Heat", in: ipadID)?.resumePosition ?? -1))")
        check(phone.library.bookmark("Heat", in: phoneID)?.resumePosition == 4_000, "the iPhone got it (\(phone.library.bookmark("Heat", in: phoneID)?.resumePosition ?? -1))")
        check(phone.library.bookmark("Ran", in: phoneID)?.isFavorite == true, "the iPad's own favorite reached the iPhone")
        check(ipad.library.preferences["player.skipForwardSeconds"] == .int(30), "the settings in iCloud win on the device that joins")
        check(phone.library.playlists.count == 1 && cloud.allRecords.filter { $0.id.kind == .playlist }.count == 1, "one playlist")
        check(converged([phone, ipad]), "both devices agree")
    }

    await scenario("A fetch that fails partway gives no baseline: nothing is applied or sent until a fetch finishes") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let ipad = Device("ipad", cloud: cloud)
        let phoneID = phone.library.addPlaylist("Films", "https://films.example/f.m3u")
        let ipadID = ipad.library.addPlaylist("Films", "https://films.example/f.m3u")
        world.advance(-86_400 * 7)
        phone.library.watch("Heat", in: phoneID, position: 600, duration: 10_000)
        phone.library.favorite("Alien", in: phoneID)
        world.advance(86_400 * 7)
        ipad.library.watch("Heat", in: ipadID, position: 4_000, duration: 10_000)
        await settle([phone])
        ipad.transport.fetchFailsAfter = 2
        await settle([phone, ipad])
        check(ipad.reconciler.needsBaseline, "no baseline after failed fetches")
        check(ipad.sentCount == 0, "the iPad sent nothing (\(ipad.sentCount))")
        check(ipad.library.bookmark("Heat", in: ipadID)?.resumePosition == 4_000 && ipad.library.favoriteCount == 0, "and applied nothing")
        ipad.transport.fetchFailsAfter = nil
        await settle([phone, ipad])
        check(!ipad.reconciler.needsBaseline, "a fetch that finishes gives the baseline")
        check(phone.library.bookmark("Heat", in: phoneID)?.resumePosition == 4_000 && ipad.library.bookmark("Alien", in: ipadID)?.isFavorite == true, "then both devices merge")
        check(converged([phone, ipad]), "both devices agree")
    }

    await scenario("A playlist deleted elsewhere while the device's ledger was lost stays there only: not deleted there, not brought back") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        phone.library.addPlaylist("News", "https://news.example/n.m3u")
        let old = phone.library.addPlaylist("Old", "https://old.example/o.m3u")
        phone.library.favorite("Archive", in: old)
        await settle([phone, tv])
        tv.library.finishImports()
        // While the TV is away, the iPhone deletes Old and the TV adds a favorite to it; then the TV's ledger is lost.
        phone.library.deletePlaylist(old)
        await settle([phone])
        if let tvOld = tv.library.playlist(named: "Old") {
            tv.library.favorite("Extra", in: tvOld)
        }
        world.advance(60)
        await tv.loseLedger()
        let sentBefore = tv.sentCount
        await settle([phone, tv])
        check(phone.library.playlists.values.map(\.name) == ["News"], "the deleted playlist did not come back on the iPhone (\(phone.library.playlists.values.map(\.name).sorted()))")
        check(tv.library.playlists.values.map(\.name).sorted() == ["News", "Old"], "the TV keeps its copy (\(tv.library.playlists.values.map(\.name).sorted()))")
        check(tv.library.bookmark("Archive", in: tv.library.playlist(named: "Old"))?.isFavorite == true && tv.library.bookmark("Extra", in: tv.library.playlist(named: "Old"))?.isFavorite == true, "with its favorites")
        check(tv.sentCount == sentBefore, "the TV sent nothing (\(tv.sentCount - sentBefore) records)")
        check(cloud.allRecords.filter { $0.id.kind == .playlist && $0.isDeletion }.count == 1, "iCloud still has the deletion")
        await settle([phone, tv])
        check(phone.library.playlists.count == 1 && tv.library.playlists.count == 2, "and it stays that way")
        // The user renames it on the TV: the newer action brings it back everywhere, with its favorite.
        if let tvOld = tv.library.playlist(named: "Old") {
            tv.library.playlists[tvOld]?.name = "Old (TV)"
        }
        await settle([phone, tv])
        let phoneOld = phone.library.playlist(named: "Old (TV)")
        check(phoneOld != nil, "renamed on the TV, it is back on the iPhone")
        check(phone.library.bookmark("Archive", in: phoneOld)?.isFavorite == true && phone.library.bookmark("Extra", in: phoneOld)?.isFavorite == true, "with its favorites, the TV's one too")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("A device that never synced keeps a playlist deleted long ago elsewhere; one added after the deletion syncs") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let kids = phone.library.addPlaylist("Kids", "https://kids.example/k.m3u")
        tv.library.addPlaylist("Kids", "https://kids.example/k.m3u")
        tv.library.preferences["player.skipForwardSeconds"] = .int(10)
        await settle([phone])
        phone.library.deletePlaylist(kids)
        await settle([phone])
        world.advance(3_600)
        let ipad = Device("ipad", cloud: cloud)
        ipad.library.addPlaylist("Kids (iPad)", "https://kids.example/k.m3u")
        await settle([phone, tv])
        check(tv.library.playlists.values.map(\.name) == ["Kids"], "the TV keeps its own playlist (\(tv.library.playlists.values.map(\.name)))")
        check(phone.library.playlists.isEmpty, "the iPhone does not get it back")
        check(cloud.allRecords.filter { $0.id.kind == .playlist }.allSatisfy(\.isDeletion), "iCloud keeps the deletion")
        check(tv.library.preferences["player.skipForwardSeconds"] == .int(10), "a setting iCloud does not have is the TV's")
        check(cloud.allRecords.contains { $0.id.kind == .preference }, "and is published")
        // The iPad added it after the deletion: the newer action.
        await settle([phone, tv, ipad])
        check(phone.library.playlist(named: "Kids (iPad)") != nil, "the iPhone got the iPad's playlist (\(phone.library.playlists.values.map(\.name)))")
        check(tv.library.playlists.values.map(\.name) == ["Kids (iPad)"], "the TV's copy is that playlist again (\(tv.library.playlists.values.map(\.name)))")
        check(converged([phone, tv, ipad]), "the three devices agree")
    }

    await scenario("A lost ledger with a rename that never reached iCloud: the playlist takes iCloud's name, nothing else changes") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Cinema", "https://cinema.example/c.m3u")
        phone.library.favorite("Dune", in: id)
        await settle([phone, tv])
        tv.library.finishImports()
        tv.transport.isOnline = false
        if let tvID = tv.library.playlist(named: "Cinema") {
            tv.library.playlists[tvID]?.name = "Cinema (TV)"
        }
        await tv.sync()
        await tv.loseLedger()
        tv.transport.isOnline = true
        await settle([phone, tv])
        check(tv.library.playlist(named: "Cinema") != nil && phone.library.playlists[id]?.name == "Cinema", "iCloud's name won (the documented trade-off)")
        check(tv.library.favoriteCount == 1 && phone.library.favoriteCount == 1 && cloud.allRecords.filter(\.isDeletion).isEmpty, "nothing else changed")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("A device that never synced, with an empty library, deletes and sends nothing") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let id = phone.library.addPlaylist("Family", "https://family.example/f.m3u")
        phone.library.favorite("Kids", in: id)
        await settle([phone])
        let records = cloud.allRecords
        let tv = Device("appletv", cloud: cloud)
        tv.library.acceptsCloudPlaylists = false
        await settle([phone, tv])
        check(cloud.allRecords == records, "the cloud is unchanged")
        check(tv.sentCount == 0, "the TV sent nothing (\(tv.sentCount))")
        check(phone.library.playlists.count == 1 && phone.library.favoriteCount == 1, "the iPhone keeps everything")
    }

    await scenario("Favorites vanishing in large numbers are held: restored here, or removed everywhere once confirmed") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Live", "https://live.example/l.m3u")
        for channel in ["C0", "C1", "C2", "C3", "C4", "C5"] {
            phone.library.favorite(channel, in: id)
        }
        await settle([phone, tv])
        tv.library.finishImports()
        check(tv.library.favoriteCount == 6, "the TV has the 6 favorites")
        tv.library.loseFavorites()
        await settle([phone, tv])
        check(phone.library.favoriteCount == 6, "the iPhone keeps its 6 favorites (\(phone.library.favoriteCount))")
        check(cloud.allRecords.filter(\.isDeletion).isEmpty, "no deletion reached the cloud")
        check(tv.reconciler.heldDeletionIDs.count == 6, "the TV holds the 6 removals for the user (\(tv.reconciler.heldDeletionIDs.count))")
        await tv.reconciler.restoreHeldDeletions()
        await settle([phone, tv])
        check(tv.library.favoriteCount == 6 && tv.reconciler.heldDeletionIDs.isEmpty, "Restore brought them back on the TV (\(tv.library.favoriteCount))")
        check(converged([phone, tv]), "both devices agree")
        // This time the user meant it.
        tv.library.loseFavorites()
        await settle([phone, tv])
        check(tv.reconciler.heldDeletionIDs.count == 6, "held again")
        await tv.reconciler.confirmHeldDeletions()
        await settle([phone, tv])
        check(phone.library.favoriteCount == 0, "once confirmed, the iPhone removed them too (\(phone.library.favoriteCount))")
        check(cloud.allRecords.filter(\.isDeletion).count == 6 && tv.reconciler.heldDeletionIDs.isEmpty, "6 deletion records, nothing held")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("History vanishing without Clear History is held; Clear History, a few removals and deleting playlists one by one sync at once") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let main = phone.library.addPlaylist("Main", "https://main.example/m.m3u")
        let extras = (1...3).map { phone.library.addPlaylist("Extra \($0)", "https://extra\($0).example/e.m3u") }
        for channel in ["A", "B", "C", "D", "E", "F"] {
            phone.library.favorite(channel, in: main)
            phone.library.watch(channel, in: main, position: 60, duration: 600)
        }
        await settle([phone, tv])
        tv.library.finishImports()
        let tvMain = tv.library.playlist(named: "Main")!
        tv.library.loseHistory()
        await settle([phone, tv])
        check(phone.library.historyCount == 6, "the iPhone keeps its history (\(phone.library.historyCount))")
        check(tv.reconciler.heldDeletionIDs.count == 6, "the TV holds the 6 removals (\(tv.reconciler.heldDeletionIDs.count))")
        await tv.reconciler.restoreHeldDeletions()
        await settle([phone, tv])
        check(tv.library.historyCount == 6, "restored on the TV")
        // Two favorites removed in a row: published at once.
        tv.library.unfavorite("A", in: tvMain)
        tv.library.unfavorite("B", in: tvMain)
        await settle([phone, tv])
        check(phone.library.favoriteCount == 4, "the iPhone removed the 2 favorites (\(phone.library.favoriteCount))")
        // Clear History on the TV.
        tv.library.clearHistory()
        await settle([phone, tv])
        check(phone.library.historyCount == 0 && tv.reconciler.heldDeletionIDs.isEmpty, "Clear History reached the iPhone (\(phone.library.historyCount) left)")
        // The user deletes 3 of the 4 playlists, one by one.
        for name in ["Extra 1", "Extra 2", "Extra 3"] {
            if let playlist = tv.library.playlist(named: name) {
                tv.library.deletePlaylist(playlist)
            }
        }
        await settle([phone, tv])
        check(extras.allSatisfy { phone.library.playlists[$0] == nil } && phone.library.playlists[main] != nil, "the iPhone deleted the 3 playlists and kept Main")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("Conflicting offline edits: a rename on the iPhone and a deletion on the Apple TV; the later wins, nothing else is lost") {
        for deletionIsLater in [true, false] {
            let cloud = MemoryCloudBackend()
            let phone = Device("iphone", cloud: cloud)
            let tv = Device("appletv", cloud: cloud)
            let shared = phone.library.addPlaylist("Shared", "https://shared.example/s.m3u")
            let other = phone.library.addPlaylist("Other", "https://other.example/o.m3u")
            phone.library.favorite("Keep", in: other)
            await settle([phone, tv])
            tv.library.finishImports()
            phone.transport.isOnline = false
            tv.transport.isOnline = false
            let rename = { phone.library.playlists[shared]?.name = "Shared (phone)" }
            let delete = { if let id = tv.library.playlist(named: "Shared") { tv.library.deletePlaylist(id) } }
            if deletionIsLater {
                rename(); await phone.sync(); world.advance(30); delete(); await tv.sync()
            } else {
                delete(); await tv.sync(); world.advance(30); rename(); await phone.sync()
            }
            phone.transport.isOnline = true
            await phone.sync()
            tv.transport.isOnline = true
            await settle([phone, tv])
            if deletionIsLater {
                check(phone.library.playlists[shared] == nil && tv.library.playlist(named: "Shared (phone)") == nil, "the later deletion won on both devices")
            } else {
                check(phone.library.playlists[shared]?.name == "Shared (phone)" && tv.library.playlist(named: "Shared (phone)") != nil, "the later rename won: the TV has the playlist again")
            }
            let tvOther = tv.library.playlist(named: "Other")
            check(phone.library.bookmark("Keep", in: other)?.isFavorite == true && tv.library.bookmark("Keep", in: tvOther)?.isFavorite == true, "the other playlist and its favorite are intact")
            check(converged([phone, tv]), "both devices agree (\(deletionIsLater ? "deletion" : "rename") later)")
        }
    }

    await scenario("The same playlist added again by hand after the store was lost is the same record: no duplicate, its favorites come back") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Living Room", "https://living.example/l.m3u")
        phone.library.favorite("Rai 1", in: id)
        await settle([phone, tv])
        tv.library.finishImports()
        // Lost and added again before any sync pass ran (sync was off, or the app had no network).
        tv.library.loseEverything()
        let again = tv.library.addPlaylist("Living Room", "https://living.example/l.m3u")
        await settle([phone, tv])
        check(phone.library.playlists.count == 1 && tv.library.playlists.count == 1, "one playlist on each device (\(phone.library.playlists.count), \(tv.library.playlists.count))")
        check(cloud.allRecords.filter { $0.id.kind == .playlist }.count == 1, "one playlist record in the cloud")
        check(tv.library.bookmark("Rai 1", in: again)?.isFavorite == true, "its favorite came back on the TV")
        check(tv.reconciler.recordsAwaitingRestore.isEmpty && cloud.allRecords.filter(\.isDeletion).isEmpty, "nothing to restore, nothing deleted")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("A guide gone without being deleted stays on the other devices; one deleted by the user is deleted there") {
        let cloud = MemoryCloudBackend()
        let mac = Device("mac", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let italy = UUID()
        let spain = UUID()
        mac.library.guides[italy] = FakeLibrary.Guide(name: "Italy", url: URL(string: "https://epg.example/it.xml")!, isEnabled: true, addedOn: world.now.syncRounded)
        mac.library.guides[spain] = FakeLibrary.Guide(name: "Spain", url: URL(string: "https://epg.example/es.xml")!, isEnabled: true, addedOn: world.now.syncRounded)
        await settle([mac, tv])
        check(tv.library.guides.count == 2, "the TV has both guides")
        // Gone from the Mac's store without a deletion.
        mac.library.guides[italy] = nil
        await settle([mac, tv])
        check(tv.library.guides.count == 2, "the TV keeps Italy")
        // Deleted by the user.
        mac.library.deleteGuide(spain)
        await settle([mac, tv])
        check(tv.library.guides.values.map(\.name) == ["Italy"], "the TV deleted Spain only (\(tv.library.guides.values.map(\.name)))")
    }

    await scenario("Restore from iCloud: held favorites come back from a full read of the cloud; the device's own edits still sync") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Cinema", "https://cinema.example/c.m3u")
        for film in ["Dune", "Heat", "Alien", "Ran"] {
            phone.library.favorite(film, in: id)
        }
        await settle([phone, tv])
        tv.library.finishImports()
        let tvID = tv.library.playlist(named: "Cinema")!
        tv.library.loseFavorites()
        tv.library.playlists[tvID]?.name = "Cinema (TV)"
        await settle([phone, tv])
        check(tv.reconciler.heldDeletionIDs.count == 4, "the 4 removals are held (\(tv.reconciler.heldDeletionIDs.count))")
        // Settings › iCloud › Restore from iCloud.
        await tv.reconciler.prepareFullRestore()
        await tv.transport.forgetFetchPosition()
        await settle([phone, tv])
        check(tv.library.favoriteCount == 4 && tv.reconciler.heldDeletionIDs.isEmpty, "the favorites came back on the TV (\(tv.library.favoriteCount))")
        check(phone.library.favoriteCount == 4, "and were never removed from the iPhone")
        check(phone.library.playlists[id]?.name == "Cinema (TV)", "the TV's own rename synced")
        check(cloud.allRecords.filter(\.isDeletion).isEmpty, "nothing was deleted")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("A playlist kept despite its deletion elsewhere is listed, and Sync Again brings it back everywhere with its favorites") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let old = phone.library.addPlaylist("Old", "https://old.example/o.m3u")
        phone.library.favorite("Archive", in: old)
        await settle([phone, tv])
        tv.library.finishImports()
        phone.library.deletePlaylist(old)
        await settle([phone])
        world.advance(60)
        await tv.loseLedger()
        await settle([phone, tv])
        let kept = tv.reconciler.keptDespiteDeletionIDs
        check(kept.count == 1 && kept.first?.kind == .playlist, "the TV lists the playlist it kept (\(kept.count))")
        check(phone.library.playlists.isEmpty, "the iPhone does not have it")
        if let tvOld = tv.library.playlist(named: "Old") {
            tv.library.favorite("Added on TV", in: tvOld)
        }
        await settle([phone, tv])
        check(phone.library.playlists.isEmpty, "a favorite added to it on the TV does not bring it back on its own")
        // Settings › iCloud › Deleted on Other Devices › Sync Again.
        await tv.reconciler.syncKeptAgain()
        await settle([phone, tv])
        let phoneOld = phone.library.playlist(named: "Old")
        check(phoneOld != nil, "Sync Again brought it back on the iPhone")
        check(phone.library.bookmark("Archive", in: phoneOld)?.isFavorite == true && phone.library.bookmark("Added on TV", in: phoneOld)?.isFavorite == true, "with its favorites, the TV's one too")
        check(tv.reconciler.keptDespiteDeletionIDs.isEmpty, "nothing is kept on the TV only any more")
        check(cloud.allRecords.filter { $0.id.kind == .playlist && $0.isDeletion }.isEmpty, "iCloud no longer has the deletion")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("A deletion that failed is withdrawn: when the store is lost later, nothing is deleted elsewhere") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        phone.library.addPlaylist("Movies", "https://movies.example/m.m3u")
        phone.library.addPlaylist("Kids", "https://kids.example/k.m3u")
        await settle([phone, tv])
        tv.library.finishImports()
        let tvMovies = tv.library.playlist(named: "Movies")!
        // Sync is off on the TV meanwhile: the journal is not folded.
        tv.library.failToDeletePlaylist(tvMovies)
        check(tv.library.journal.localIDs.isEmpty, "the failed deletion left no entry in the journal")
        tv.library.loseEverything()
        await settle([phone, tv])
        check(cloud.allRecords.filter(\.isDeletion).isEmpty, "no deletion reached the cloud (\(cloud.allRecords.filter(\.isDeletion).count))")
        check(phone.library.playlists.count == 2, "the iPhone keeps both playlists")
        check(tv.reconciler.recordsAwaitingRestore.count == 2, "the TV offers both for a restore (\(tv.reconciler.recordsAwaitingRestore.count))")
    }

    await scenario("The deletion journal keeps the newest deletions only, and a deletion dropped from it deletes nothing elsewhere") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let first = phone.library.addPlaylist("First", "https://first.example/f.m3u")
        await settle([phone, tv])
        // Sync off on the iPhone: deletions pile up in the journal (the first one, then many others).
        phone.library.deletePlaylist(first)
        for _ in 0..<(SyncDeletionJournal.capacity + 20) {
            SyncDeletionJournal.noteDeleted(UUID(), in: phone.library.defaults)
        }
        let stored = phone.library.defaults.stringArray(forKey: SyncDeletionJournal.deletedKey) ?? []
        check(stored.count == SyncDeletionJournal.capacity, "the journal holds \(SyncDeletionJournal.capacity) entries (\(stored.count))")
        check(!stored.contains(first.uuidString), "the oldest deletion was dropped")
        await settle([phone, tv])
        check(cloud.allRecords.filter(\.isDeletion).isEmpty, "the dropped deletion is not published: the playlist is merely gone, kept in iCloud")
        check(tv.library.playlist(named: "First") != nil, "the TV keeps it")
        check(phone.reconciler.recordsAwaitingRestore.count == 1, "the iPhone can restore it")
        check((phone.library.defaults.stringArray(forKey: SyncDeletionJournal.deletedKey) ?? []).isEmpty, "the pass folded the journal")
    }

    await scenario("Engine life (CloudKitSyncTransport): start, stop and Restore in quick succession never run two engines at once") {
        // The steps of `CloudKitSyncTransport` on its `SerialTaskQueue`, with engines whose cancellation takes a
        // while (`CKSyncEngine.cancelOperations()` is asynchronous).
        @MainActor
        final class Engines {
            var live = 0
            var most = 0
            var created = 0
            var current: Int?

            func make() {
                live += 1
                created += 1
                most = max(most, live)
                current = created
            }

            func retire() async -> Bool {
                guard current != nil else {
                    return false
                }
                current = nil
                for _ in 0..<5 {
                    await Task.yield()
                }
                live -= 1
                return true
            }
        }
        let engines = Engines()
        let queue = SerialTaskQueue()
        @MainActor func start() {
            queue.enqueue {
                if engines.current == nil {
                    engines.make()
                }
            }
        }
        @MainActor func stop() {
            queue.enqueue {
                _ = await engines.retire()
            }
        }
        @MainActor func forgetFetchPosition() async {
            await queue.enqueue {
                if await engines.retire() {
                    engines.make()
                }
            }.value
        }
        start()
        stop()
        start()
        let restore = Task { @MainActor in
            await forgetFetchPosition()
        }
        stop()
        start()
        await restore.value
        await forgetFetchPosition()
        await queue.settled()
        check(engines.most == 1, "at most one engine at a time (\(engines.most))")
        check(engines.live == 1 && engines.current != nil, "one engine runs at the end (\(engines.live))")
        check(queue.pendingCount == 0, "every step finished")
    }

    await scenario("Clear History made long before sync runs is a mass removal the user is asked about") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Cinema", "https://cinema.example/c.m3u")
        for film in ["Dune", "Heat", "Alien", "Ran"] {
            phone.library.watch(film, in: id, position: 600, duration: 6_000)
        }
        await settle([phone, tv])
        tv.library.finishImports()
        tv.library.clearHistory()
        // Two days pass before the TV syncs again.
        world.advance(2 * 86_400)
        await settle([phone, tv])
        check(tv.reconciler.heldDeletionIDs.count == 4, "the removals are held (\(tv.reconciler.heldDeletionIDs.count))")
        check(phone.library.historyCount == 4, "the iPhone keeps its history meanwhile")
    }

    await scenario("Remove from History on a series (most of the history, one record per episode) syncs at once: nothing held, the rest stays") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Shows", "https://shows.example/s.m3u")
        for number in 1...4 {
            phone.library.watchEpisode(number, of: "Severance", in: id)
            world.advance(60)
        }
        phone.library.watch("Heat", in: id, position: 1_200, duration: 6_000)
        await settle([phone, tv])
        tv.library.finishImports()
        let tvShows = tv.library.playlist(named: "Shows")!
        check(tv.library.historyCount == 5 && tv.library.seriesHistoryCount == 1, "the TV has the 4 episodes, the movie and the series (\(tv.library.historyCount), \(tv.library.seriesHistoryCount))")
        // Continue Watching › Remove from History on the series card (TVHomeScreen, ChannelRows).
        tv.library.removeSeriesFromHistory("Severance", in: tvShows)
        await settle([phone, tv])
        check(tv.reconciler.heldDeletionIDs.isEmpty, "nothing is held (\(tv.reconciler.heldDeletionIDs.count))")
        check(phone.library.historyCount == 1 && phone.library.bookmark("Heat", in: id)?.lastWatchedAt != nil, "the iPhone removed the 4 episodes and kept the movie (\(phone.library.historyCount) left)")
        check(phone.library.seriesHistoryCount == 0, "the iPhone forgot the series' watch state (\(phone.library.seriesHistoryCount))")
        check(cloud.allRecords.filter(\.isDeletion).count == 5, "5 deletion records: 4 episodes and the series (\(cloud.allRecords.filter(\.isDeletion).count))")
        check(tv.library.journal.removedHistory.isEmpty, "the pass that published them folded the journal")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("Several quick swipes in the history in one pass, then more between passes, all sync at once; a movie watched again stays") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Cinema", "https://cinema.example/c.m3u")
        let films = ["Dune", "Heat", "Alien", "Ran", "Brazil", "Ikiru", "Solaris"]
        for film in films {
            phone.library.watch(film, in: id, position: 600, duration: 6_000)
            world.advance(60)
        }
        await settle([phone, tv])
        tv.library.finishImports()
        let tvCinema = tv.library.playlist(named: "Cinema")!
        // Five swipes before the TV's next pass (5 of 7: a mass removal by count and share), and one movie is
        // watched again right after its swipe.
        for film in ["Dune", "Heat", "Alien", "Ran", "Brazil"] {
            tv.library.removeFromHistory(film, in: tvCinema)
        }
        world.advance(5)
        tv.library.watch("Brazil", in: tvCinema, position: 30, duration: 6_000)
        await settle([phone, tv])
        check(tv.reconciler.heldDeletionIDs.isEmpty, "nothing is held (\(tv.reconciler.heldDeletionIDs.count))")
        check(phone.library.historyCount == 3, "the iPhone removed the 4 movies (\(phone.library.historyCount) left)")
        check(phone.library.bookmark("Brazil", in: id)?.resumePosition == 30, "the movie watched again kept its new position on the iPhone")
        check(tv.library.journal.removedHistory.isEmpty, "the journal is folded")
        // The last ones, one swipe per pass (each the whole remaining history at the end).
        for film in ["Brazil", "Ikiru", "Solaris"] {
            tv.library.removeFromHistory(film, in: tvCinema)
            await tv.sync()
        }
        await settle([phone, tv])
        check(tv.reconciler.heldDeletionIDs.isEmpty && phone.library.historyCount == 0, "the iPhone removed them too (\(phone.library.historyCount) left, \(tv.reconciler.heldDeletionIDs.count) held)")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("A removal from the history does not cover a loss: what vanishes with it unexplained is still held") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Shows", "https://shows.example/s.m3u")
        for number in 1...4 {
            phone.library.watchEpisode(number, of: "Severance", in: id)
        }
        for film in ["Dune", "Heat", "Alien", "Ran"] {
            phone.library.watch(film, in: id, position: 600, duration: 6_000)
        }
        await settle([phone, tv])
        tv.library.finishImports()
        tv.library.removeSeriesFromHistory("Severance", in: tv.library.playlist(named: "Shows")!)
        // The rest of the history vanishes in the same pass, without a word (a damaged store).
        tv.library.loseHistory()
        await settle([phone, tv])
        check(tv.reconciler.heldDeletionIDs.count == 4, "the 4 movies are held (\(tv.reconciler.heldDeletionIDs.count))")
        check(phone.library.historyCount == 4 && phone.library.seriesHistoryCount == 0, "the iPhone removed the series only (\(phone.library.historyCount) left, \(phone.library.seriesHistoryCount) series)")
        // A removal made long before sync runs (sync off for days) is no longer the user's word for it.
        let cloud2 = MemoryCloudBackend()
        let phone2 = Device("iphone2", cloud: cloud2)
        let tv2 = Device("appletv2", cloud: cloud2)
        let id2 = phone2.library.addPlaylist("Shows", "https://shows.example/s.m3u")
        for number in 1...4 {
            phone2.library.watchEpisode(number, of: "Severance", in: id2)
        }
        await settle([phone2, tv2])
        tv2.library.finishImports()
        tv2.library.removeSeriesFromHistory("Severance", in: tv2.library.playlist(named: "Shows")!)
        world.advance(2 * 86_400)
        await settle([phone2, tv2])
        check(tv2.reconciler.heldDeletionIDs.count == 5, "a removal 2 days old is held (\(tv2.reconciler.heldDeletionIDs.count))")
        check(phone2.library.historyCount == 4, "the iPhone keeps its history meanwhile")
    }

    await scenario("Back in the history before sync folds its removal (a saved position, an episode marked watched, another device's record): a loss later is held") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Cinema", "https://cinema.example/c.m3u")
        for film in ["Dune", "Heat", "Alien", "Ran"] {
            phone.library.watch(film, in: id, position: 600, duration: 6_000)
            world.advance(60)
        }
        for number in 1...2 {
            phone.library.watchEpisode(number, of: "Severance", in: id)
            world.advance(60)
        }
        await settle([phone, tv])
        tv.library.finishImports()
        let tvCinema = tv.library.playlist(named: "Cinema")!
        // The TV does not sync meanwhile (sync paused, the app in the background): its journal is not folded.
        tv.library.removeFromHistory("Dune", in: tvCinema)
        tv.library.saveProgress("Dune", in: tvCinema, position: 300)
        check(tv.library.journal.removedHistory.isEmpty, "a position saved again withdraws the movie's removal")
        tv.library.removeSeriesFromHistory("Severance", in: tvCinema)
        tv.library.setEpisodeWatched(1, of: "Severance", in: tvCinema, watched: true)
        check(tv.library.journal.removedHistory.count == 2, "an episode marked watched withdraws the series' removal, not its episodes' (\(tv.library.journal.removedHistory.count) left)")
        tv.library.removeFromHistory("Heat", in: tvCinema)
        // The iPhone's record of Heat reaches the TV (applied as a pass applies it).
        if let heat = cloud.allRecords.first(where: { record in
            if case .channelProgress(let progress) = record.payload {
                return progress.channel.url == FakeLibrary.channelURL("Heat")
            }
            return false
        }), case .channelProgress(let progress) = heat.payload {
            var links = SyncLinks(playlists: [progress.channel.playlist: tvCinema])
            _ = await tv.library.apply([heat], links: &links)
        }
        check(tv.library.bookmark("Heat", in: tvCinema)?.lastWatchedAt != nil, "the record brought Heat back")
        check(tv.library.journal.removedHistory.count == 2, "a synced record withdraws the movie's removal (\(tv.library.journal.removedHistory.count) left)")
        // Then the TV's history vanishes unexplained (a damaged store) before its next pass.
        tv.library.loseHistory()
        world.advance(60)
        await settle([phone, tv])
        check(tv.reconciler.heldDeletionIDs.count == 5, "the 4 movies and the series are held (\(tv.reconciler.heldDeletionIDs.count))")
        check(phone.library.historyCount == 4 && phone.library.seriesHistoryCount == 1, "the iPhone keeps its movies and the series (\(phone.library.historyCount), \(phone.library.seriesHistoryCount))")
        check(phone.library.bookmark(FakeLibrary.episode(1, of: "Severance"), in: id) == nil, "the episodes removed on purpose left the iPhone")
    }

    await scenario("Play from Beginning on items only started (never in the history) syncs as the user's removal, not as a loss") {
        let cloud = MemoryCloudBackend()
        let phone = Device("iphone", cloud: cloud)
        let tv = Device("appletv", cloud: cloud)
        let id = phone.library.addPlaylist("Cinema", "https://cinema.example/c.m3u")
        // Positions synced from a device that saves progress without a watch date, and one movie watched.
        for film in ["Dune", "Heat", "Alien"] {
            phone.library.saveProgress(film, in: id, position: 900)
        }
        phone.library.watch("Ran", in: id, position: 600, duration: 6_000)
        await settle([phone, tv])
        tv.library.finishImports()
        let tvCinema = tv.library.playlist(named: "Cinema")!
        check(tv.library.bookmark("Alien", in: tvCinema)?.resumePosition == 900, "the TV has the positions")
        // Play from Beginning on each (the player then fails to open them, so nothing is watched again).
        for film in ["Dune", "Heat", "Alien"] {
            tv.library.saveProgress(film, in: tvCinema, position: 0)
        }
        check(tv.library.journal.removedHistory.count == 3, "each reset is journaled (\(tv.library.journal.removedHistory.count))")
        await settle([phone, tv])
        check(tv.reconciler.heldDeletionIDs.isEmpty, "nothing is held (\(tv.reconciler.heldDeletionIDs.count))")
        check(["Dune", "Heat", "Alien"].allSatisfy { (phone.library.bookmark($0, in: id)?.resumePosition ?? 0) == 0 }, "the iPhone starts them from the beginning too")
        check(phone.library.bookmark("Ran", in: id)?.resumePosition == 600, "the movie watched keeps its position")
        // A reset of an item that stays in the history is an edit, not a removal.
        tv.library.saveProgress("Ran", in: tvCinema, position: 0)
        check(tv.library.journal.removedHistory.isEmpty, "a reset that keeps the item in the history journals nothing")
        await settle([phone, tv])
        check(phone.library.bookmark("Ran", in: id)?.resumePosition == 0 && phone.library.bookmark("Ran", in: id)?.lastWatchedAt != nil, "the iPhone keeps Ran in the history, from the beginning")
        check(converged([phone, tv]), "both devices agree")
    }

    await scenario("The held-removals question comes back a day after Not Now, not at every launch; sooner when more are held") {
        let start = world.now
        var reminder = SyncHeldRemovalsReminder()
        check(!reminder.shouldAsk(held: 0, now: start), "nothing held, nothing asked")
        check(reminder.shouldAsk(held: 4, now: start), "asked the first time")
        reminder = SyncHeldRemovalsReminder(postponedOn: start, postponedCount: 4)
        check(!reminder.shouldAsk(held: 4, now: start.addingTimeInterval(60)), "not asked again at the next launch")
        check(!reminder.shouldAsk(held: 4, now: start.addingTimeInterval(23 * 3_600)), "not asked again the same day")
        check(reminder.shouldAsk(held: 4, now: start.addingTimeInterval(24 * 3_600)), "asked again a day later")
        check(reminder.shouldAsk(held: 6, now: start.addingTimeInterval(60)), "asked again when more removals are held")
        check(!reminder.shouldAsk(held: 3, now: start.addingTimeInterval(60)), "not asked when fewer are held (some were restored)")
        check(reminder.shouldAsk(held: 4, now: start.addingTimeInterval(-3_600)), "a clock set back does not put it off for good")
    }
}

await run()
FakeLibrary.removeDefaults()
print("\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
