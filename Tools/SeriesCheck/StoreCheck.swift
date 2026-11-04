//
//  StoreCheck.swift
//  Fluxo
//
//  Store checks of series grouping (Tools/SeriesCheck): the import of a playlist with series, the queries Home,
//  Search and the series page use, a refresh and a delete; and the backfill of a store written by the version
//  before series grouping.
//

import Foundation
import SwiftData

enum StoreCheck {

    static var failures = 0

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition {
            print("  ok   \(message())")
        } else {
            failures += 1
            print("  FAIL \(message())")
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func makeContainer(_ storeURL: URL) throws -> ModelContainer {
        let schema = Schema(ModelRegistry.all)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
    }

    // MARK: - Import

    static func run(storeURL: URL, playlist: URL) async throws {
        let container = try makeContainer(storeURL)
        let importer = PlaylistImporter(container: container)
        let playlistID = UUID()
        try await importer.createPlaylist(uuid: playlistID, name: "Series Check", url: playlist)
        let clock = ContinuousClock()
        let started = clock.now
        let summary = try await importer.importContent(ofPlaylist: playlistID, from: playlist) { _ in }
        let importTime = clock.now - started
        print(String(format: "import: %d entries in %.0f ms", summary.channelCount, milliseconds(importTime)))

        let context = ModelContext(container)
        guard let importID = try context.fetch(HomeQueries.playlist(uuid: playlistID)).first?.currentImportID else {
            expect(false, "the import is visible")
            exit(1)
        }
        let episodeCount = try context.fetchCount(FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.importID == importID && $0.seriesKey != nil }))
        let seriesRows = try context.fetch(FetchDescriptor<PlaylistSeries>(predicate: #Predicate { $0.importID == importID }))
        let expected = expectedCounts
        expect(episodeCount == expected.episodes, "every episode is grouped (\(episodeCount) of \(expected.episodes))")
        expect(seriesRows.count == expected.series, "one series row per series (\(seriesRows.count), expected \(expected.series))")
        expect(seriesRows.reduce(0) { $0 + $1.episodeCount } == episodeCount, "the series counts add up to the episodes")
        expect(seriesRows.sorted { $0.sortIndex < $1.sortIndex }.dropLast().allSatisfy { $0.seasonCount >= 2 && $0.artwork != nil }, "seasons and artwork are known (the last series may be cut short)")
        let playlistRow = try context.fetch(HomeQueries.playlist(uuid: playlistID)).first
        expect(playlistRow?.seriesIndexVersion == EpisodeParser.version, "the import is marked as indexed")

        // Group listings: one card per series.
        let seriesKind = ChannelContentKind.series.rawValue
        let groups = try context.fetch(FetchDescriptor<PlaylistChannelGroup>(predicate: #Predicate { $0.importID == importID && $0.kindRawValue == seriesKind }))
        expect(!groups.isEmpty, "series categories exist (\(groups.count))")
        if let group = groups.first {
            let groupName = group.name
            let listed = try context.fetch(HomeQueries.channels(importID: importID, groupName: groupName, order: .playlist, limit: 10_000))
            let keys = listed.compactMap(\.seriesKey)
            expect(Set(keys).count == keys.count, "a category lists each of its series once (\(keys.count) series)")
            expect(listed.count == group.listedCount && group.seriesCount == keys.count, "listedCount (\(group.listedCount)) and seriesCount (\(group.seriesCount)) match the listing")
            let byName = try context.fetch(HomeQueries.channels(importID: importID, groupName: groupName, order: .name, limit: 10_000))
            expect(byName.count == listed.count, "the A–Z order lists the same entries")
        }
        let featured = try context.fetch(HomeQueries.featured(importIDs: [importID], onDemand: true))
        let featuredKeys = featured.compactMap(\.seriesKey)
        expect(Set(featuredKeys).count == featuredKeys.count, "featured candidates have each series once")

        // The series page and Continue.
        if let series = seriesRows.first {
            let measured = clock.now
            let episodes = SeriesLookup.episodes(playlistID: playlistID, key: series.key, in: container)
            let lookupTime = clock.now - measured
            expect(episodes?.episodes.count ?? 0 > 0, String(format: "the series page loads %d episodes in %.1f ms", episodes?.episodes.count ?? 0, milliseconds(lookupTime)))
            if let episodes {
                // What the import stored reads back as the parser saw it (`StoredEpisode`).
                var session = EpisodeParser.Session()
                let roundTrips = episodes.episodes.allSatisfy { item in
                    guard let ref = item.series, let info = session.parse(item.name, groupName: item.groupName) else {
                        return false
                    }
                    return ref.seriesKey == info.seriesKey && ref.seriesTitle == info.seriesTitle && ref.season == info.season
                        && ref.episode == info.episode && ref.episodeTitle == info.episodeTitle
                }
                expect(roundTrips, "the stored season, number and titles of every episode read back as parsed")
                let codes = episodes.episodes.compactMap { $0.series?.code }
                expect(codes == codes.sorted(), "episodes are in watching order")
                expect(episodes.seasons.count == series.seasonCount, "seasons \(episodes.seasons) match the series row")
                let first = episodes.episodes[0]
                let second = SeriesLookup.nextEpisode(after: first, in: container)
                expect(second?.series?.code == episodes.episodes.first(where: { $0.series?.code != first.series?.code })?.series?.code, "next episode after \(first.displayName) is \(second?.displayName ?? "nil")")
                let start = SeriesLookup.nextUp(in: episodes, state: nil, progressKeys: [])
                expect(start?.reason == .start && start?.episode.url == first.url, "never watched: Continue plays the first episode")
                let resume = SeriesLookup.nextUp(in: episodes, state: SeriesWatchState(lastEpisodeURL: first.url, lastEpisode: first.series?.code), progressKeys: [first.bookmarkKey ?? ""])
                expect(resume?.reason == .resume && resume?.episode.url == first.url, "stopped part-way: Continue resumes it")
                let next = SeriesLookup.nextUp(in: episodes, state: SeriesWatchState(watched: [first.series!.code], lastEpisodeURL: first.url, lastEpisode: first.series?.code), progressKeys: [])
                expect(next?.reason == .next && next?.episode.series?.code == second?.series?.code, "watched to the end: Continue plays the next one")
                let all = SeriesLookup.nextUp(in: episodes, state: SeriesWatchState(watched: Set(codes), lastEpisodeURL: episodes.episodes.last?.url, lastEpisode: codes.last), progressKeys: [])
                expect(all?.reason == .rewatch, "everything watched: Watch Again")
                let restart = SeriesLookup.nextUp(in: episodes, state: SeriesWatchState(lastEpisodeURL: first.url, lastEpisode: first.series?.code), progressKeys: [])
                expect(restart?.reason == .restart && restart?.episode.url == first.url, "stopped before a position was kept: Continue plays it again from the start")
                await checkHistory(container: container, episodes: episodes)
            }
        }

        // Search: a series is one result, whatever matched.
        if let series = seriesRows.first {
            await ChannelSearchIndex.shared.prewarm(importIDs: [importID], container: container)
            var timings: [Double] = []
            var hits: (channels: [SearchHit], groups: [SearchHit], series: [SearchHit]) = ([], [], [])
            for _ in 0..<5 {
                let measured = clock.now
                hits = await ChannelSearchIndex.shared.searchCollapsingSeries(series.title, importIDs: [importID], kind: nil, channelLimit: 150, groupLimit: 20, seriesLimit: 40, container: container)
                timings.append(milliseconds(clock.now - measured))
            }
            let episodeHits = ChannelSearchIndex.channels(for: hits.channels, in: context).filter { $0.seriesKey != nil }
            let found = SeriesQueries.series(for: hits.series, in: context)
            expect(episodeHits.isEmpty, "search lists no episodes as channels")
            expect(found.first?.key == series.key, String(format: "search finds “%@” first (%d series; median %.1f ms)", series.title, found.count, timings.sorted()[2]))
            let typo = await ChannelSearchIndex.shared.searchSeries(String(series.title.dropLast(3)), importIDs: [importID], limit: 10, container: container)
            expect(!typo.isEmpty, "a prefix of the title finds the series")
        }

        // Refresh replaces the series with the new import's; delete removes them.
        let refreshStarted = clock.now
        _ = try await importer.importContent(ofPlaylist: playlistID, from: playlist) { _ in }
        print(String(format: "refresh: %.0f ms", milliseconds(clock.now - refreshStarted)))
        let afterRefresh = try ModelContext(container).fetchCount(FetchDescriptor<PlaylistSeries>())
        expect(afterRefresh == expected.series, "a refresh keeps one set of series rows (\(afterRefresh))")
        let bookmarkContext = ModelContext(container)
        bookmarkContext.insert(SeriesBookmark(key: SeriesBookmark.key(playlistID: playlistID, seriesKey: "x"), playlistID: playlistID, seriesKey: "x", title: "X", artwork: nil, groupName: ""))
        try bookmarkContext.save()
        try await importer.deletePlaylist(uuid: playlistID)
        let left = try ModelContext(container).fetchCount(FetchDescriptor<PlaylistSeries>()) + ModelContext(container).fetchCount(FetchDescriptor<SeriesBookmark>())
        expect(left == 0, "deleting the playlist deletes its series and series bookmarks")

        finish()
    }

    /// "Remove from History": one episode (the history screen) re-points the series to the episode watched before
    /// it; a Continue Watching series card removes the whole series.
    @MainActor
    static func checkHistory(container: ModelContainer, episodes: SeriesEpisodes) {
        var seen: Set<EpisodeCode> = []
        let items = Array(episodes.episodes.filter { $0.series.map { seen.insert($0.code).inserted } ?? false }.prefix(3))
        guard items.count == 3, let series = items[0].seriesItem else {
            expect(false, "the series has three episodes for the history checks")
            return
        }
        let library = ChannelLibrary(container: container)
        let context = container.mainContext
        func watchedBookmarks() -> Int {
            (try? context.fetchCount(ChannelLibrary.episodeBookmarks(playlistID: series.playlistID, seriesKey: series.key, watchedOnly: true))) ?? -1
        }
        // E1 and E2 watched to the end, E3 started.
        for item in items.prefix(2) {
            library.recordWatch(item)
            library.saveWatchProgress(for: item, position: 2_700, duration: 2_700)
        }
        library.recordWatch(items[2])
        library.saveWatchProgress(for: items[2], position: 600, duration: 2_700)
        expect(watchedBookmarks() == 3 && library.series.state(for: series)?.lastEpisodeURL == items[2].url, "three episodes in the history, the last one is the series' last episode")

        library.removeFromHistory(items[2])
        let afterOne = library.series.state(for: series)
        expect(watchedBookmarks() == 2 && afterOne?.lastEpisodeURL == items[1].url && library.watchProgress(for: items[2]) == nil,
               "removing the last episode from the history makes the one before it the series' last episode")
        library.removeFromHistory(items[1])
        let afterTwo = library.series.state(for: series)
        expect(afterTwo?.lastEpisodeURL == items[0].url && afterTwo?.watched.contains(items[1].series!.code) == false && afterTwo?.watched.contains(items[0].series!.code) == true,
               "removing a watched episode from the history unmarks it, and only it")

        library.recordWatch(items[1])
        library.recordWatch(items[2])
        library.series.setFavorite(true, for: series)
        library.removeFromContinueWatching(items[2])
        let bookmark = try? context.fetch(SeriesQueries.bookmark(key: series.bookmarkKey)).first
        expect(watchedBookmarks() == 0 && library.series.state(for: series) == nil && bookmark?.lastEpisodeURL == nil && bookmark?.watchedEpisodeCodes.isEmpty == true,
               "Remove from History on the series card removes every episode of the series and what the series knew of them")
        expect(library.series.isFavorite(series) && bookmark?.isFavorite == true, "a favorite series stays a favorite")
        library.series.setFavorite(false, for: series)
        expect(((try? context.fetchCount(FetchDescriptor<SeriesBookmark>())) ?? -1) == 0 && ((try? context.fetchCount(FetchDescriptor<ChannelBookmark>())) ?? -1) == 0,
               "no bookmarks are left behind")
    }

    /// Set by main from the generator.
    nonisolated(unsafe) static var expectedCounts: (episodes: Int, series: Int) = (0, 0)

    // MARK: - Backfill

    /// The store was written by the previous version (OldMain.swift): no series fields, no series rows.
    static func backfill(storeURL: URL) async throws {
        let clock = ContinuousClock()
        let opened = clock.now
        let container = try makeContainer(storeURL)
        print(String(format: "migration: the old store opened with the new schema in %.0f ms", milliseconds(clock.now - opened)))
        let context = ModelContext(container)
        let before = try context.fetchCount(FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.seriesKey != nil }))
        let total = try context.fetchCount(FetchDescriptor<PlaylistChannel>())
        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        expect(before == 0 && total > 0, "the old rows have no series yet (\(total) channels)")
        expect(playlists.allSatisfy { $0.seriesIndexVersion == 0 }, "old playlists are not indexed")
        let unlisted = try context.fetchCount(FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.isListed == false }))
        expect(unlisted == 0, "every old row is listed until indexed (new attributes take their default)")

