//
//  FavoritesView.swift
//  Fluxo
//
//  The Favorites screen: what the favorite channels show now (large cards from the TV guide), then every
//  favorite in sections by kind or by playlist, with the programme on air and its progress, swipe and
//  context actions, a filter, and the user's own order (Edit on iOS, drag on macOS).
//

import SwiftData
import SwiftUI

/// How the favorites are split into sections.
enum FavoritesGrouping: String, CaseIterable, Identifiable {
    case kind
    case playlist
    case none

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .kind:
            return String(localized: "Type")
        case .playlist:
            return String(localized: "Playlist")
        case .none:
            return String(localized: "None")
        }
    }
}

struct FavoritesView: View {

    static let fetchLimit = 1_000

    /// nil: every playlist.
    let playlistIDs: [UUID]?

    @Query private var favorites: [ChannelBookmark]
    /// Favorite series (a series as a whole, `SeriesBookmark`), listed in their own section.
    @Query private var favoriteSeries: [SeriesBookmark]
    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @AppStorage("favorites.grouping") private var grouping = FavoritesGrouping.kind
    @State private var filter: ChannelContentKind?
    @State private var onNow: [OnNowEntry] = []

    @Environment(ChannelLibrary.self) private var library
    @Environment(EPGStore.self) private var epg
    @Environment(AppNavigation.self) private var navigation
    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif

    init(playlistIDs: [UUID]?) {
        self.playlistIDs = playlistIDs
        _favorites = Query(HomeQueries.favorites(playlistIDs: playlistIDs, limit: Self.fetchLimit))
        _favoriteSeries = Query(SeriesQueries.favorites(playlistIDs: playlistIDs, limit: Self.fetchLimit))
    }

