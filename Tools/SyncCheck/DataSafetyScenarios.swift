//
//  DataSafetyScenarios.swift
//  SyncCheck
//
//  Data safety: an empty, recreated or stale library never empties the other devices; vanishing favorites and history
//  are held; deletions, the deletion journal and the life of the sync engine.
//

import Foundation

@MainActor
func runDataSafetyScenarios() async {
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
}
