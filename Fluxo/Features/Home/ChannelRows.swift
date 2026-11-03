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
    case favorites(playlistIDs: [UUID]?)
    case history(playlistIDs: [UUID]?)
}

extension View {
    /// Registers the screens of `ChannelRoute` on the enclosing NavigationStack.
    func channelDestinations() -> some View {
        navigationDestination(for: ChannelRoute.self) { route in
            switch route {
            case let .group(importID, groupName, title):
                ChannelGridView(importID: importID, groupName: groupName, title: title)
            case .favorites(let playlistIDs):
                BookmarkGridView(mode: .favorites, playlistIDs: playlistIDs)
            case .history(let playlistIDs):
                BookmarkGridView(mode: .history, playlistIDs: playlistIDs)
            }
        }
    }
}

/// Title of a Home section with an optional "See all" link.
struct HomeSectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.bold())
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
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
    let route: ChannelRoute
    var count: Int?

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 4) {
                if let count {
                    Text(count.formatted())
                        .foregroundStyle(.secondary)
                }
                Text("See All")
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
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
        name.isEmpty ? "Other" : name
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
    }
}

/// Every channel of a group in a lazy grid, fetched a page at a time as the grid scrolls.
struct ChannelGridView: View {

    static let pageSize = 60

    let importID: UUID
    let groupName: String
    let title: String

    @State private var limit = ChannelGridView.pageSize

    var body: some View {
        ScrollView {
            ChannelGridPage(importID: importID, groupName: groupName, limit: limit) {
                limit += Self.pageSize
            }
            .padding(.horizontal, HomeLayout.horizontalMargin)
            .padding(.vertical)
        }
        .navigationTitle(title)
    }
}

private struct ChannelGridPage: View {

    @Query private var channels: [PlaylistChannel]

    private let limit: Int
    private let onReachEnd: () -> Void

    init(importID: UUID, groupName: String, limit: Int, onReachEnd: @escaping () -> Void) {
        self.limit = limit
        self.onReachEnd = onReachEnd
        _channels = Query(HomeQueries.channels(importID: importID, groupName: groupName, limit: limit))
    }