        let importer = PlaylistImporter(container: container)
        let started = clock.now
        let indexed = await importer.indexSeriesIfNeeded()
        print(String(format: "backfill: %d import(s) indexed in %.0f ms", indexed.count, milliseconds(clock.now - started)))
        let check = ModelContext(container)
        let episodes = try check.fetchCount(FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.seriesKey != nil }))
        let series = try check.fetchCount(FetchDescriptor<PlaylistSeries>())
        expect(indexed.count == playlists.count, "every visible import was indexed")
        expect(episodes == expectedCounts.episodes && series == expectedCounts.series, "\(episodes) episodes in \(series) series (expected \(expectedCounts.episodes) in \(expectedCounts.series))")
        let marked = try check.fetch(FetchDescriptor<Playlist>()).allSatisfy { $0.seriesIndexVersion == EpisodeParser.version }
        expect(marked, "playlists are marked as indexed")
        let again = await importer.indexSeriesIfNeeded()
        expect(again.isEmpty, "a second launch indexes nothing")

        // The bookmark of a watched episode written by the old version: linked to its series and watched.
        let bookmarks = try check.fetch(FetchDescriptor<ChannelBookmark>())
        expect(bookmarks.allSatisfy { $0.seriesKey != nil }, "old episode bookmarks are linked to their series")
        let seriesBookmarks = try check.fetch(FetchDescriptor<SeriesBookmark>())
        expect(seriesBookmarks.count == 1 && seriesBookmarks.first?.watchedEpisodeCodes == ["1:1"] && seriesBookmarks.first?.lastEpisode == 1,
               "the watched episode counts as watched (\(seriesBookmarks.first?.watchedEpisodeCodes ?? []))")
        finish()
    }

    static func finish() {
        print(failures == 0 ? "store: all checks pass" : "store: \(failures) check(s) failed")
        if failures > 0 {
            exit(1)
        }
    }
}
