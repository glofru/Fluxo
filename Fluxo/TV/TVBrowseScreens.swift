//
//  TVBrowseScreens.swift
//  Fluxo
//
//  Browsing on Apple TV: the Movies and Series tabs (and the channels of the Live TV tab), a category's grid, the
//  category browser, the full Favorites and Recently Watched, and the screens of `ChannelRoute`, which every TV
//  navigation stack registers (`tvDestinations()`), so a card anywhere can open a category or a series and the
//  debug routes and App Intents that push routes reach the TV screens.
//

#if os(tvOS)
import SwiftData
import SwiftUI

extension View {
    /// The Apple TV screens of `ChannelRoute` on the enclosing NavigationStack.
    func tvDestinations() -> some View {
        navigationDestination(for: ChannelRoute.self) { route in
            switch route {
            case let .group(importID, groupName, title):
                TVCategoryScreen(importID: importID, groupName: groupName, title: title)
                    .id(route)
            case let .categories(importIDs, kind):
                TVCategoriesScreen(importIDs: importIDs, kind: kind)
                    .id(route)
            case .favorites(let playlistIDs):
                TVFavoritesScreen(playlistIDs: playlistIDs)
            case let .history(playlistIDs, kinds):
                TVHistoryScreen(playlistIDs: playlistIDs, kinds: kinds)
            case let .series(playlistID, key, title):
                TVSeriesScreen(playlistID: playlistID, seriesKey: key, title: title)
                    .id(route)
            case .downloads, .downloadedSeries:
                // No offline downloads on Apple TV (`PlatformFeatures.offlineDownloads`): nothing links here.
                TVEmptyState(title: String(localized: "TV.downloads.title", defaultValue: "No Downloads", comment: "Apple TV: shown if a link to the offline downloads is opened (Apple TV has none)."), message: String(localized: "TV.downloads.message", defaultValue: "Apple TV plays movies and series as they stream.", comment: "Apple TV: why there are no downloads."), systemImage: "arrow.down.circle")
            }
        }
    }
}

// MARK: - Movies, Series and channels

/// Every category of one kind as shelves (Continue Watching of that kind first, then a strip of the categories
/// to jump to one), a page of categories at a time. The Movies and Series tabs, and the channels of Live TV.
struct TVKindScreen: View {
    let kind: ChannelContentKind
    /// The tab owns its navigation (the Live TV tab embeds the content without a stack of its own).
    var embedsNavigation = true

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNavigation.self) private var navigation
    @State private var path = NavigationPath()
    @State private var groupCount: Int?

    private var scope: LibraryScope {
        LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
    }

    var body: some View {
        if embedsNavigation {
            NavigationStack(path: $path) {
                content
                    .tvDestinations()
            }
            // Open Screen (Siri, a fluxo:// link): the tab from its root.
            .onChange(of: navigation.rootRequest) { _, request in
                if kind != .live, request?.tab == (kind == .series ? AppNavigation.Tab.series : AppNavigation.Tab.movies) {
                    path = NavigationPath()
                }
            }
        } else {
            content
        }
    }

    private var content: some View {
        let scope = scope
        return Group {
            if playlists.isEmpty {
                TVNoPlaylistsState(message: String(localized: "TV.kind.noPlaylists", defaultValue: "Add an M3U playlist to see its channels, movies and series here.", comment: "Apple TV Movies, Series or Live TV page when there is no playlist."), systemImage: kind.systemImage)
            } else if groupCount == 0 {
                TVEmptyState(title: emptyTitle, message: emptyMessage, systemImage: kind.systemImage)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: TVLayout.shelfSpacing) {
                        if kind != .live {
                            TVContinueWatchingShelf(playlistIDs: scope.bookmarkFilter, kinds: kind == .movie ? [.movie] : [.series])
                                .id(scope.bookmarkFilter)
                        }
                        TVCategoryStrip(scope: scope, kind: kind, count: groupCount ?? 0)
                        TVGroupShelves(scope: scope, kind: kind)
                    }
                    .padding(.top, embedsNavigation ? TVLayout.tabBarClearance : 0)
                    .padding(.bottom, TVLayout.verticalMargin)
                }
                .scrollClipDisabled()
                .ignoresSafeArea(edges: embedsNavigation ? .all : .horizontal)
            }
        }
        .task(id: scope.importIDs) {
            groupCount = (try? modelContext.fetchCount(HomeQueries.groupCount(importIDs: scope.importIDs, kind: kind))) ?? 0
        }
    }

    private var emptyTitle: String {
        switch kind {
        case .live:
            return String(localized: "TV.kind.live.empty", defaultValue: "No Live Channels", comment: "Apple TV Live TV page when the playlists have no live channel.")
        case .movie:
            return String(localized: "TV.kind.movies.empty", defaultValue: "No Movies", comment: "Apple TV Movies page when the playlists have no movie.")
        case .series:
            return String(localized: "TV.kind.series.empty", defaultValue: "No Series", comment: "Apple TV Series page when the playlists have no series.")
        }
    }

    private var emptyMessage: String {
        String(localized: "TV.kind.empty.message", defaultValue: "The playlists shown have none. Add another playlist, or show every playlist, in Settings.", comment: "Apple TV Movies, Series or Live TV page when the playlists shown have nothing of that kind.")
    }
}

