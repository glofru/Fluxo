//
//  HomeView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// The Home screen: featured billboard, playlist switcher, Continue Watching (with the progress of movies and
/// episodes), On Now (from the TV guide), Favorites, Because You Watched, then the Live TV / Movies / Series
/// sections: a strip of category cards and a row per category. Everything follows the selected playlist (or
/// every playlist).
///
/// Everything below the header is lazy: group rows are fetched a page at a time as they scroll in, and each
/// row fetches only its first channels.
struct HomeView: View {

    let player: AVPlayerViewModel
    /// The macOS sidebar lists the playlists itself, so it hides the switcher.
    var showsPlaylistSwitcher = true
    /// iPad sidebar: Home of one playlist, whatever Home's own playlist selection is. It has its own navigation
    /// path (the shared one belongs to the Home tab), and no switcher.
    var fixedPlaylistID: UUID?

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""

    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter
    /// The navigation path.
    @Environment(AppNavigation.self) private var navigation

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("home.contentKind") private var kindRawValue = ChannelContentKind.live.rawValue
    /// Number of groups per content kind in the scope; nil until counted.
    @State private var groupCounts: [ChannelContentKind: Int]?
    /// iOS: the billboard runs under the toolbar; the title fades in once it has scrolled away.
    @State private var isShowingBillboard = false
    @State private var isScrolledPastHero = false
    /// Navigation path of a playlist's Home (`fixedPlaylistID`).
    @State private var playlistPath = NavigationPath()

    private var scope: LibraryScope {
        if let fixedPlaylistID {
            return LibraryScope(playlists: playlists, selection: .playlist(fixedPlaylistID))
        }
        return LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
    }

    private var path: Binding<NavigationPath> {
        if fixedPlaylistID != nil {
            return $playlistPath
        }
        @Bindable var navigation = navigation
        return $navigation.homePath
    }

    private var showsSwitcher: Bool {
        showsPlaylistSwitcher && fixedPlaylistID == nil
    }

    var body: some View {
        let scope = scope
        NavigationStack(path: path) {
            Group {
                if playlists.isEmpty {
                    HomeEmptyState {
                        actions.add()
                    }
                } else {
                    content(scope: scope)
                }
            }
            .navigationTitle(title(for: scope))
            #if os(iOS)
            .toolbarTitleDisplayMode(playlists.isEmpty ? .large : .inline)
            #endif
            .toolbar {
                toolbarContent(scope: scope)
            }
            .channelDestinations()
        }
    }

