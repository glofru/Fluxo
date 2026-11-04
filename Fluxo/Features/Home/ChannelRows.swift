//
//  ChannelRows.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// Destinations pushed from Home, Search and the library screens.
enum ChannelRoute: Hashable {
    case group(importID: UUID, groupName: String, title: String)
    /// Every category of a kind in the given imports (the category browser).
    case categories(importIDs: [UUID], kind: ChannelContentKind)
    case favorites(playlistIDs: [UUID]?)
    case history(playlistIDs: [UUID]?)
}

extension View {
    /// Registers the screens of `ChannelRoute` on the enclosing NavigationStack. On iOS a group's grid zooms
    /// out of its Home row (or its search category chip).
    func channelDestinations() -> some View {
        modifier(ChannelDestinations())
    }
}

private struct ChannelDestinations: ViewModifier {

    @Namespace private var namespace

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: ChannelRoute.self) { route in
                switch route {
                case let .group(importID, groupName, title):
                    // A fresh screen per route: two group routes pushed at the same depth must not share state.
                    CategoryDetailView(importID: importID, groupName: groupName, title: title)
                        .id(route)
                        .zoomTransition(sourceID: route, in: namespace)
                case let .categories(importIDs, kind):
                    CategoryBrowserView(importIDs: importIDs, kind: kind)
                        .id(route)
                        .zoomTransition(sourceID: route, in: namespace)
                case .favorites(let playlistIDs):
                    FavoritesView(playlistIDs: playlistIDs)
                case .history(let playlistIDs):
                    HistoryView(playlistIDs: playlistIDs)
                }
            }
            // Outside the destination too, so pushed screens can mark sources of their own.
            .environment(\.routeTransitionNamespace, namespace)
    }
}

/// Title of a Home section with an optional "See all" link.
struct HomeSectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility text sizes the "See All" link moves under the title, which may then wrap.
        // Otherwise the title may still take two lines next to the link: translations of titles such as
        // "Because You Watched" are often longer than the English and would be cut off on small iPhones.
        AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.bold())
                        .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 2 : 1)
                    }
                }
            }
            if !dynamicTypeSize.prefersStackedLayout {
                Spacer(minLength: 8)
            }
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HomeLayout.horizontalMargin)
    }
}

extension HomeSectionHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) {
            EmptyView()
        }
    }
}

/// "See all" link shown in section headers.
struct SeeAllLink: View {
    /// What `count` counts, for VoiceOver ("See All, 17 channels").
    enum Unit {
        case channels
        case categories
    }

    let route: ChannelRoute
    var count: Int?
    var unit: Unit = .channels

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 4) {
                if let count {
                    Text(count.formatted())
                        .foregroundStyle(Theme.secondaryText)
                }
                Text("See All")
                Image(systemName: "chevron.forward")
                    .font(.caption.bold())
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .accessibilityButtonShape()
            // A 44 pt tall target around the short text.
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityInputLabels([Text("See All")])
    }

    private var accessibilityLabel: Text {
        guard let count else {
            return Text("See All")
        }
        switch unit {
        case .channels:
            return Text("See All, \(count) channels")
        case .categories:
            return Text("See All, \(count) categories")
        }
    }
}

enum HomeLayout {
    #if os(macOS)
    static let horizontalMargin: CGFloat = 24
    #else
    static let horizontalMargin: CGFloat = 20
    #endif
    static let rowSpacing: CGFloat = 14
}

/// Lazily scrolling horizontal row of cards.
struct CardRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: HomeLayout.rowSpacing) {
                content()
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, HomeLayout.horizontalMargin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

// MARK: - Groups

/// Lightweight value for a group, so rows can be built without keeping the group model around.
struct GroupItem: Identifiable, Hashable, Sendable {
    let importID: UUID
    let playlistID: UUID
    let name: String
    let channelCount: Int
    let kind: ChannelContentKind

    var id: String {
        "\(importID.uuidString)|\(name)"
    }

    var displayName: String {
        name.isEmpty ? String(localized: "Other", comment: "Name of the category that holds the channels without a category.") : name
    }

    init(importID: UUID, playlistID: UUID, name: String, channelCount: Int, kind: ChannelContentKind) {
        self.importID = importID
        self.playlistID = playlistID
        self.name = name
        self.channelCount = channelCount
        self.kind = kind
    }

    init(_ group: PlaylistChannelGroup) {
        importID = group.importID
        playlistID = group.playlistID
        name = group.name
        channelCount = group.channelCount
        kind = group.kind
    }

    var route: ChannelRoute {
        .group(importID: importID, groupName: name, title: displayName)
    }
}

/// Header plus a horizontal row with the first channels of a group. Only `fetchLimit` channels are fetched,
/// so huge groups never load thousands of models for one row.
struct ChannelGroupRow: View {