/// A shelf of category tiles: a quick way to a category far down the page, and to the full category browser.
private struct TVCategoryStrip: View {
    let scope: LibraryScope
    let kind: ChannelContentKind
    let count: Int

    @Query private var groups: [PlaylistChannelGroup]

    static let limit = 30

    init(scope: LibraryScope, kind: ChannelContentKind, count: Int) {
        self.scope = scope
        self.kind = kind
        self.count = count
        _groups = Query(HomeQueries.groups(importIDs: scope.importIDs, kind: kind, limit: Self.limit))
    }

    var body: some View {
        if groups.count > 1 {
            TVShelf(title: String(localized: "Categories"), subtitle: count.formatted()) {
                ForEach(groups) { group in
                    TVCategoryTile(group: GroupItem(group))
                }
                if count > groups.count {
                    TVSeeAllCard(route: .categories(importIDs: scope.importIDs, kind: kind), size: TVCategoryTile.size, focusName: "see-all-categories")
                }
            }
        }
    }
}

/// A category: its name and how many entries it has, on a tile tinted after its name.
struct TVCategoryTile: View {
    static let size = CGSize(width: 320, height: 150)

    let group: GroupItem

    var body: some View {
        TVCard(
            size: Self.size,
            action: .open(group.route),
            focusName: group.displayName,
            accessibilityLabel: Text(TextParts.spoken([group.displayName, CategoryCard.countText(group)])),
            accessibilityHint: Text(TVText.opensCategoryHint)
        ) {
            ZStack(alignment: .bottomLeading) {
                let hue = ArtworkPlaceholder.hue(for: group.name)
                LinearGradient(
                    colors: [Color(hue: hue, saturation: 0.5, brightness: 0.55), Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.displayName)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text(group.itemCount.formatted())
                        .font(.caption)
                        .opacity(0.8)
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(20)
            }
        } caption: { _ in
            EmptyView()
        }
    }
}

/// Every category of a kind as a grid of tiles (See All of the category strip).
struct TVCategoriesScreen: View {
    let importIDs: [UUID]
    let kind: ChannelContentKind

    @Query private var groups: [PlaylistChannelGroup]

    init(importIDs: [UUID], kind: ChannelContentKind) {
        self.importIDs = importIDs
        self.kind = kind
        _groups = Query(HomeQueries.groups(importIDs: importIDs, kind: kind, limit: 2_000))
    }

    private let columns = Array(repeating: GridItem(.fixed(TVCategoryTile.size.width), spacing: TVLayout.cardSpacing, alignment: .top), count: 5)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                TVPageTitle(title: kind.title, subtitle: String(localized: "\(groups.count) categories", comment: "Apple TV: the number of categories of the category browser."))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                    ForEach(groups) { group in
                        TVCategoryTile(group: GroupItem(group))
                    }
                }
                .padding(.horizontal, TVLayout.margin)
                .padding(.vertical, TVLayout.focusPadding)
            }
            .padding(.vertical, TVLayout.verticalMargin)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
    }
}

