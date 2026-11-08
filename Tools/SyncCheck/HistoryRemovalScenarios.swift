//
//  HistoryRemovalScenarios.swift
//  SyncCheck
//
//  The user's removals from the history (Clear History, Remove from History, Play from Beginning) against losses,
//  and the held-removals question.
//

import Foundation

@MainActor
func runHistoryRemovalScenarios() async {
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