    static let fetchLimit = 24

    let group: GroupItem
    var playlistName: String?

    @Query private var channels: [PlaylistChannel]

    init(group: GroupItem, playlistName: String?) {
        self.group = group
        self.playlistName = playlistName
        _channels = Query(HomeQueries.channels(importID: group.importID, groupName: group.name, limit: Self.fetchLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader(title: group.displayName, subtitle: playlistName) {
                SeeAllLink(route: group.route, count: group.channelCount)
            }

            CardRow {
                ForEach(channels) { channel in
                    ChannelPreview(item: ChannelItem(channel))
                }
            }
        }
        // "See All" zooms the whole row into the group's grid.
        .routeTransitionSource(group.route)
    }
}

// MARK: - Bookmarks

/// "Continue watching" row: the most recently watched channels of the scope.
struct RecentlyWatchedRow: View {

    static let fetchLimit = 20

    let playlistIDs: [UUID]?

    @Query private var bookmarks: [ChannelBookmark]
    @Environment(ChannelLibrary.self) private var library

    init(playlistIDs: [UUID]?) {
        self.playlistIDs = playlistIDs
        _bookmarks = Query(HomeQueries.recents(playlistIDs: playlistIDs, limit: Self.fetchLimit))
    }

    var body: some View {
        if !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionHeader(title: String(localized: "Continue Watching", comment: "Home page section: videos and channels watched recently."), systemImage: "clock.arrow.circlepath") {
                    SeeAllLink(route: .history(playlistIDs: playlistIDs))
                }
                CardRow {
                    ForEach(bookmarks) { bookmark in
                        let item = ChannelItem(bookmark)
                        CompactChannelCard(item: item, watchedAt: bookmark.lastWatchedAt, extraActions: [
                            ChannelCardAction(title: String(localized: "Remove from History", comment: "Context menu action of a Continue Watching item."), systemImage: "minus.circle", role: .destructive) {
                                library.removeFromHistory(item)
                            },
                        ])
                    }
                }
            }
        }
    }
}

/// "Favorites" row of the scope.
struct FavoritesRow: View {

    static let fetchLimit = 20

    let playlistIDs: [UUID]?

    @Query private var bookmarks: [ChannelBookmark]
    @Environment(ChannelLibrary.self) private var library
    /// A channel is dragged over the row (it becomes a favorite when dropped).
    @State private var isDropTarget = false

    init(playlistIDs: [UUID]?) {
        self.playlistIDs = playlistIDs
        _bookmarks = Query(HomeQueries.favorites(playlistIDs: playlistIDs, limit: Self.fetchLimit))
    }

    var body: some View {
        if !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionHeader(title: String(localized: "Favorites", comment: "Home page section: the favorite channels."), systemImage: "star.fill") {
                    SeeAllLink(route: .favorites(playlistIDs: playlistIDs))
                }
                CardRow {
                    ForEach(bookmarks) { bookmark in
                        ChannelPreview(item: ChannelItem(bookmark))
                    }
                }
            }
            .padding(.vertical, 6)
            .background {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Theme.favorite.opacity(0.12))
                        .strokeBorder(Theme.favorite.opacity(0.6), lineWidth: 2)
                        .padding(.horizontal, 8)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, -6)
            .animation(.easeInOut(duration: 0.2), value: isDropTarget)
            // Drag a channel card here to add it to the favorites (iPad, macOS).
            .favoritesDropDestination(library: library, isTargeted: $isDropTarget)
        }
    }
}

/// Card of "Continue Watching": the artwork, the name, and how far a movie or episode was watched (a progress
/// bar and the time left), or what a live channel shows now; otherwise when it was last watched.
struct CompactChannelCard: View {

    static let logoSize = CGSize(width: 78, height: 52)
    static let posterSize = CGSize(width: 52, height: 78)
    static let width: CGFloat = 272

