//
//  HomeDiscoveryRows.swift
//  Fluxo
//
//  Home rows that help finding something to watch: "Because You Watched …" (more of the category of the last
//  thing watched) and the category strip (cards with artwork mosaics and counts, plus the category browser).
//

import SwiftData
import SwiftUI

/// "Because You Watched <channel>": other channels of the category of the most recent entry of the watch
/// history in the scope (for an episode: the other series and movies of its category, never its own series).
/// Hidden when the history is empty or the category has nothing else.
struct BecauseYouWatchedRow: View {

    let scope: LibraryScope

    @Query private var recents: [ChannelBookmark]

    init(scope: LibraryScope) {
        self.scope = scope
        _recents = Query(HomeQueries.recents(playlistIDs: scope.bookmarkFilter, limit: 6))
    }

    var body: some View {
        // The most recent entry whose playlist is visible (its category is read from the current import).
        let source = recents.lazy.compactMap { bookmark -> (ChannelItem, UUID)? in
            guard let importID = scope.importID(ofPlaylist: bookmark.playlistID) else {
                return nil
            }
            return (ChannelItem(bookmark), importID)
        }.first
        if let source {
            BecauseYouWatchedContent(item: source.0, importID: source.1, playlistName: scope.showsPlaylistNames ? scope.playlistNames[source.0.playlistID] : nil)
                .id(source.0.bookmarkKey)
        }
    }
}

private struct BecauseYouWatchedContent: View {

    static let fetchLimit = 24

    let item: ChannelItem
    let importID: UUID
    let playlistName: String?

    @Query private var channels: [PlaylistChannel]

    init(item: ChannelItem, importID: UUID, playlistName: String?) {
        self.item = item
        self.importID = importID
        self.playlistName = playlistName
        _channels = Query(HomeQueries.channels(importID: importID, groupName: item.groupName, limit: Self.fetchLimit + 1))
    }

    var body: some View {
        let ownSeries = item.series?.seriesKey
        let others = channels.filter { $0.url != item.url && (ownSeries == nil || $0.seriesKey != ownSeries) }.prefix(Self.fetchLimit)
        if others.count >= 2 {
            let route = ChannelRoute.group(importID: importID, groupName: item.groupName, title: item.groupName.isEmpty ? String(localized: "Other") : item.groupName)
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionHeader(
                    title: String(localized: "Because You Watched"),
                    subtitle: TextParts.line([item.series?.seriesTitle ?? item.displayName, item.groupName, playlistName]),
                    systemImage: "sparkles"
                ) {
                    SeeAllLink(route: route)
                }
                CardRow {
                    ForEach(others) { channel in
                        ChannelPreview(item: ChannelItem(channel))
                    }
                }
            }
            .routeTransitionSource(route)
        }
    }
}

/// The categories of one kind as a row of cards, with "See All" opening the category browser.
struct CategoryStrip: View {

    static let fetchLimit = 20

    let scope: LibraryScope
    let kind: ChannelContentKind
    let totalCount: Int

    @Query private var groups: [PlaylistChannelGroup]

    init(scope: LibraryScope, kind: ChannelContentKind, totalCount: Int) {
        self.scope = scope
        self.kind = kind
        self.totalCount = totalCount
        _groups = Query(HomeQueries.groups(importIDs: scope.importIDs, kind: kind, limit: Self.fetchLimit))
    }

    var body: some View {
        if !groups.isEmpty {
            let route = ChannelRoute.categories(importIDs: scope.importIDs, kind: kind)
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionHeader(title: String(localized: "Categories"), systemImage: "square.grid.2x2.fill") {
                    SeeAllLink(route: route, count: totalCount, unit: .categories)
                }
                CardRow {
                    ForEach(groups) { group in
                        let item = GroupItem(group)
                        CategoryCard(group: item, playlistName: scope.showsPlaylistNames ? scope.playlistNames[item.playlistID] : nil)
                    }
                }
            }
            .routeTransitionSource(route)
        }
    }
}

#Preview("Discovery rows") {
    let scope = LibraryScope(
        playlists: (try? PreviewSampleData.container.mainContext.fetch(FetchDescriptor<Playlist>())) ?? [],
        selection: .all
    )
    NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BecauseYouWatchedRow(scope: scope)
                CategoryStrip(scope: scope, kind: .live, totalCount: 3)
                CategoryStrip(scope: scope, kind: .movie, totalCount: 2)
            }
        }
        .channelDestinations()
    }
    .fluxoPreviewEnvironment()
}