    var body: some View {
        let usesPosters = !channels.isEmpty && channels.allSatisfy { $0.kind.usesPosterArtwork }
        let minimum = usesPosters ? ChannelPreview.posterSize.width : ChannelPreview.liveSize.width
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: HomeLayout.rowSpacing, alignment: .top)], spacing: 20) {
            ForEach(channels) { channel in
                ChannelPreview(item: ChannelItem(channel))
                    .onAppear {
                        if channels.count >= limit, channel.persistentModelID == channels.last?.persistentModelID {
                            onReachEnd()
                        }
                    }
            }
        }
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
                HomeSectionHeader(title: "Continue Watching", systemImage: "clock.arrow.circlepath") {
                    SeeAllLink(route: .history(playlistIDs: playlistIDs))
                }
                CardRow {
                    ForEach(bookmarks) { bookmark in
                        let item = ChannelItem(bookmark)
                        CompactChannelCard(item: item, watchedAt: bookmark.lastWatchedAt, extraActions: [
                            ChannelCardAction(title: "Remove from History", systemImage: "minus.circle", role: .destructive) {
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

    init(playlistIDs: [UUID]?) {
        self.playlistIDs = playlistIDs
        _bookmarks = Query(HomeQueries.favorites(playlistIDs: playlistIDs, limit: Self.fetchLimit))
    }

    var body: some View {
        if !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionHeader(title: "Favorites", systemImage: "star.fill") {
                    SeeAllLink(route: .favorites(playlistIDs: playlistIDs))
                }
                CardRow {
                    ForEach(bookmarks) { bookmark in
                        ChannelPreview(item: ChannelItem(bookmark))
                    }
                }
            }
        }
    }
}

/// Small glass card for "Continue watching": logo, name and when it was last watched.
struct CompactChannelCard: View {

    static let logoSize = CGSize(width: 56, height: 42)

    let item: ChannelItem
    var watchedAt: Date?
    var extraActions: [ChannelCardAction] = []

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel

    var body: some View {
        Button {
            playChannel(item)
        } label: {
            HStack(spacing: 12) {
                LogoImage(source: item.logo, size: Self.logoSize, accessibilityLabel: item.displayName) { _ in
                    ArtworkPlaceholder(name: item.displayName, kind: item.kind)
                        .scaleEffect(0.7)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let watchedAt {
                        Text(watchedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, alignment: .leading)

                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(CardButtonStyle())
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .contextMenu {
            ChannelContextMenu(item: item, isFavorite: library.isFavorite(item), extraActions: extraActions)
        }
    }
}

/// All favorites or the whole watch history, as a grid. Used by "See all", the Favorites tab and the
/// macOS sidebar.
struct BookmarkGridView: View {

    enum Mode {
        case favorites
        case history
    }

    static let pageSize = 60

    let mode: Mode
    /// nil: every playlist.
    let playlistIDs: [UUID]?

    @State private var limit = BookmarkGridView.pageSize
    @State private var confirmsClear = false
    @Environment(ChannelLibrary.self) private var library

    var body: some View {
        BookmarkGridPage(mode: mode, playlistIDs: playlistIDs, limit: limit) {
            limit += Self.pageSize
        }
        .navigationTitle(mode == .favorites ? "Favorites" : "Recently Watched")
        .toolbar {
            switch mode {
            case .history:
                Button("Clear History", systemImage: "trash") {
                    confirmsClear = true
                }
            case .favorites:
                NavigationLink(value: ChannelRoute.history(playlistIDs: playlistIDs)) {
                    Label("Recently Watched", systemImage: "clock")
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
}

private struct BookmarkGridPage: View {

    @Query private var bookmarks: [ChannelBookmark]

    private let mode: BookmarkGridView.Mode
    private let limit: Int
    private let onReachEnd: () -> Void

    @Environment(ChannelLibrary.self) private var library

    init(mode: BookmarkGridView.Mode, playlistIDs: [UUID]?, limit: Int, onReachEnd: @escaping () -> Void) {
        self.mode = mode
        self.limit = limit
        self.onReachEnd = onReachEnd
        switch mode {
        case .favorites:
            _bookmarks = Query(HomeQueries.favorites(playlistIDs: playlistIDs, limit: limit))
        case .history:
            _bookmarks = Query(HomeQueries.recents(playlistIDs: playlistIDs, limit: limit))
        }
    }

    var body: some View {
        if bookmarks.isEmpty {
            switch mode {
            case .favorites:
                ContentUnavailableView(
                    "No Favorites Yet",
                    systemImage: "star",
                    description: Text("Touch and hold a channel, or right-click it, and choose Add to Favorites.")
                )
            case .history:
                ContentUnavailableView("Nothing Watched Yet", systemImage: "clock", description: Text("Channels you play show up here."))
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: ChannelPreview.liveSize.width), spacing: HomeLayout.rowSpacing, alignment: .top)], spacing: 20) {
                    ForEach(bookmarks) { bookmark in
                        let item = ChannelItem(bookmark)
                        ChannelPreview(item: item, extraActions: extraActions(for: item))
                            .onAppear {
                                if bookmarks.count >= limit, bookmark.persistentModelID == bookmarks.last?.persistentModelID {
                                    onReachEnd()
                                }
                            }
                    }
                }
                .padding(.horizontal, HomeLayout.horizontalMargin)
                .padding(.vertical)
            }
        }
    }

    private func extraActions(for item: ChannelItem) -> [ChannelCardAction] {
        guard mode == .history else {
            return []
        }
        return [
            ChannelCardAction(title: "Remove from History", systemImage: "minus.circle", role: .destructive) {
                library.removeFromHistory(item)
            },
        ]
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

#Preview("Favorites grid") {
    NavigationStack {
        BookmarkGridView(mode: .favorites, playlistIDs: nil)
    }
    .fluxoPreviewEnvironment()
}
