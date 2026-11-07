//
//  HomeQueries.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import SwiftData

/// Every fetch used by Home, Search and the library screens, in one place so the predicates can be checked
/// against a real store outside the app (Tools/HomeQueriesCheck).
///
/// All descriptors are bounded by a fetch limit and filter on indexed keys (`importID`, `playlistID`,
/// `isFavorite`, `lastWatchedAt`) first, so they stay cheap on playlists with hundreds of thousands of rows.
enum HomeQueries {

    // MARK: - Groups and channels

    /// Groups of `kind` in the given imports, in playlist order.
    static func groups(importIDs: [UUID], kind: ChannelContentKind, limit: Int) -> FetchDescriptor<PlaylistChannelGroup> {
        var descriptor = FetchDescriptor<PlaylistChannelGroup>(
            predicate: groupsPredicate(importIDs: importIDs, kind: kind),
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// For `fetchCount`: how many groups of `kind` the imports have.
    static func groupCount(importIDs: [UUID], kind: ChannelContentKind) -> FetchDescriptor<PlaylistChannelGroup> {
        FetchDescriptor<PlaylistChannelGroup>(predicate: groupsPredicate(importIDs: importIDs, kind: kind))
    }

    /// Channels of one group, in playlist order. A series is listed once, by its first episode in the group
    /// (`PlaylistChannel.isListed`), here and in the other listings of a group.
    static func channels(importID: UUID, groupName: String, limit: Int) -> FetchDescriptor<PlaylistChannel> {
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName && $0.isListed == true },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Channels of one group in the given order, a window at a time (`offset`, `limit`).
    static func channels(importID: UUID, groupName: String, order: ChannelSortOrder, offset: Int = 0, limit: Int) -> FetchDescriptor<PlaylistChannel> {
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName && $0.isListed == true },
            sortBy: order.channelSortDescriptors
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Channels of one group whose name contains `term` (case and diacritic insensitive), in the given order.
    /// Series match on their title, once each.
    static func channels(importID: UUID, groupName: String, matching term: String, order: ChannelSortOrder, limit: Int) -> FetchDescriptor<PlaylistChannel> {
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName && $0.isListed == true && $0.name?.localizedStandardContains(term) == true },
            sortBy: order.channelSortDescriptors
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// The first channels of a group that have artwork: the mosaic of its category card (one poster per series).
    static func groupArtwork(importID: UUID, groupName: String, limit: Int) -> FetchDescriptor<PlaylistChannel> {
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName && $0.isListed == true && $0.logo != nil },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchLimit = limit
        descriptor.propertiesToFetch = [\.logo, \.name, \.kindRawValue]
        return descriptor
    }

    /// Groups of `kind` in the given imports in the given order, optionally only those whose name contains
    /// `term`.
    static func groups(importIDs: [UUID], kind: ChannelContentKind, order: GroupSortOrder, matching term: String?, limit: Int) -> FetchDescriptor<PlaylistChannelGroup> {
        let kindValue = kind.rawValue
        let predicate: Predicate<PlaylistChannelGroup>
        if let term, !term.isEmpty {
            predicate = #Predicate { importIDs.contains($0.importID) && $0.kindRawValue == kindValue && $0.name.localizedStandardContains(term) }
        } else {
            predicate = groupsPredicate(importIDs: importIDs, kind: kind)
        }
        var descriptor = FetchDescriptor<PlaylistChannelGroup>(predicate: predicate, sortBy: order.sortDescriptors)
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// The most watched channels of one group of a playlist, from the watch history (most played first).
    static func mostWatched(playlistID: UUID, groupName: String, limit: Int) -> FetchDescriptor<ChannelBookmark> {
        var descriptor = FetchDescriptor<ChannelBookmark>(
            predicate: #Predicate { $0.playlistID == playlistID && $0.groupName == groupName && $0.watchCount > 0 },
            sortBy: [SortDescriptor(\.watchCount, order: .reverse), SortDescriptor(\.lastWatchedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    // MARK: - Channel zapping

    /// The visible import of a playlist is `Playlist.currentImportID`.
    static func playlist(uuid: UUID) -> FetchDescriptor<Playlist> {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// One channel of a group, by row UUID.
    static func channel(importID: UUID, groupName: String, uuid: UUID) -> FetchDescriptor<PlaylistChannel> {
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName && $0.uuid == uuid }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// One channel of a group, by stream URL (bookmarks keep the URL; row UUIDs change on every refresh).
    static func channel(importID: UUID, groupName: String, url: URL) -> FetchDescriptor<PlaylistChannel> {
        let url: URL? = url
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName && $0.url == url },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// The playable channel of the group right after (`forward`) or right before `sortIndex`.
    static func adjacentChannel(importID: UUID, groupName: String, sortIndex: Int, forward: Bool) -> FetchDescriptor<PlaylistChannel> {
        let predicate: Predicate<PlaylistChannel>
        if forward {
            predicate = #Predicate { $0.importID == importID && $0.groupName == groupName && $0.sortIndex > sortIndex && $0.url != nil }
        } else {
            predicate = #Predicate { $0.importID == importID && $0.groupName == groupName && $0.sortIndex < sortIndex && $0.url != nil }
        }
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sortIndex, order: forward ? .forward : .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// The first or last playable channel of a group (zapping wraps around).
    static func edgeChannel(importID: UUID, groupName: String, first: Bool) -> FetchDescriptor<PlaylistChannel> {
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName && $0.url != nil },
            sortBy: [SortDescriptor(\.sortIndex, order: first ? .forward : .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Candidates for the featured carousel across the imports: channels with artwork, on-demand ones (posters) or
    /// live ones. `FeaturedLoader` fills with a window of it (`fetchOffset` / `fetchLimit`) the pages its categories
    /// did not. A series is a candidate
    /// once per category it is in (its first episode there): the carousel keeps one page per series. That first
    /// episode may have no artwork of its own while the series has some (`PlaylistSeries.artwork`, from a later
    /// episode): the carousel takes the series' then, and leaves out series without any.
    static func featured(importIDs: [UUID], onDemand: Bool) -> FetchDescriptor<PlaylistChannel> {
        let live = ChannelContentKind.live.rawValue
        let predicate: Predicate<PlaylistChannel>
        if onDemand {
            predicate = #Predicate { importIDs.contains($0.importID) && $0.kindRawValue != live && $0.isListed == true && ($0.logo != nil || $0.seriesKey != nil) }
        } else {
            predicate = #Predicate { importIDs.contains($0.importID) && $0.kindRawValue == live && $0.logo != nil }
        }
        return FetchDescriptor<PlaylistChannel>(predicate: predicate, sortBy: [SortDescriptor(\.sortIndex)])
    }

    /// Featured candidates of one category (`FeaturedPicker`): entries with artwork, and series (whose first episode
    /// may have none of its own), a window at a time in playlist order. Uses the `[importID, groupName, sortIndex]`
    /// index.
    static func featured(importID: UUID, groupName: String, offset: Int, limit: Int) -> FetchDescriptor<PlaylistChannel> {
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName && $0.isListed == true && ($0.logo != nil || $0.seriesKey != nil) },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Every category of the imports, in playlist order (the featured picker reads them all: a few hundred rows).
    static func allGroups(importIDs: [UUID]) -> FetchDescriptor<PlaylistChannelGroup> {
        FetchDescriptor<PlaylistChannelGroup>(
            predicate: #Predicate { importIDs.contains($0.importID) },
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        )
    }

    // MARK: - Search

    // The Search screen ranks tokens in memory (`ChannelSearchIndex`). These are plain SQL filters on the whole
    // text, for lookups that need no ranking.

    /// Channels whose name contains `term` (case and diacritic insensitive), optionally of one kind.
    static func searchChannels(term: String, importIDs: [UUID], kind: ChannelContentKind?, limit: Int) -> FetchDescriptor<PlaylistChannel> {
        let predicate: Predicate<PlaylistChannel>
        if let kind {
            let kindValue = kind.rawValue
            predicate = #Predicate { channel in
                importIDs.contains(channel.importID) && channel.kindRawValue == kindValue && channel.name?.localizedStandardContains(term) == true
            }
        } else {
            predicate = #Predicate { channel in
                importIDs.contains(channel.importID) && channel.name?.localizedStandardContains(term) == true
            }
        }
        var descriptor = FetchDescriptor<PlaylistChannel>(predicate: predicate, sortBy: [SortDescriptor(\.name), SortDescriptor(\.sortIndex)])
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Groups whose name contains `term`, optionally of one kind.
    static func searchGroups(term: String, importIDs: [UUID], kind: ChannelContentKind?, limit: Int) -> FetchDescriptor<PlaylistChannelGroup> {
        let predicate: Predicate<PlaylistChannelGroup>
        if let kind {
            let kindValue = kind.rawValue
            predicate = #Predicate { group in
                importIDs.contains(group.importID) && group.kindRawValue == kindValue && group.name.localizedStandardContains(term)
            }
        } else {
            predicate = #Predicate { group in
                importIDs.contains(group.importID) && group.name.localizedStandardContains(term)
            }
        }
        var descriptor = FetchDescriptor<PlaylistChannelGroup>(predicate: predicate, sortBy: [SortDescriptor(\.name)])
        descriptor.fetchLimit = limit
        return descriptor
    }

    // MARK: - Bookmarks

    /// Recently watched channels, newest first. `playlistIDs == nil` means every playlist.
    static func recents(playlistIDs: [UUID]?, limit: Int) -> FetchDescriptor<ChannelBookmark> {
        let predicate: Predicate<ChannelBookmark>
        if let playlistIDs {
            predicate = #Predicate { $0.lastWatchedAt != nil && playlistIDs.contains($0.playlistID) }
        } else {
            predicate = #Predicate { $0.lastWatchedAt != nil }
        }
        var descriptor = FetchDescriptor<ChannelBookmark>(predicate: predicate, sortBy: [SortDescriptor(\.lastWatchedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Favorites, most recently added first. `playlistIDs == nil` means every playlist.
    static func favorites(playlistIDs: [UUID]?, limit: Int) -> FetchDescriptor<ChannelBookmark> {
        let predicate: Predicate<ChannelBookmark>
        if let playlistIDs {
            predicate = #Predicate { $0.isFavorite == true && playlistIDs.contains($0.playlistID) }
        } else {
            predicate = #Predicate { $0.isFavorite == true }
        }
        // The user's order (`favoriteOrder`), then the most recently added first.
        var descriptor = FetchDescriptor<ChannelBookmark>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.favoritedOn, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    static func bookmark(key: String) -> FetchDescriptor<ChannelBookmark> {
        var descriptor = FetchDescriptor<ChannelBookmark>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Watch history entries beyond the newest `keep` that are not favorites, for trimming the history.
    static func staleHistory(keep: Int) -> FetchDescriptor<ChannelBookmark> {
        var descriptor = FetchDescriptor<ChannelBookmark>(
            predicate: #Predicate { $0.lastWatchedAt != nil },
            sortBy: [SortDescriptor(\.lastWatchedAt, order: .reverse)]
        )
        descriptor.fetchOffset = keep
        return descriptor
    }

    // MARK: - Private

    private static func groupsPredicate(importIDs: [UUID], kind: ChannelContentKind) -> Predicate<PlaylistChannelGroup> {
        let kindValue = kind.rawValue
        return #Predicate { importIDs.contains($0.importID) && $0.kindRawValue == kindValue }
    }
}

/// Orders of the channels of a category.
enum ChannelSortOrder: String, CaseIterable, Identifiable, Sendable {
    /// Playlist order (the provider's channel numbers).
    case playlist
    /// By name, A to Z.
    case name
    /// Last entries of the playlist first: providers append new movies and episodes at the end.
    case recentlyAdded
    /// The channels watched most often first (from the watch history), then the others in playlist order.
    case mostWatched

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .playlist:
            return String(localized: "Channel Number")
        case .name:
            return String(localized: "Name (A–Z)")
        case .recentlyAdded:
            return String(localized: "Recently Added")
        case .mostWatched:
            return String(localized: "Most Watched")
        }
    }

    var systemImage: String {
        switch self {
        case .playlist:
            return "number"
        case .name:
            return "textformat"
        case .recentlyAdded:
            return "sparkles"
        case .mostWatched:
            return "flame"
        }
    }

    /// The store order (most watched channels are listed first by the screen, then the rest in playlist order).
    var channelSortDescriptors: [SortDescriptor<PlaylistChannel>] {
        switch self {
        case .playlist, .mostWatched:
            return [SortDescriptor(\.sortIndex)]
        case .name:
            return [SortDescriptor(\.name), SortDescriptor(\.sortIndex)]
        case .recentlyAdded:
            return [SortDescriptor(\.sortIndex, order: .reverse)]
        }
    }
}

/// Orders of the category browser.
enum GroupSortOrder: String, CaseIterable, Identifiable, Sendable {
    case playlist
    case name
    case size

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .playlist:
            return String(localized: "Playlist Order")
        case .name:
            return String(localized: "Name (A–Z)")
        case .size:
            return String(localized: "Most Channels")
        }
    }

    var systemImage: String {
        switch self {
        case .playlist:
            return "list.number"
        case .name:
            return "textformat"
        case .size:
            return "chart.bar.fill"
        }
    }

    var sortDescriptors: [SortDescriptor<PlaylistChannelGroup>] {
        switch self {
        case .playlist:
            return [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        case .name:
            return [SortDescriptor(\.name), SortDescriptor(\.sortIndex)]
        case .size:
            return [SortDescriptor(\.channelCount, order: .reverse), SortDescriptor(\.sortIndex)]
        }
    }
}
