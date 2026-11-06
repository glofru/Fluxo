//
//  LibraryLookup.swift
//  Fluxo
//
//  Read-only lookups over the library for the Apple Intelligence features and the App Intents: the visible
//  playlists, favorites and watch history, channels by bookmark key, and the token search of the Search screen.
//  Every function uses its own `ModelContext` and returns value types, so callers can run it off the main actor.
//

import Foundation
import SwiftData

/// A favorite or watch history entry, as a value.
struct BookmarkSnapshot: Hashable, Sendable {
    let item: ChannelItem
    let isFavorite: Bool
    let watchCount: Int
    let lastWatchedAt: Date?

    init(_ bookmark: ChannelBookmark) {
        item = ChannelItem(bookmark)
        isFavorite = bookmark.isFavorite
        watchCount = bookmark.watchCount
        lastWatchedAt = bookmark.lastWatchedAt
    }
}

/// A visible playlist: its current import and name.
struct VisiblePlaylist: Hashable, Sendable {
    let playlistID: UUID
    let importID: UUID
    let name: String
}

enum LibraryLookup {

    static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    /// Every playlist that has channels, in creation order.
    static func visiblePlaylists(in container: ModelContainer) -> [VisiblePlaylist] {
        let playlists = (try? makeContext(container).fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.createdOn)]))) ?? []
        return playlists.compactMap { playlist in
            playlist.currentImportID.map { VisiblePlaylist(playlistID: playlist.uuid, importID: $0, name: playlist.name) }
        }
    }

    /// The most recently watched channels and the favorites (`playlistIDs == nil`: every playlist).
    static func bookmarks(playlistIDs: [UUID]?, historyLimit: Int = 60, favoriteLimit: Int = 60, in container: ModelContainer) -> (history: [BookmarkSnapshot], favorites: [BookmarkSnapshot]) {
        let context = makeContext(container)
        let history = ((try? context.fetch(HomeQueries.recents(playlistIDs: playlistIDs, limit: historyLimit))) ?? []).map(BookmarkSnapshot.init)
        let favorites = ((try? context.fetch(HomeQueries.favorites(playlistIDs: playlistIDs, limit: favoriteLimit))) ?? []).map(BookmarkSnapshot.init)
        return (history, favorites)
    }

    /// The channel a bookmark key (`ChannelBookmark.key(playlistID:url:)`) points at: the bookmark's snapshot when
    /// there is one, otherwise the entry with that stream URL in the playlist's visible import. Nil when the
    /// playlist is gone or no longer lists the URL.
    static func channel(forKey key: String, in container: ModelContainer) -> ChannelItem? {
        guard let (playlistID, url) = parse(key: key) else {
            return nil
        }
        let context = makeContext(container)
        if let bookmark = try? context.fetch(HomeQueries.bookmark(key: key)).first {
            return ChannelItem(bookmark)
        }
        guard let importID = try? context.fetch(HomeQueries.playlist(uuid: playlistID)).first?.currentImportID else {
            return nil
        }
        let optionalURL: URL? = url
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.url == optionalURL },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first).map(ChannelItem.init)
    }

    /// Splits a bookmark key into its playlist and stream URL.
    static func parse(key: String) -> (UUID, URL)? {
        guard let separator = key.firstIndex(of: "|"),
              let playlistID = UUID(uuidString: String(key[..<separator])),
              let url = URL(string: String(key[key.index(after: separator)...])) else {
            return nil
        }
        return (playlistID, url)
    }

    /// The first channels of a group, in playlist order.
    static func channels(importID: UUID, groupName: String, limit: Int, in container: ModelContainer) -> [ChannelItem] {
        ((try? makeContext(container).fetch(HomeQueries.channels(importID: importID, groupName: groupName, limit: limit))) ?? []).map(ChannelItem.init)
    }

    /// The first groups of each import, in playlist order (for suggestions without any watch history).
    static func firstGroups(importIDs: [UUID], kind: ChannelContentKind, limit: Int, in container: ModelContainer) -> [GroupItem] {
        ((try? makeContext(container).fetch(HomeQueries.groups(importIDs: importIDs, kind: kind, limit: limit))) ?? []).map(GroupItem.init)
    }

    /// The token search of the Search screen (`ChannelSearchIndex`): every word must match, typos allowed, best
    /// matches first.
    @concurrent static func searchChannels(_ term: String, importIDs: [UUID], kind: ChannelContentKind? = nil, limit: Int, in container: ModelContainer) async -> [ChannelItem] {
        let hits = await ChannelSearchIndex.shared.search(term, importIDs: importIDs, kind: kind, channelLimit: limit, groupLimit: 0, container: container)
        guard !hits.channels.isEmpty else {
            return []
        }
        return ChannelSearchIndex.channels(for: hits.channels, in: makeContext(container)).map(ChannelItem.init)
    }

    /// Groups whose name matches `term` (same rules as `searchChannels`).
    @concurrent static func searchGroups(_ term: String, importIDs: [UUID], kind: ChannelContentKind? = nil, limit: Int, in container: ModelContainer) async -> [GroupItem] {
        let hits = await ChannelSearchIndex.shared.search(term, importIDs: importIDs, kind: kind, channelLimit: 0, groupLimit: limit, container: container)
        guard !hits.groups.isEmpty else {
            return []
        }
        return ChannelSearchIndex.groups(for: hits.groups, in: makeContext(container)).map(GroupItem.init)
    }
}