    @ViewBuilder
    private func content(scope: LibraryScope) -> some View {
        #if os(iOS)
        // The billboard runs under the status bar and the floating toolbar: the scroll view ignores the top
        // safe area, and the billboard adds it back as its own height.
        GeometryReader { proxy in
            scrollContent(scope: scope, topInset: proxy.safeAreaInsets.top)
                .ignoresSafeArea(edges: .top)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let threshold = isShowingBillboard ? FeaturedCarousel.billboardHeight(for: dynamicTypeSize) - 40 : 24
                    return geometry.contentOffset.y + geometry.contentInsets.top > threshold
                } action: { _, isPast in
                    isScrolledPastHero = isPast
                }
        }
        #else
        scrollContent(scope: scope, topInset: 0)
        #endif
    }

    private func scrollContent(scope: LibraryScope, topInset: CGFloat) -> some View {
        let available = ChannelContentKind.allCases.filter { (groupCounts?[$0] ?? 0) > 0 }
        let kind = available.first { $0.rawValue == kindRawValue } ?? available.first
        let isOffline = NetworkMonitor.shared.isOffline
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    // Offline, the featured pages are only downloads, and the downloads row comes first: what
                    // plays without a network is at the top.
                    #if os(iOS)
                    FeaturedCarousel(importIDs: scope.importIDs, style: .billboard, topInset: topInset, isShowingBillboard: $isShowingBillboard)
                        .padding(.bottom, -12)

                    OfflineHomeSection()

                    if showsSwitcher {
                        PlaylistSwitcher(playlists: playlists, selection: selectionBinding(scope: scope))
                    }
                    #else
                    OfflineHomeSection()

                    if showsSwitcher {
                        PlaylistSwitcher(playlists: playlists, selection: selectionBinding(scope: scope))
                    }

                    FeaturedCarousel(importIDs: scope.importIDs)
                    #endif

                    PlaylistStatusBanner(playlists: playlistsInScope(scope))

                    RecentlyWatchedRow(playlistIDs: scope.bookmarkFilter)
                        .id(scope.bookmarkFilter)

                    // Offline, the suggestions and what is on now (streams) give way to the downloads above.
                    if !isOffline {
                        ForYouRow(scope: scope)
                            .id(HomeSection.forYou)

                        OnNowRow(scope: scope)
                            .id(HomeSection.onNow)
                    }

                    FavoritesRow(playlistIDs: scope.bookmarkFilter)
                        .id(scope.bookmarkFilter)

                    if !isOffline {
                        BecauseYouWatchedRow(scope: scope)
                            .id(scope.importIDs)
                    }

                    if let kind {
                        ContentKindHeader(available: available, kind: kindBinding(current: kind))
                            .id(HomeSection.browse)

                        CategoryStrip(scope: scope, kind: kind, totalCount: groupCounts?[kind] ?? 0)
                            .id(CategoryStripIdentity(rows: GroupRowsIdentity(importIDs: scope.importIDs, kind: kind)))

                        GroupRows(scope: scope, kind: kind)
                            .id(GroupRowsIdentity(importIDs: scope.importIDs, kind: kind))
                    } else if groupCounts != nil && !scope.importIDs.isEmpty {
                        ContentUnavailableView("No Channels", systemImage: "tv.slash", description: Text("This playlist has no channels."))
                    }
                }
                #if os(iOS)
                .padding(.bottom, 12)
                #else
                .padding(.vertical, 12)
                #endif
                #if DEBUG
                // Debug harness: the content as if Home were pulled down (rubber-band overscroll).
                .offset(y: navigation.debugHomeOverscroll)
                #endif
            }
            .scrollIndicators(.hidden)
            .softScrollEdge()
            #if DEBUG
            // Debug harness (`home-section:<name>`): scrolls to a section for screenshots.
            .onChange(of: navigation.debugHomeSection) { _, section in
                if let section = section.flatMap(HomeSection.init(rawValue:)) {
                    proxy.scrollTo(section, anchor: UnitPoint(x: 0.5, y: 0.1))
                }
            }
            #endif
        }
        .task(id: scope.importIDs) {
            groupCounts = countGroups(importIDs: scope.importIDs)
        }
        .forYouRecommendations(scope: scope)
        .refreshable {
            for playlist in playlistsInScope(scope) {
                importCenter.refresh(playlist)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(scope: LibraryScope) -> some ToolbarContent {
        #if os(iOS)
        if !playlists.isEmpty {
            // The inline title only shows once the billboard has scrolled under the toolbar.
            ToolbarItem(placement: .principal) {
                Text(title(for: scope))
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(isScrolledPastHero ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isScrolledPastHero)
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        #endif
        // The recordings are in the Library tab (iOS) and the Library section of the sidebar (macOS).
        ToolbarItem {
            Menu("Playlists", systemImage: "ellipsis") {
                Button("Add Playlist", systemImage: "plus") {
                    actions.add()
                }
                if case .playlist = scope.selection, let playlist = playlistsInScope(scope).first {
                    Section(playlist.name) {
                        PlaylistMenuItems(playlist: playlist)
                    }
                } else if !playlists.isEmpty {
                    Button("Refresh All", systemImage: "arrow.clockwise") {
                        playlists.forEach(importCenter.refresh)
                    }
                }
            }
        }
    }

    @Environment(\.modelContext) private var modelContext

    /// Three indexed counts; cheap enough for the main context.
    private func countGroups(importIDs: [UUID]) -> [ChannelContentKind: Int] {
        var counts: [ChannelContentKind: Int] = [:]
        for kind in ChannelContentKind.allCases {
            counts[kind] = (try? modelContext.fetchCount(HomeQueries.groupCount(importIDs: importIDs, kind: kind))) ?? 0
        }
        return counts
    }

    private func kindBinding(current: ChannelContentKind) -> Binding<ChannelContentKind> {
        Binding(get: { current }, set: { kindRawValue = $0.rawValue })
    }

    private func title(for scope: LibraryScope) -> String {
        if case .playlist = scope.selection, let name = scope.playlistNames.values.first {
            return name
        }
        return String(localized: "Home", comment: "Title of the Home page.")
    }

    private func playlistsInScope(_ scope: LibraryScope) -> [Playlist] {
        playlists.filter { scope.playlistIDs.contains($0.uuid) }
    }

    private func selectionBinding(scope: LibraryScope) -> Binding<PlaylistSelection> {
        Binding(
            get: { scope.selection },
            set: { selectionRawValue = $0.rawValue }
        )
    }
}

// MARK: - Playlist switcher

/// Horizontally scrolling glass chips: "All" plus one per playlist, and a chip to add one.
/// Each playlist chip has the playlist's refresh / rename / delete actions in its context menu.
///
/// The chips share one `GlassEffectContainer`, and the tinted selection glass carries the same
/// `glassEffectID` from chip to chip, so changing the selection morphs the tint across the bar.
struct PlaylistSwitcher: View {

    private static let selectionGlassID = "switcher.selection"
    private static let allGlassID = "switcher.all"
    private static let addGlassID = "switcher.add"

    let playlists: [Playlist]
    @Binding var selection: PlaylistSelection

    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(title: String(localized: "All Playlists", comment: "Home page playlist switcher: show every playlist."), systemImage: "square.stack.fill", glassID: Self.allGlassID, isSelected: selection == .all, isUpdating: false) {
                        selection = .all
                    }

                    ForEach(playlists) { playlist in
                        chip(
                            title: playlist.name,
                            systemImage: nil,
                            glassID: playlist.uuid.uuidString,
                            isSelected: selection == .playlist(playlist.uuid),
                            isUpdating: importCenter.progress[playlist.uuid] != nil
                        ) {
                            selection = .playlist(playlist.uuid)
                        }
                        .contextMenu {
                            PlaylistMenuItems(playlist: playlist)
                        }
                    }

                    Button {
                        actions.add()
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.bold())
                            .frame(width: 20, height: 20)
                            .padding(8)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID(Self.addGlassID, in: glassNamespace)
                    .accessibilityLabel("Add Playlist")
                }
            }
            .padding(.vertical, 4)
        }
        .contentMargins(.horizontal, HomeLayout.horizontalMargin, for: .scrollContent)
        .scrollIndicators(.hidden)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func chip(title: String, systemImage: String?, glassID: String, isSelected: Bool, isUpdating: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SelectionCheckmark(isSelected: isSelected)
                if isUpdating {
                    ProgressView()
                        .controlSize(.mini)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(Theme.accentFill).interactive() : .regular.interactive(), in: .capsule)
        .glassEffectID(isSelected ? Self.selectionGlassID : glassID, in: glassNamespace)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Status and empty states

/// Progress of running imports, and a prompt for playlists that have no channels yet.
private struct PlaylistStatusBanner: View {

    let playlists: [Playlist]

    @Environment(PlaylistImportCenter.self) private var importCenter

    var body: some View {
        let updating = playlists.filter { importCenter.progress[$0.uuid] != nil }
        let empty = playlists.filter { $0.currentImportID == nil && importCenter.progress[$0.uuid] == nil }
        if !updating.isEmpty || !empty.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(updating) { playlist in
                    if let progress = importCenter.progress[playlist.uuid] {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Updating \(playlist.name)")
                                    .font(.subheadline.weight(.semibold))
                                PlaylistImportProgressView(progress: progress)
                                    .font(.caption)
                            }
                            Button("Cancel", systemImage: "xmark") {
                                importCenter.cancelImport(for: playlist.uuid)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                        }
                    }
                }

                ForEach(empty) { playlist in
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.title3)
                            .foregroundStyle(Theme.warning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                                .font(.subheadline.weight(.semibold))
                            Text("No channels yet. Refresh to download them.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            importCenter.refresh(playlist)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(16)
            // Content, not a control layer: a plain surface rather than glass.
            .background(Theme.surface, in: .rect(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, HomeLayout.horizontalMargin)
        }
    }
}

/// First launch: no playlist yet.
struct HomeEmptyState: View {

    let onAddPlaylist: () -> Void

    @State private var animates = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(colors: [Theme.accent, Theme.cyan, Theme.lilac, Theme.pink, Theme.accent], center: .center)
                    )
                    .frame(width: 150, height: 150)
                    .blur(radius: 40)
                    .opacity(0.7)
                    .rotationEffect(.degrees(animates ? 360 : 0))

                Image(systemName: "play.tv.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 120, height: 120)
                    .glassEffect(.regular.tint(Theme.accent.opacity(0.6)), in: .circle)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 8) {
                Text("Welcome to Fluxo")
                    .font(.largeTitle.bold())
                Text("Add an M3U playlist to watch live TV, movies and series. You can add as many playlists as you like and switch between them here.")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button {
                onAddPlaylist()
            } label: {
                Label("Add Playlist", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accentFill)
            .controlSize(.large)

            // The playlists of the user's other devices (iCloud sync).
            CloudSyncWelcomeNote()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !reduceMotion else {
                return
            }
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                animates = true
            }
        }
    }
}

// MARK: - Live TV / Movies / Series

/// The Live TV / Movies / Series picker (or a plain title when the scope has a single kind).
private struct ContentKindHeader: View {

    let available: [ChannelContentKind]
    @Binding var kind: ChannelContentKind

    var body: some View {
        if available.count > 1 {
            Picker("Content", selection: $kind) {
                ForEach(available) { kind in
                    Label(kind.segmentTitle, systemImage: kind.systemImage)
                        .tag(kind)
                }
            }
            .segmentedPickerStyleAdaptingToTextSize()
            .labelsHidden()
            .padding(.horizontal, HomeLayout.horizontalMargin)
        } else {
            HomeSectionHeader(title: kind.title, systemImage: kind.systemImage)
        }
    }
}

/// Sections of Home that can be scrolled to.
enum HomeSection: String {
    case forYou
    case onNow
    case browse
}

private struct CategoryStripIdentity: Hashable {
    let rows: GroupRowsIdentity
}

private struct GroupRowsIdentity: Hashable {
    let importIDs: [UUID]
    let kind: ChannelContentKind
}

/// Group rows of one kind, fetched `pageSize` groups at a time when the last loaded row appears.
private struct GroupRows: View {

    static let pageSize = 8

    let scope: LibraryScope
    let kind: ChannelContentKind

    @State private var limit = GroupRows.pageSize

    var body: some View {
        GroupRowsPage(scope: scope, kind: kind, limit: limit) {
            limit += Self.pageSize
        }
    }
}

private struct GroupRowsPage: View {

    @Query private var groups: [PlaylistChannelGroup]

    private let scope: LibraryScope
    private let limit: Int
    private let onReachEnd: () -> Void

    init(scope: LibraryScope, kind: ChannelContentKind, limit: Int, onReachEnd: @escaping () -> Void) {
        self.scope = scope
        self.limit = limit
        self.onReachEnd = onReachEnd
        _groups = Query(HomeQueries.groups(importIDs: scope.importIDs, kind: kind, limit: limit))
    }

    var body: some View {
        ForEach(groups) { group in
            ChannelGroupRow(
                group: GroupItem(group),
                playlistName: scope.showsPlaylistNames ? scope.playlistNames[group.playlistID] : nil
            )
            .onAppear {
                if groups.count >= limit, group.persistentModelID == groups.last?.persistentModelID {
                    onReachEnd()
                }
            }
        }
    }
}

#Preview("Home") {
    HomeView(player: AVPlayerViewModel())
        .fluxoPreviewEnvironment()
}

#Preview("Empty") {
    HomeView(player: AVPlayerViewModel())
        .fluxoPreviewEnvironment(PreviewSampleData.makeContainer(withSamples: false))
}