/// The big title of a pushed page, with a second line.
struct TVPageTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.bold())
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, TVLayout.margin)
    }
}

// MARK: - A category

/// Every entry of one category as a grid (posters for movies and series, landscape cards for channels), a page at
/// a time, in the order chosen at the top.
struct TVCategoryScreen: View {
    let importID: UUID
    let groupName: String
    let title: String

    @Query private var groups: [PlaylistChannelGroup]
    @Environment(\.modelContext) private var modelContext
    @State private var model = CategoryChannelsModel()
    @AppStorage("tv.category.order") private var orderRawValue = ChannelSortOrder.playlist.rawValue

    init(importID: UUID, groupName: String, title: String) {
        self.importID = importID
        self.groupName = groupName
        self.title = title
        _groups = Query(FetchDescriptor<PlaylistChannelGroup>(predicate: #Predicate { $0.importID == importID && $0.name == groupName }))
    }

    private var group: GroupItem? {
        groups.first.map(GroupItem.init)
    }

    private var order: ChannelSortOrder {
        ChannelSortOrder(rawValue: orderRawValue) ?? .playlist
    }

    var body: some View {
        let group = group
        let kind = group?.kind ?? .live
        let columns = Array(
            repeating: GridItem(.fixed(kind == .live ? TVLayout.landscapeCard.width : TVLayout.posterCard.width), spacing: TVLayout.cardSpacing, alignment: .top),
            count: kind == .live ? 4 : 6
        )
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom) {
                    TVPageTitle(title: title, subtitle: group.map(CategoryCard.countText))
                    Spacer()
                    Picker(selection: $orderRawValue) {
                        ForEach(ChannelSortOrder.allCases.filter { $0 != .mostWatched }) { order in
                            Label(order.title, systemImage: order.systemImage)
                                .tag(order.rawValue)
                        }
                    } label: {
                        Label(String(localized: "TV.category.order", defaultValue: "Order", comment: "Apple TV, a category's page: the menu of the order of its entries."), systemImage: "arrow.up.arrow.down")
                    }
                    .pickerStyle(.menu)
                    .padding(.trailing, TVLayout.margin)
                }
                .focusSection()

                if model.isLoaded && model.items.isEmpty {
                    TVEmptyState(title: String(localized: "No Channels"), message: String(localized: "This playlist has no channels."), systemImage: "tv.slash")
                } else if !model.isLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                        ForEach(model.items) { item in
                            Group {
                                if kind == .live {
                                    TVChannelCard(item: item)
                                } else {
                                    TVPosterCard(item: item)
                                }
                            }
                            .onAppear {
                                if item.id == model.items.last?.id, !model.reachedEnd {
                                    Task {
                                        await model.loadMore(container: modelContext.container)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, TVLayout.margin)
                    .padding(.vertical, TVLayout.focusPadding)
                }
            }
            .padding(.vertical, TVLayout.verticalMargin)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .task(id: LoadKey(group: group, order: order)) {
            guard let group else {
                return
            }
            await model.load(CategoryChannelsModel.Request(importID: group.importID, playlistID: group.playlistID, groupName: group.name, order: order, term: ""), container: modelContext.container)
        }
    }

    private struct LoadKey: Hashable {
        let group: GroupItem?
        let order: ChannelSortOrder
    }
}

// MARK: - Favorites and history

/// Every favorite: channels, movies and episodes, then the series.
struct TVFavoritesScreen: View {
    let playlistIDs: [UUID]?

    @Query private var bookmarks: [ChannelBookmark]
    @Query private var seriesBookmarks: [SeriesBookmark]

    init(playlistIDs: [UUID]?) {
        self.playlistIDs = playlistIDs
        _bookmarks = Query(HomeQueries.favorites(playlistIDs: playlistIDs, limit: 500))
        _seriesBookmarks = Query(SeriesQueries.favorites(playlistIDs: playlistIDs, limit: 500))
    }

    private let columns = Array(repeating: GridItem(.fixed(TVLayout.landscapeCard.width), spacing: TVLayout.cardSpacing, alignment: .top), count: 4)

    var body: some View {
        let entries = TVFavoriteEntry.merge(bookmarks, seriesBookmarks, limit: 1_000)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                TVPageTitle(title: String(localized: "Favorites"), subtitle: entries.isEmpty ? nil : entries.count.formatted())
                if entries.isEmpty {
                    TVEmptyState(title: String(localized: "TV.favorites.empty", defaultValue: "No Favorites Yet", comment: "Apple TV Favorites page when there is none."), message: String(localized: "TV.favorites.emptyMessage", defaultValue: "Press and hold a channel, movie or series, then choose Add to Favorites.", comment: "Apple TV Favorites page: how to add a favorite (long press on the Siri Remote)."), systemImage: "star")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .channel(let bookmark):
                                TVChannelCard(item: ChannelItem(bookmark))
                            case .series(let bookmark):
                                TVSeriesLandscapeCard(series: SeriesItem(bookmark))
                            }
                        }
                    }
                    .padding(.horizontal, TVLayout.margin)
                    .padding(.vertical, TVLayout.focusPadding)
                }
            }
            .padding(.vertical, TVLayout.verticalMargin)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
    }
}