    var body: some View {
        let items = favorites.map(ChannelItem.init)
        let series = favoriteSeries.map(SeriesItem.init)
        let sections = sections(of: items)
        Group {
            if items.isEmpty && series.isEmpty {
                emptyState
            } else {
                List {
                    if kinds(of: items).count > 1, !isEditing {
                        Section {
                            filterPicker(kinds: kinds(of: items))
                                .listRowInsets(EdgeInsets(top: 4, leading: HomeLayout.horizontalMargin, bottom: 4, trailing: HomeLayout.horizontalMargin))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }

                    if !isEditing, !onNow.isEmpty, filter == nil || filter == .live {
                        Section {
                            CardRow {
                                ForEach(onNow) { entry in
                                    OnNowCard(entry: entry, width: 264)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } header: {
                            Label("On Now", systemImage: "dot.radiowaves.left.and.right")
                                .foregroundStyle(Theme.live)
                        }
                    }

                    if !series.isEmpty, filter == nil || filter == .series {
                        Section {
                            ForEach(series) { series in
                                SeriesListRow(series: series, subtitle: playlistName(forPlaylist: series.playlistID))
                            }
                            .onMove { source, destination in
                                var reordered = series
                                reordered.move(fromOffsets: source, toOffset: destination)
                                library.series.reorderFavorites(reordered.map(\.bookmarkKey))
                            }
                        } header: {
                            Label {
                                Text(ChannelContentKind.series.title)
                            } icon: {
                                Image(systemName: "square.stack")
                            }
                        }
                    }

                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                FavoriteRow(item: item, playlistName: playlistName(for: item, in: section))
                            }
                            .onMove { source, destination in
                                move(in: section, from: source, to: destination, all: items)
                            }
                        } header: {
                            if let title = section.title {
                                Label {
                                    Text(title)
                                } icon: {
                                    Image(systemName: section.systemImage)
                                }
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .animation(.smooth, value: filter)
                .animation(.smooth, value: grouping)
            }
        }
        .navigationTitle("Favorites")
        // Channels dragged here (from another window, or the player's channel list) become favorites.
        .favoritesDropDestination(library: library)
        .toolbar {
            toolbarContent(isEmpty: items.isEmpty && series.isEmpty)
        }
        .task(id: OnNowKey(keys: items.filter { $0.kind == .live }.compactMap(\.bookmarkKey), revision: epg.revision)) {
            await loadOnNow(items)
        }
    }

    // MARK: - Sections

    struct FavoritesSection: Identifiable {
        let id: String
        let title: String?
        let systemImage: String
        let items: [ChannelItem]
    }

    private func kinds(of items: [ChannelItem]) -> [ChannelContentKind] {
        ChannelContentKind.allCases.filter { kind in items.contains { $0.kind == kind } || (kind == .series && !favoriteSeries.isEmpty) }
    }

    private func sections(of items: [ChannelItem]) -> [FavoritesSection] {
        let filtered = filter.map { kind in items.filter { $0.kind == kind } } ?? items
        switch grouping {
        case .none:
            return [FavoritesSection(id: "all", title: nil, systemImage: "star", items: filtered)]
        case .kind:
            return ChannelContentKind.allCases.compactMap { kind in
                let matching = filtered.filter { $0.kind == kind }
                // Next to the favorite series, favorite episodes are "Episodes".
                let title = kind == .series && !favoriteSeries.isEmpty ? String(localized: "Episodes", comment: "Favorites section: single episodes of series that are favorites.") : kind.title
                return matching.isEmpty ? nil : FavoritesSection(id: "kind-\(kind.rawValue)", title: title, systemImage: kind.systemImage, items: matching)
            }
        case .playlist:
            var result = playlists.compactMap { playlist -> FavoritesSection? in
                let matching = filtered.filter { $0.playlistID == playlist.uuid }
                return matching.isEmpty ? nil : FavoritesSection(id: playlist.uuid.uuidString, title: playlist.name, systemImage: "list.bullet.rectangle", items: matching)
            }
            let known = Set(playlists.map(\.uuid))
            let orphans = filtered.filter { !known.contains($0.playlistID) }
            if !orphans.isEmpty {
                result.append(FavoritesSection(id: "other", title: String(localized: "Other"), systemImage: "questionmark.folder", items: orphans))
            }
            return result
        }
    }

    private func playlistName(for item: ChannelItem, in section: FavoritesSection) -> String? {
        guard grouping != .playlist, playlists.count > 1 else {
            return nil
        }
        return playlists.first { $0.uuid == item.playlistID }?.name
    }

    private func playlistName(forPlaylist playlistID: UUID) -> String? {
        playlists.count > 1 ? playlists.first { $0.uuid == playlistID }?.name : nil
    }

    /// Moves within one section, then writes the order of the whole list (the other sections keep their places).
    private func move(in section: FavoritesSection, from source: IndexSet, to destination: Int, all items: [ChannelItem]) {
        var reordered = section.items
        reordered.move(fromOffsets: source, toOffset: destination)
        let sectionKeys = Set(section.items.compactMap(\.bookmarkKey))
        var replacements = reordered.makeIterator()
        let keys = items.compactMap { item -> String? in
            guard let key = item.bookmarkKey else {
                return nil
            }
            return sectionKeys.contains(key) ? replacements.next()?.bookmarkKey : key
        }
        library.reorderFavorites(keys)
    }

    private var isEditing: Bool {
        #if os(iOS)
        editMode?.wrappedValue.isEditing == true
        #else
        false
        #endif
    }

    // MARK: - Pieces

    private func filterPicker(kinds: [ChannelContentKind]) -> some View {
        Picker("Show", selection: $filter) {
            Text("All")
                .tag(ChannelContentKind?.none)
            ForEach(kinds) { kind in
                Text(kind.segmentTitle)
                    .tag(ChannelContentKind?.some(kind))
            }
        }
        .segmentedPickerStyleAdaptingToTextSize()
        .labelsHidden()
    }

    @ToolbarContentBuilder
    private func toolbarContent(isEmpty: Bool) -> some ToolbarContent {
        #if os(iOS)
        if !isEmpty {
            // iPad: on the trailing side, next to Options; on the leading side it would sit next to the sidebar's
            // own Edit button (tab customization).
            ToolbarItem(placement: DeviceIdiom.isPad ? .topBarTrailing : .topBarLeading) {
                EditButton()
            }
        }
        #endif
        ToolbarItem {
            Menu {
                if !isEmpty {
                    Picker("Group By", selection: $grouping) {
                        ForEach(FavoritesGrouping.allCases) { grouping in
                            Text(grouping.title)
                                .tag(grouping)
                        }
                    }
                    .pickerStyle(.inline)
                }
                NavigationLink(value: ChannelRoute.history(playlistIDs: playlistIDs)) {
                    Label("Recently Watched", systemImage: "clock")
                }
            } label: {
                Label("Options", systemImage: "ellipsis")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Favorites Yet", systemImage: "star")
                .symbolRenderingMode(.multicolor)
        } description: {
            Text("Swipe a channel, or touch and hold it, and choose Favorite. Your favorites show up here with what they are showing now.")
        } actions: {
            Button {
                navigation.show(.home)
            } label: {
                Label("Browse Channels", systemImage: "play.tv")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accentFill)
        }
    }

    private struct OnNowKey: Hashable {
        let keys: [String]
        let revision: Int
    }

    private func loadOnNow(_ items: [ChannelItem]) async {
        while !Task.isCancelled {
            guard epg.hasGuide else {
                onNow = []
                return
            }
            let found = await OnNowLoader.load(candidates: items, epg: epg, limit: 20)
            guard !Task.isCancelled else {
                return
            }
            if found != onNow {
                onNow = found
            }
            let wake = OnNowLoader.nextChange(of: found)
            try? await Task.sleep(for: .seconds(max(30, wake.timeIntervalSinceNow + 1)))
        }
    }
}

/// A favorite: large artwork, the name and the playlist / category, what a live channel shows now (with its
/// progress and what follows) or how far a movie was watched. Tapping plays it; swipe for the other actions.
private struct FavoriteRow: View {

    static let logoSize = CGSize(width: 96, height: 64)
    static let posterSize = CGSize(width: 60, height: 90)

    let item: ChannelItem
    let playlistName: String?

    @Environment(ChannelLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(EPGStore.self) private var epg
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sourceID = UUID().uuidString

    var body: some View {
        HStack(spacing: 14) {
            Button {
                playChannel(item, from: sourceID)
            } label: {
                // At the accessibility text sizes the artwork sits above the text, which gets the whole width.
                AdaptiveStack(spacing: 14) {
                    ChannelLogoTile(item: item, size: item.kind.usesPosterArtwork ? Self.posterSize : Self.logoSize, cornerRadius: 12)
                        .playerTransitionSource(id: sourceID, cornerRadius: 12)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.series?.seriesTitle ?? item.displayName)
                            .font(.headline)
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 5 : 2)
                        if let episode = item.series {
                            Text(TextParts.line([EpisodeFormat.code(episode), episode.episodeTitle]))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 1)
                                .accessibilityLabel(Text(TextParts.spoken([EpisodeFormat.spokenCode(episode), episode.episodeTitle])))
                        }
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 1)
                        if item.kind == .live {
                            RowProgrammeInfo(item: item)
                        } else {
                            WatchProgressLine(item: item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(item.kind == .live ? "Plays the channel" : "Plays the video")
            .channelAccessibilityActions(item, isFavorite: true)

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondaryText)
            .accessibilityLabel("More Actions")
            .accessibilityHint(item.displayName)
        }
        .padding(.vertical, 4)
        .contextMenu {
            actions
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Play", systemImage: "play.fill") {
                playChannel(item, from: sourceID)
            }
            .tint(Theme.accentFill)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Remove", systemImage: "star.slash.fill", role: .destructive) {
                library.setFavorite(false, for: item)
            }
            if item.kind == .live, epg.hasGuide {
                Button("Guide", systemImage: "calendar.day.timeline.left") {
                    navigation.scheduleChannel = item
                }
                .tint(Theme.cyanFill)
            }
        }
    }

    private var subtitle: String {
        TextParts.line([item.kind.title, item.groupName, playlistName])
    }

    @ViewBuilder
    private var actions: some View {
        Button(item.kind == .live ? "Watch Live" : "Play", systemImage: "play.fill") {
            playChannel(item, from: sourceID)
        }
        if item.kind == .live, epg.hasGuide {
            Button("Today's Schedule", systemImage: "calendar.day.timeline.left") {
                navigation.scheduleChannel = item
            }
            Button("Guide Channel…", systemImage: "calendar.badge.checkmark") {
                epg.matchingTarget = item
            }
        }
        if StreamLink(item.url) != nil {
            Divider()
            ChannelLinkMenuItems(item: item)
        }
        Divider()
        Button("Remove from Favorites", systemImage: "star.slash", role: .destructive) {
            library.setFavorite(false, for: item)
        }
    }
}

#Preview("Favorites") {
    NavigationStack {
        FavoritesView(playlistIDs: nil)
            .channelDestinations()
    }
    .fluxoPreviewEnvironment(GuidePreviewData.container)
}

#Preview("No favorites") {
    NavigationStack {
        FavoritesView(playlistIDs: nil)
    }
    .fluxoPreviewEnvironment(PreviewSampleData.makeContainer(withSamples: false))
}