    let item: ChannelItem
    var watchedAt: Date?
    var extraActions: [ChannelCardAction] = []

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sourceID = UUID().uuidString
    private var scale = CardScale(maximum: 1.25)

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        let progress = library.watchProgress(for: item)
        let isFavorite = library.isFavorite(item)
        Button {
            playChannel(item, from: sourceID)
        } label: {
            HStack(spacing: 12) {
                ChannelLogoTile(item: item, size: item.kind.usesPosterArtwork ? Self.posterSize : Self.logoSize, cornerRadius: 10)
                    // The name follows as text.
                    .accessibilityHidden(true)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Theme.accentFill, in: .circle)
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1)
                            }
                            .padding(4)
                            .accessibilityHidden(true)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    // Two lines: long IPTV names ("Test Pattern (MPEG-TS)") stay readable on small phones.
                    Text(item.displayName)
                        .font(Theme.Typography.cardTitle)
                        .lineLimit(CardTextMetrics.titleLineLimit(2, at: dynamicTypeSize))
                        .fixedSize(horizontal: false, vertical: true)

                    if let progress {
                        ProgrammeProgressBar(progress: progress.fraction, tint: Theme.accent, height: 4)
                        Text(WatchProgressFormat.remaining(progress))
                            .font(Theme.Typography.cardSubtitle.monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                    } else if item.kind == .live {
                        NowNextReader(item: item) { nowNext in
                            if let current = nowNext?.current {
                                HStack(spacing: 5) {
                                    LiveBadge(compact: true)
                                    Text(current.title)
                                        .font(Theme.Typography.cardSubtitle)
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(CardTextMetrics.titleLineLimit(1, at: dynamicTypeSize))
                                }
                            } else if let watchedAt {
                                lastWatched(watchedAt)
                            }
                        }
                    } else if let watchedAt {
                        lastWatched(watchedAt)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(width: scale.scaled(Self.width), alignment: .leading)
            .frame(minHeight: 72)
            // A content surface: glass is kept for the controls and navigation layer.
            .background(Theme.surface, in: shape)
            .overlay {
                shape.strokeBorder(Theme.surfaceStroke)
            }
            .contentShape(shape)
            .playerTransitionSource(id: sourceID, cornerRadius: 20)
        }
        .buttonStyle(CardButtonStyle())
        .cardHoverEffect()
        .contextMenu {
            ChannelContextMenu(item: item, isFavorite: library.isFavorite(item), extraActions: extraActions)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isFavorite ? ChannelAccessibility.favoriteState : "")
        .accessibilityHint(item.kind == .live ? "Plays the channel" : "Resumes the video")
        .channelAccessibilityActions(item, isFavorite: isFavorite)
    }

    private func lastWatched(_ date: Date) -> some View {
        Text(date, format: .relative(presentation: .named))
            .font(Theme.Typography.cardSubtitle)
            .foregroundStyle(Theme.secondaryText)
    }
}

/// The watch history, newest first, in sections by day ("Today", "Yesterday", …), with how far movies and
/// episodes were watched and what live channels show now. Used by "See All", Favorites and the macOS sidebar.
struct HistoryView: View {

    /// nil: every playlist.
    let playlistIDs: [UUID]?

    @Query private var bookmarks: [ChannelBookmark]
    @State private var confirmsClear = false
    @Environment(ChannelLibrary.self) private var library

    init(playlistIDs: [UUID]?) {
        self.playlistIDs = playlistIDs
        _bookmarks = Query(HomeQueries.recents(playlistIDs: playlistIDs, limit: ChannelLibrary.historyLimit))
    }

    var body: some View {
        Group {
            if bookmarks.isEmpty {
                ContentUnavailableView("Nothing Watched Yet", systemImage: "clock", description: Text("Channels, movies and series you play show up here."))
            } else {
                List {
                    ForEach(days, id: \.day) { day in
                        Section(GuideFormat.day(day.day)) {
                            ForEach(day.entries, id: \.key) { entry in
                                let item = ChannelItem(entry)
                                ChannelListRow(
                                    item: item,
                                    subtitle: subtitle(for: entry),
                                    showsNumber: false,
                                    extraActions: [
                                        ChannelCardAction(title: String(localized: "Remove from History"), systemImage: "minus.circle", role: .destructive) {
                                            library.removeFromHistory(item)
                                        },
                                    ]
                                )
                            }
                            .onDelete { offsets in
                                for offset in offsets {
                                    library.removeFromHistory(ChannelItem(day.entries[offset]))
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
            }
        }
        .navigationTitle("Recently Watched")
        .toolbar {
            if !bookmarks.isEmpty {
                Button("Clear History", systemImage: "trash") {
                    confirmsClear = true
                }
            }
        }
        .confirmationDialog("Clear the watch history?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive) {
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

    private func subtitle(for bookmark: ChannelBookmark) -> String {
        var parts: [String] = []
        if let watchedAt = bookmark.lastWatchedAt {
            parts.append(GuideFormat.time(watchedAt))
        }
        if !bookmark.groupName.isEmpty {
            parts.append(bookmark.groupName)
        }
        if bookmark.watchCount > 1 {
            parts.append(String(localized: "Watched \(bookmark.watchCount) times"))
        }
        return TextParts.line(parts)
    }
}

#Preview("Group row") {
    NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RecentlyWatchedRow(playlistIDs: nil)
                FavoritesRow(playlistIDs: nil)
                ChannelGroupRow(group: PreviewSampleData.firstGroup(), playlistName: "Freeview")
            }
        }
        .channelDestinations()
    }
    .fluxoPreviewEnvironment()
}

#Preview("History") {
    NavigationStack {
        HistoryView(playlistIDs: nil)
    }
    .fluxoPreviewEnvironment()
}