/// The watch history, newest first, in sections by day.
struct TVHistoryScreen: View {
    let playlistIDs: [UUID]?
    /// nil: every kind (Continue Watching of the Movies and Series pages narrows it to theirs).
    var kinds: Set<ChannelContentKind>?

    @Query private var history: [ChannelBookmark]
    @Environment(ChannelLibrary.self) private var library
    @State private var confirmsClear = false

    init(playlistIDs: [UUID]?, kinds: Set<ChannelContentKind>? = nil) {
        self.playlistIDs = playlistIDs
        self.kinds = kinds
        _history = Query(HomeQueries.recents(playlistIDs: playlistIDs, limit: ChannelLibrary.historyLimit))
    }

    private var bookmarks: [ChannelBookmark] {
        guard let kinds else {
            return history
        }
        return history.filter { kinds.contains($0.kind) }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom) {
                    TVPageTitle(title: String(localized: "Recently Watched"))
                    Spacer()
                    // Clear History empties all of it: not offered on a page that shows part of it.
                    if !bookmarks.isEmpty, kinds == nil {
                        Button(String(localized: "Clear History"), systemImage: "trash") {
                            confirmsClear = true
                        }
                        .tvActionButton()
                        .padding(.trailing, TVLayout.margin)
                    }
                }
                .focusSection()
                if bookmarks.isEmpty {
                    TVEmptyState(title: String(localized: "Nothing Watched Yet"), message: String(localized: "Channels, movies and series you play show up here."), systemImage: "clock")
                } else {
                    ForEach(days, id: \.day) { day in
                        TVShelf(title: GuideFormat.day(day.day)) {
                            ForEach(day.entries, id: \.key) { bookmark in
                                TVContinueCard(lastWatched: ChannelItem(bookmark), watchedAt: bookmark.lastWatchedAt)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, TVLayout.verticalMargin)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .confirmationDialog(String(localized: "Clear the watch history?"), isPresented: $confirmsClear) {
            Button(String(localized: "Clear History"), role: .destructive) {
                library.clearHistory()
            }
        } message: {
            Text("Favorites are kept.")
        }
    }

    private struct Day {
        let day: Date
        let entries: [ChannelBookmark]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        var result: [Day] = []
        for bookmark in bookmarks {
            let day = calendar.startOfDay(for: bookmark.lastWatchedAt ?? .distantPast)
            if let last = result.last, last.day == day {
                result[result.count - 1] = Day(day: day, entries: last.entries + [bookmark])
            } else {
                result.append(Day(day: day, entries: [bookmark]))
            }
        }
        return result
    }
}
#endif
