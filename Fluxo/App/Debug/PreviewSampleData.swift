//
//  PreviewSampleData.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// In-memory sample library for SwiftUI previews: two playlists with live, movie and series groups,
/// a few favorites and some watch history.
@MainActor
enum PreviewSampleData {

    // Fixed identifiers so previews are deterministic.
    static let freeviewID = UUID(uuidString: "00000000-0000-0000-0000-00000000F001") ?? UUID()
    static let cinemaID = UUID(uuidString: "00000000-0000-0000-0000-00000000C001") ?? UUID()
    static let freeviewImportID = UUID(uuidString: "00000000-0000-0000-0000-00000000F1F1") ?? UUID()
    static let cinemaImportID = UUID(uuidString: "00000000-0000-0000-0000-00000000C1C1") ?? UUID()

    static var importIDs: [UUID] {
        [freeviewImportID, cinemaImportID]
    }

    static let container = makeContainer(withSamples: true)

    static func makeContainer(withSamples: Bool) -> ModelContainer {
        let container = ModelContainerFactory.preview()
        if withSamples {
            insertSamples(into: container.mainContext)
        }
        return container
    }

    static var sampleItems: [ChannelItem] {
        [
            ChannelItem(id: UUID(), playlistID: freeviewID, name: "Fluxo News", logo: "https://i.imgur.com/Vx1F4o5.png", url: URL(string: "https://example.com/live/1"), groupName: "News", kind: .live),
            ChannelItem(id: UUID(), playlistID: freeviewID, name: "Channel without logo", logo: nil, url: URL(string: "https://example.com/live/2"), groupName: "News", kind: .live),
            ChannelItem(
                id: UUID(), playlistID: cinemaID, name: "A movie with a very long long title", logo: "https://image.tmdb.org/t/p/w600_and_h900_bestv2/6JVhFwg6lhnmjLndT18idG7rwwg.jpg",
                url: URL(string: "https://example.com/movie/1.mp4"), groupName: "Drama", kind: .movie
            ),
            ChannelItem(id: UUID(), playlistID: cinemaID, name: "Series S01E01", logo: nil, url: URL(string: "https://example.com/series/1.mkv"), groupName: "Sci-Fi", kind: .series),
        ]
    }

    static func firstGroup() -> GroupItem {
        let context = container.mainContext
        let groups = (try? context.fetch(HomeQueries.groups(importIDs: [freeviewImportID], kind: .live, limit: 1))) ?? []
        if let group = groups.first {
            return GroupItem(group)
        }
        return GroupItem(PlaylistChannelGroup(uuid: UUID(), name: "Empty", sortIndex: 0, channelCount: 0, importID: UUID(), playlistID: UUID()))
    }

    private static func insertSamples(into context: ModelContext) {
        let freeview = Playlist(uuid: freeviewID, name: "Freeview", url: URL(string: "https://example.com/freeview.m3u") ?? .temporaryDirectory, createdOn: .now)
        let cinema = Playlist(uuid: cinemaID, name: "Cinema Club", url: URL(string: "https://example.com/cinema.m3u") ?? .temporaryDirectory, createdOn: .now)
        context.insert(freeview)
        context.insert(cinema)

        let library: [(Playlist, UUID, String, ChannelContentKind, [String])] = [
            (freeview, freeviewImportID, "News", .live, ["Fluxo News", "World Report", "Morning Live", "Business Today", "Weather Now"]),
            (freeview, freeviewImportID, "Sports", .live, ["Sport One", "Football TV", "Tennis Live", "Motor Racing"]),
            (freeview, freeviewImportID, "Kids", .live, ["Cartoons", "Junior", "Science Kids"]),
            (cinema, cinemaImportID, "Action", .movie, ["Fast Roads", "Night Chase", "Skyfall Point", "Iron Bay"]),
            (cinema, cinemaImportID, "Drama", .movie, ["Quiet River", "The Long Winter", "Paper Hearts"]),
            (cinema, cinemaImportID, "Sci-Fi Series", .series, ["Orbit S01E01", "Orbit S01E02", "Orbit S01E03"]),
        ]

        var groupsByPlaylist: [UUID: [PlaylistChannelGroup]] = [:]
        var sortIndex = 0
        var firstItems: [ChannelItem] = []
        for (groupIndex, entry) in library.enumerated() {
            let (playlist, importID, groupName, kind, names) = entry
            let group = PlaylistChannelGroup(
                uuid: UUID(), name: groupName, sortIndex: groupIndex, channelCount: names.count, importID: importID, playlistID: playlist.uuid, kind: kind
            )
            context.insert(group)
            groupsByPlaylist[playlist.uuid, default: []].append(group)
            for name in names {
                let path = kind == .live ? "live/\(sortIndex)" : "\(kind == .movie ? "movie" : "series")/\(sortIndex).mp4"
                let logo = kind == .live ? "https://i.imgur.com/Vx1F4o5.png" : "https://image.tmdb.org/t/p/w600_and_h900_bestv2/6JVhFwg6lhnmjLndT18idG7rwwg.jpg"
                let channel = PlaylistChannel(
                    uuid: UUID(), name: name, logo: logo, groupName: groupName, url: URL(string: "https://example.com/\(path)"),
                    sortIndex: sortIndex, importID: importID, playlistID: playlist.uuid, kind: kind
                )
                context.insert(channel)
                if firstItems.count < 4 && sortIndex % 3 == 0 {
                    firstItems.append(ChannelItem(channel))
                }
                sortIndex += 1
            }
        }
        for playlist in [freeview, cinema] {
            let groups = groupsByPlaylist[playlist.uuid] ?? []
            playlist.groups = groups
            playlist.currentImportID = playlist.uuid == freeviewID ? freeviewImportID : cinemaImportID
            playlist.groupCount = groups.count
            playlist.channelCount = groups.reduce(0) { $0 + $1.channelCount }
            playlist.lastRefreshedOn = .now
        }

        for (index, item) in firstItems.enumerated() {
            guard let url = item.url, let key = item.bookmarkKey else {
                continue
            }
            let bookmark = ChannelBookmark(
                key: key, playlistID: item.playlistID, url: url, channelID: item.id, name: item.name, logo: item.logo, groupName: item.groupName, kind: item.kind
            )
            bookmark.lastWatchedAt = Date.now.addingTimeInterval(TimeInterval(-3_600 * (index + 1)))
            bookmark.watchCount = index + 1
            if index.isMultiple(of: 2) {
                bookmark.isFavorite = true
                bookmark.favoritedOn = .now
            }
            context.insert(bookmark)
        }
        try? context.save()
    }
}

extension View {
    /// Everything the Fluxo screens read from the environment, backed by an in-memory container.
    @MainActor
    func fluxoPreviewEnvironment(_ container: ModelContainer? = nil) -> some View {
        let container = container ?? PreviewSampleData.container
        let library = ChannelLibrary(container: container)
        let player = AVPlayerViewModel()
        return self
            .environment(PlaylistImportCenter(container: container))
            .environment(library)
            .environment(PlaylistActions())
            .environment(\.playChannel, PlayChannelAction(library: library, player: player))
            .modelContainer(container)
    }
}
