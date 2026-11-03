//
//  main.swift
//  HomeQueriesCheck
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import SwiftData

@main
@MainActor
enum HomeQueriesCheck {

    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("  ok   \(message)")
        } else {
            failures += 1
            print("  FAIL \(message)")
        }
    }

    static func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try body()
        let elapsed = clock.now - start
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("  " + label.padding(toLength: 40, withPad: " ", startingAt: 0) + String(format: "%9.2f ms", milliseconds))
        return value
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        let storeURL = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "/tmp/fluxo-home-queries.sqlite")
        let channelTotal = arguments.count > 2 ? Int(arguments[2]) ?? 50_000 : 50_000
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
        }

        print("== classification")
        checkClassification()

        let schema = Schema(ModelRegistry.all)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))

        let playlistA = UUID()
        let playlistB = UUID()
        let importA = UUID()
        let importB = UUID()
        let stale = UUID()

        print("== seeding \(channelTotal) + 300 channels")
        try timed("seed") {
            try seed(container: container, playlistA: playlistA, importA: importA, playlistB: playlistB, importB: importB, stale: stale, channelTotal: channelTotal)
        }

        let context = ModelContext(container)
        print("== groups")
        let liveGroupCount = try timed("fetchCount live groups (A)") { try context.fetchCount(HomeQueries.groupCount(importIDs: [importA], kind: .live)) }
        let movieGroupCount = try timed("fetchCount movie groups (A)") { try context.fetchCount(HomeQueries.groupCount(importIDs: [importA], kind: .movie)) }
        let seriesGroupCount = try timed("fetchCount series groups (A)") { try context.fetchCount(HomeQueries.groupCount(importIDs: [importA], kind: .series)) }
        expect(liveGroupCount == 50 && movieGroupCount == 30 && seriesGroupCount == 20, "group counts per kind: \(liveGroupCount)/\(movieGroupCount)/\(seriesGroupCount)")
        let bothLive = try context.fetchCount(HomeQueries.groupCount(importIDs: [importA, importB], kind: .live))
        expect(bothLive == 53, "live groups across two playlists: \(bothLive)")
        let staleCount = try context.fetchCount(HomeQueries.groupCount(importIDs: [importA, importB], kind: .movie))
        expect(staleCount == 30, "previous import is not visible: \(staleCount)")
        let firstPage = try timed("groups page (movie, 10)") { try context.fetch(HomeQueries.groups(importIDs: [importA], kind: .movie, limit: 10)) }
        expect(firstPage.count == 10 && firstPage.allSatisfy { $0.kind == .movie }, "movie group page has 10 movie groups")
        expect(zip(firstPage, firstPage.dropFirst()).allSatisfy { $0.sortIndex <= $1.sortIndex }, "groups sorted by sortIndex")

        if let group = firstPage.first {
            let channels = try timed("channels of a group (30)") { try context.fetch(HomeQueries.channels(importID: importA, groupName: group.name, limit: 30)) }
            expect(channels.count == 30 && channels.allSatisfy { $0.groupName == group.name }, "channel row of \(group.name): \(channels.count)")
        }

        print("== featured")
        let onDemandCount = try timed("fetchCount featured on-demand") { try context.fetchCount(HomeQueries.featured(importIDs: [importA], onDemand: true)) }
        let liveCount = try timed("fetchCount featured live") { try context.fetchCount(HomeQueries.featured(importIDs: [importA], onDemand: false)) }
        expect(onDemandCount > 0 && liveCount > 0, "featured candidates: \(onDemandCount) on-demand, \(liveCount) live")
        var window = HomeQueries.featured(importIDs: [importA], onDemand: true)
        window.fetchOffset = max(0, onDemandCount - 8) / 2
        window.fetchLimit = 8
        let featured = try timed("featured window (offset, 8)") { try context.fetch(window) }
        expect(featured.count == 8 && featured.allSatisfy { $0.logo != nil && $0.kind != .live }, "featured window has 8 on-demand items with artwork")

        print("== search")
        let news = try timed("search 'news' (all kinds, 100)") { try context.fetch(HomeQueries.searchChannels(term: "news", importIDs: [importA, importB], kind: nil, limit: 100)) }
        expect(!news.isEmpty && news.allSatisfy { $0.name?.localizedCaseInsensitiveContains("news") == true }, "search 'news' found \(news.count)")
        let cafe = try timed("search 'cafe' (diacritics)") { try context.fetch(HomeQueries.searchChannels(term: "cafe", importIDs: [importA, importB], kind: nil, limit: 100)) }
        expect(cafe.contains { $0.name == "Café Crème TV" }, "diacritic-insensitive search matches 'Café Crème TV'")
        let movies = try timed("search 'movie' (movies only)") { try context.fetch(HomeQueries.searchChannels(term: "movie", importIDs: [importA], kind: .movie, limit: 50)) }
        expect(movies.count == 50 && movies.allSatisfy { $0.kind == .movie }, "kind-scoped search: \(movies.count)")
        let scoped = try context.fetch(HomeQueries.searchChannels(term: "café", importIDs: [importA], kind: nil, limit: 100))
        expect(scoped.isEmpty, "playlist-scoped search excludes the other playlist")
        let unnamed = try context.fetch(HomeQueries.searchChannels(term: "x", importIDs: [importB], kind: nil, limit: 400))
        expect(unnamed.allSatisfy { $0.name != nil }, "channels without a name never match")
        let groups = try timed("search groups 'sport'") { try context.fetch(HomeQueries.searchGroups(term: "SPORT", importIDs: [importA, importB], kind: nil, limit: 20)) }
        expect(!groups.isEmpty && groups.allSatisfy { $0.name.localizedCaseInsensitiveContains("sport") }, "group search found \(groups.count)")

        print("== library")
        try checkLibrary(container: container, playlistA: playlistA, importA: importA, playlistB: playlistB, importB: importB)

        print("== zapping")
        try checkZapping(container: container, playlistA: playlistA, importA: importA)

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        if failures > 0 {
            exit(1)
        }
    }

    static func checkClassification() {
        func kind(_ url: String, group: String = "", name: String? = nil) -> ChannelContentKind {
            ChannelContentKind.classify(url: URL(string: url), groupName: group, name: name)
        }
        expect(kind("https://host/user/pass/123") == .live, "extensionless stream is live")
        expect(kind("https://host/live/user/pass/123.ts") == .live, ".ts stream is live")
        expect(kind("https://host/hls/index.m3u8") == .live, "HLS is live")
        expect(kind("https://host/movie/user/pass/1.mkv") == .movie, "Xtream /movie/ path is a movie")
        expect(kind("https://host/series/user/pass/1.mkv") == .series, "Xtream /series/ path is a series")
        expect(kind("https://host/files/film.mp4") == .movie, ".mp4 is a movie")
        expect(kind("https://host/files/ep.mp4", name: "Show S01E02") == .series, "SxxEyy name is a series")
        expect(kind("https://host/files/ep.mp4", name: "Show s1 e2") == .series, "sX eY name is a series")
        expect(kind("https://host/files/a.mp4", name: "Gases 2E") == .movie, "no false episode marker")
        expect(kind("https://host/files/a.mp4", group: "TV Series | Drama") == .series, "series group keyword")
        expect(ChannelContentKind.dominant(live: 1, movie: 3, series: 2) == .movie, "dominant kind")
    }

    static func seed(container: ModelContainer, playlistA: UUID, importA: UUID, playlistB: UUID, importB: UUID, stale: UUID, channelTotal: Int) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let a = Playlist(uuid: playlistA, name: "Big", url: URL(string: "https://example.com/a.m3u") ?? URL(fileURLWithPath: "/"), createdOn: .now)
        a.currentImportID = importA
        let b = Playlist(uuid: playlistB, name: "Small", url: URL(string: "https://example.com/b.m3u") ?? URL(fileURLWithPath: "/"), createdOn: .now)
        b.currentImportID = importB
        context.insert(a)
        context.insert(b)

        // Playlist A: 50 live, 30 movie and 20 series groups.
        var groups: [PlaylistChannelGroup] = []
        let perGroup = max(31, channelTotal / 100)
        var index = 0
        for groupIndex in 0..<100 {
            let kind: ChannelContentKind = groupIndex < 50 ? .live : (groupIndex < 80 ? .movie : .series)
            let name = groupIndex % 10 == 0 ? "Sports \(groupIndex)" : "\(kind.title) \(groupIndex)"
            groups.append(PlaylistChannelGroup(uuid: UUID(), name: name, sortIndex: groupIndex, channelCount: perGroup, importID: importA, playlistID: playlistA, kind: kind))
            for item in 0..<perGroup {
                let url: String
                let title: String
                switch kind {
                case .live:
                    url = "https://host/user/pass/\(index)"
                    title = item % 7 == 0 ? "News \(index)" : "Channel \(index)"
                case .movie:
                    url = "https://host/movie/user/pass/\(index).mkv"
                    title = "Movie \(index)"
                case .series:
                    url = "https://host/series/user/pass/\(index).mkv"
                    title = "Show \(groupIndex) S01E\(item + 1)"
                }
                let classified = ChannelContentKind.classify(url: URL(string: url), groupName: name, name: title)
                context.insert(PlaylistChannel(
                    uuid: UUID(), name: title, logo: item % 3 == 0 ? nil : "https://img/\(index).png", groupName: name, url: URL(string: url),
                    sortIndex: index, importID: importA, playlistID: playlistA, kind: classified
                ))
                index += 1
            }
            if groupIndex % 10 == 9 {
                try context.save()
            }
        }
        a.groups = groups

        // Playlist B: 3 live groups, one channel with diacritics, some without a name.
        var groupsB: [PlaylistChannelGroup] = []
        for groupIndex in 0..<3 {
            let name = groupIndex == 0 ? "World Sport" : "Group \(groupIndex)"
            groupsB.append(PlaylistChannelGroup(uuid: UUID(), name: name, sortIndex: groupIndex, channelCount: 100, importID: importB, playlistID: playlistB))
            for item in 0..<100 {
                let title: String? = item == 0 && groupIndex == 0 ? "Café Crème TV" : (item % 10 == 0 ? nil : "Extra \(groupIndex)-\(item)")
                context.insert(PlaylistChannel(
                    uuid: UUID(), name: title, logo: nil, groupName: name, url: URL(string: "https://other/\(groupIndex)/\(item)"),
                    sortIndex: groupIndex * 100 + item, importID: importB, playlistID: playlistB
                ))
            }
        }
        b.groups = groupsB
        // Leftover rows of a previous import of A must stay invisible.
        context.insert(PlaylistChannelGroup(uuid: UUID(), name: "Old", sortIndex: 0, channelCount: 1, importID: stale, playlistID: playlistA, kind: .movie))
        try context.save()
    }

    static func checkLibrary(container: ModelContainer, playlistA: UUID, importA: UUID, playlistB: UUID, importB: UUID) throws {
        let library = ChannelLibrary(container: container)
        let context = container.mainContext
        let channelsA = try context.fetch(HomeQueries.searchChannels(term: "News", importIDs: [importA], kind: nil, limit: 3)).map(ChannelItem.init)
        let channelsB = try context.fetch(HomeQueries.searchChannels(term: "Extra", importIDs: [importB], kind: nil, limit: 2)).map(ChannelItem.init)
        guard channelsA.count == 3, channelsB.count == 2 else {
            expect(false, "library fixtures")
            return
        }

        library.toggleFavorite(channelsA[0])
        library.toggleFavorite(channelsB[0])
        expect(library.isFavorite(channelsA[0]) && library.isFavorite(channelsB[0]), "favorites toggled on")
        let favoritesAll = try context.fetch(HomeQueries.favorites(playlistIDs: nil, limit: 20))
        let favoritesA = try context.fetch(HomeQueries.favorites(playlistIDs: [playlistA], limit: 20))
        expect(favoritesAll.count == 2 && favoritesA.count == 1, "favorites filtered by playlist: \(favoritesAll.count)/\(favoritesA.count)")

        for item in channelsA + channelsB {
            library.recordWatch(item)
        }
        library.recordWatch(channelsA[1])
        let recents = try context.fetch(HomeQueries.recents(playlistIDs: nil, limit: 20))
        expect(recents.count == 5, "five channels in the history: \(recents.count)")
        expect(recents.first?.channelID == channelsA[1].id && recents.first?.watchCount == 2, "most recently watched comes first")
        let recentsB = try context.fetch(HomeQueries.recents(playlistIDs: [playlistB], limit: 20))
        expect(recentsB.count == 2, "history filtered by playlist: \(recentsB.count)")

        // A refresh writes new channel rows with new UUIDs; the bookmark (keyed by URL) keeps the favorite.
        let refreshed = ChannelItem(id: UUID(), playlistID: playlistA, name: "Renamed", logo: nil, url: channelsA[0].url, groupName: "G", kind: .live)
        expect(library.isFavorite(refreshed), "favorite survives a refresh (new channel UUID, same URL)")

        library.toggleFavorite(channelsB[0])
        expect(!library.isFavorite(channelsB[0]), "favorite toggled off")
        library.removeFromHistory(channelsB[0])
        let bookmarkCount = try context.fetchCount(FetchDescriptor<ChannelBookmark>())
        expect(bookmarkCount == 4, "unused bookmark deleted: \(bookmarkCount)")

        library.clearHistory()
        let afterClear = try context.fetchCount(FetchDescriptor<ChannelBookmark>())
        expect(afterClear == 1 && library.isFavorite(channelsA[0]), "clearing history keeps favorites: \(afterClear)")

        // History trimming.
        let many = try context.fetch(HomeQueries.channels(importID: importA, groupName: "Live TV 1", limit: 300)).map(ChannelItem.init)
        for item in many.prefix(ChannelLibrary.historyLimit + 10) {
            library.recordWatch(item)
        }
        let historyCount = try context.fetchCount(HomeQueries.recents(playlistIDs: nil, limit: 10_000))
        expect(historyCount == min(ChannelLibrary.historyLimit, many.count), "history trimmed to \(historyCount)")
    }

    static func checkZapping(container: ModelContainer, playlistA: UUID, importA: UUID) throws {
        let zapper = ChannelZapper(container: container, library: ChannelLibrary(container: container))
        let context = container.mainContext
        let group = try context.fetch(HomeQueries.channels(importID: importA, groupName: "Live TV 1", limit: 10_000)).map(ChannelItem.init)
        guard group.count > 2, let first = group.first, let last = group.last else {
            expect(false, "zapping fixtures")
            return
        }
        let next = timed("next channel") { zapper.neighbor(of: first, offset: 1) }
        expect(next?.id == group[1].id, "channel up goes to the next channel of the group")
        expect(zapper.neighbor(of: group[1], offset: -1)?.id == first.id, "channel down goes to the previous channel")
        expect(zapper.neighbor(of: last, offset: 1)?.id == first.id, "channel up wraps from the last to the first channel")
        expect(zapper.neighbor(of: first, offset: -1)?.id == last.id, "channel down wraps from the first to the last channel")
        // A bookmark keeps the URL but its row UUID is gone after a refresh.
        let bookmarked = ChannelItem(id: UUID(), playlistID: playlistA, name: first.name, logo: nil, url: first.url, groupName: first.groupName, kind: .live)
        expect(zapper.neighbor(of: bookmarked, offset: 1)?.id == group[1].id, "zapping from a bookmark finds the channel by URL")
        let orphan = ChannelItem(id: UUID(), playlistID: UUID(), name: "Gone", logo: nil, url: first.url, groupName: first.groupName, kind: .live)
        expect(zapper.neighbor(of: orphan, offset: 1) == nil, "no neighbor once the playlist is gone")
        expect(next.map { $0.groupName == first.groupName } == true, "zapping stays inside the group")
    }
}
