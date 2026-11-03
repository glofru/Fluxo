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

    /// Channels of one group, in playlist order.
    static func channels(importID: UUID, groupName: String, limit: Int) -> FetchDescriptor<PlaylistChannel> {
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName },
            sortBy: [SortDescriptor(\.sortIndex)]
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

    /// Candidates for the featured carousel: channels with artwork, on-demand ones (posters) or live ones.
    /// Use `fetchCount` on it, then pick a window with `fetchOffset` / `fetchLimit`.
    static func featured(importIDs: [UUID], onDemand: Bool) -> FetchDescriptor<PlaylistChannel> {
        let live = ChannelContentKind.live.rawValue
        let predicate: Predicate<PlaylistChannel>
        if onDemand {
            predicate = #Predicate { importIDs.contains($0.importID) && $0.kindRawValue != live && $0.logo != nil }
        } else {
            predicate = #Predicate { importIDs.contains($0.importID) && $0.kindRawValue == live && $0.logo != nil }
        }
        return FetchDescriptor<PlaylistChannel>(predicate: predicate, sortBy: [SortDescriptor(\.sortIndex)])
    }

    // MARK: - Search

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
        var descriptor = FetchDescriptor<ChannelBookmark>(predicate: predicate, sortBy: [SortDescriptor(\.favoritedOn, order: .reverse)])
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
