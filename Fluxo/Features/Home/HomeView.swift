//
//  HomeView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// The Home screen: playlist switcher, featured carousel, Continue Watching, Favorites and the
/// Live TV / Movies / Series sections, all filtered by the selected playlist (or every playlist).
///
/// Everything below the header is lazy: group rows are fetched a page at a time as they scroll in, and each
/// row fetches only its first channels.
struct HomeView: View {

    let player: AVPlayerViewModel
    /// The macOS sidebar lists the playlists itself, so it hides the switcher.
    var showsPlaylistSwitcher = true

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""

    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter

    @AppStorage("home.contentKind") private var kindRawValue = ChannelContentKind.live.rawValue
    @State private var showsRecordings = false
    /// Number of groups per content kind in the scope; nil until counted.
    @State private var groupCounts: [ChannelContentKind: Int]?

    private var scope: LibraryScope {
        LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
    }

    var body: some View {
        let scope = scope
        NavigationStack {
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
            .toolbar {
                toolbarContent(scope: scope)
            }
            .channelDestinations()
        }
        #if !os(macOS)
        .sheet(isPresented: $showsRecordings) {
            RecordingsView(store: player.recordings, isRecordingActive: player.isRecording) { recording in
                showsRecordings = false
                player.playRecording(recording)
            }
        }
        #endif
    }

    private func content(scope: LibraryScope) -> some View {
        let available = ChannelContentKind.allCases.filter { (groupCounts?[$0] ?? 0) > 0 }
        let kind = available.first { $0.rawValue == kindRawValue } ?? available.first
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if showsPlaylistSwitcher {
                    PlaylistSwitcher(playlists: playlists, selection: selectionBinding(scope: scope))
                }

                PlaylistStatusBanner(playlists: playlistsInScope(scope))

                FeaturedCarousel(importIDs: scope.importIDs)

                RecentlyWatchedRow(playlistIDs: scope.bookmarkFilter)
                    .id(scope.bookmarkFilter)

                FavoritesRow(playlistIDs: scope.bookmarkFilter)
                    .id(scope.bookmarkFilter)

                if let kind {
                    ContentKindHeader(available: available, kind: kindBinding(current: kind))

                    GroupRows(scope: scope, kind: kind)
                        .id(GroupRowsIdentity(importIDs: scope.importIDs, kind: kind))
                } else if groupCounts != nil && !scope.importIDs.isEmpty {
                    ContentUnavailableView("No Channels", systemImage: "tv.slash", description: Text("This playlist has no channels."))
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .task(id: scope.importIDs) {
            groupCounts = countGroups(importIDs: scope.importIDs)
        }
        .refreshable {
            for playlist in playlistsInScope(scope) {
                importCenter.refresh(playlist)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(scope: LibraryScope) -> some ToolbarContent {
        #if !os(macOS)
        ToolbarItem {
            Button("Recordings", systemImage: "film.stack") {
                showsRecordings = true
            }
        }
        #endif
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
        return "Home"
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
struct PlaylistSwitcher: View {

    let playlists: [Playlist]
    @Binding var selection: PlaylistSelection

    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Namespace private var namespace

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(title: "All Playlists", systemImage: "square.stack.fill", isSelected: selection == .all, isUpdating: false) {
                        selection = .all
                    }

                    ForEach(playlists) { playlist in
                        chip(
                            title: playlist.name,
                            systemImage: nil,
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
                            .accessibilityLabel("Add Playlist")
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                }
            }
            .padding(.vertical, 4)
        }
        .contentMargins(.horizontal, HomeLayout.horizontalMargin, for: .scrollContent)
        .scrollIndicators(.hidden)
        .animation(.snappy, value: selection)
    }

    private func chip(title: String, systemImage: String?, isSelected: Bool, isUpdating: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
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
        .glassEffect(isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
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
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                                .font(.subheadline.weight(.semibold))
                            Text("No channels yet. Refresh to download them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .padding(.horizontal, HomeLayout.horizontalMargin)
        }
    }
}

/// First launch: no playlist yet.
struct HomeEmptyState: View {

    let onAddPlaylist: () -> Void

    @State private var animates = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(colors: [.accentColor, .purple, .pink, .orange, .accentColor], center: .center)
                    )
                    .frame(width: 150, height: 150)
                    .blur(radius: 40)
                    .opacity(0.7)
                    .rotationEffect(.degrees(animates ? 360 : 0))

                Image(systemName: "play.tv.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 120, height: 120)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.6)), in: .circle)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 8) {
                Text("Welcome to Fluxo")
                    .font(.largeTitle.bold())
                Text("Add an M3U playlist to watch live TV, movies and series. You can add as many playlists as you like and switch between them here.")
                    .font(.body)
                    .foregroundStyle(.secondary)
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
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
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
                    Label(kind.title, systemImage: kind.systemImage)
                        .tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, HomeLayout.horizontalMargin)
        } else {
            HomeSectionHeader(title: kind.title, systemImage: kind.systemImage)
        }
    }
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
