//
//  MacRootView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// Sidebar entries of the macOS window.
enum SidebarItem: Hashable {
    case home
    case guide
    case search
    case favorites
    case history
    case recordings
    case playlist(UUID)
}

/// macOS layout: a sidebar with Home, TV Guide, Search, Favorites, Recently Watched, Recordings and every playlist,
/// and the selected screen as the detail. Selecting a playlist shows Home filtered to it.
struct MacRootView: View {

    let player: AVPlayerViewModel

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""
    @State private var sidebarSelection: SidebarItem? = .home

    var body: some View {
        NavigationSplitView {
            MacSidebar(playlists: playlists, selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                .id(sidebarSelection)
                .playerAccessory(isVisible: player.currentChannel != nil) {
                    PlayerBottomAccessory(viewModel: player)
                }
        }
        .onAppear {
            if case .playlist(let uuid) = PlaylistSelection(rawValue: selectionRawValue).resolved(in: playlists) {
                sidebarSelection = .playlist(uuid)
            }
            #if DEBUG
            if DebugGuideDemo.opensGuide {
                sidebarSelection = .guide
            } else if DebugGuideDemo.opensFavorites {
                sidebarSelection = .favorites
            }
            #endif
        }
        .onChange(of: sidebarSelection) { _, item in
            switch item {
            case .home:
                selectionRawValue = PlaylistSelection.all.rawValue
            case .playlist(let uuid):
                selectionRawValue = PlaylistSelection.playlist(uuid).rawValue
            default:
                break
            }
        }
        .onChange(of: selectionRawValue) { _, rawValue in
            // Keep the sidebar in step when the selection changes elsewhere (e.g. a deleted playlist).
            guard sidebarSelection == .home || sidebarSelection.isPlaylist else {
                return
            }
            let selection = PlaylistSelection(rawValue: rawValue)
            let item: SidebarItem
            switch selection {
            case .all:
                item = .home
            case .playlist(let uuid):
                item = .playlist(uuid)
            }
            if sidebarSelection != item {
                sidebarSelection = item
            }
        }
        .onChange(of: playlists.map(\.uuid)) { _, uuids in
            if case .playlist(let uuid) = sidebarSelection, !uuids.contains(uuid) {
                sidebarSelection = .home
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch sidebarSelection ?? .home {
        case .home, .playlist:
            HomeView(player: player, showsPlaylistSwitcher: false)
        case .guide:
            GuideView()
        case .search:
            SearchView()
        case .favorites:
            NavigationStack {
                BookmarkGridView(mode: .favorites, playlistIDs: nil)
                    .channelDestinations()
            }
        case .history:
            NavigationStack {
                BookmarkGridView(mode: .history, playlistIDs: nil)
                    .channelDestinations()
            }
        case .recordings:
            RecordingsView(store: player.recordings, isRecordingActive: player.isRecording, showsDoneButton: false) { recording in
                player.playRecording(recording)
            }
        }
    }
}

private extension Optional where Wrapped == SidebarItem {
    var isPlaylist: Bool {
        if case .playlist = self {
            return true
        }
        return false
    }
}

private struct MacSidebar: View {

    let playlists: [Playlist]
    @Binding var selection: SidebarItem?

    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Home", systemImage: "play.tv")
                    .tag(SidebarItem.home)
                Label("TV Guide", systemImage: "calendar.day.timeline.left")
                    .tag(SidebarItem.guide)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                Label("Favorites", systemImage: "star")
                    .tag(SidebarItem.favorites)
                Label("Recently Watched", systemImage: "clock")
                    .tag(SidebarItem.history)
                Label("Recordings", systemImage: "film.stack")
                    .tag(SidebarItem.recordings)
            }

            Section("Playlists") {
                if playlists.isEmpty {
                    Text("No playlists yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(playlists) { playlist in
                    PlaylistSidebarRow(playlist: playlist, progress: importCenter.progress[playlist.uuid])
                        .tag(SidebarItem.playlist(playlist.uuid))
                        .contextMenu {
                            PlaylistMenuItems(playlist: playlist)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                actions.add()
            } label: {
                Label("Add Playlist", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(12)
        }
    }
}

private struct PlaylistSidebarRow: View {
    let playlist: Playlist
    let progress: PlaylistImportProgress?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .lineLimit(1)
                if let progress {
                    Text(progress.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if playlist.currentImportID != nil {
                    Text("\(playlist.channelCount.formatted()) channels")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No channels yet")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } icon: {
            if progress != nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "list.bullet.rectangle")
            }
        }
    }
}

#Preview {
    MacRootView(player: AVPlayerViewModel())
        .fluxoPreviewEnvironment()
}
