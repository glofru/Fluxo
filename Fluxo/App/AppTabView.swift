//
//  AppTabView.swift
//  Fluxo
//
//  The iOS root: a native TabView. On iPhone it is the tab bar (Home, Guide, Favorites, Settings and Search).
//  On iPad it is a sidebar-adaptable tab view: the sidebar (shown by default in a regular width window) adds
//  Recently Watched, Recordings and a Playlists section with the Home of each playlist and an Add Playlist button;
//  the sidebar collapses into the floating tab bar, and the user can pin sidebar entries to the tab bar
//  (tab customization, kept across launches). Narrow iPad windows (Slide Over, a third of Split View) are compact
//  and use the iPhone tab bar.
//

#if os(iOS)
import SwiftData
import SwiftUI

struct AppTabView: View {

    let player: AVPlayerViewModel

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @Environment(AppNavigation.self) private var navigation
    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(ChannelLibrary.self) private var library
    /// Which sidebar entries the user moved into (or out of) the iPad tab bar, and their order.
    @AppStorage("tabs.customization") private var customization = TabViewCustomization()

    var body: some View {
        if DeviceIdiom.isPad {
            // A window wide enough for the sidebar next to the content (iPad in landscape, a large window) starts
            // with the sidebar; a narrower one with the tab bar, where the sidebar would cover the content. The
            // tab view reads its default placement once, when it is created, so the size must be known in the
            // very first layout: a GeometryReader has it then, while a size reported after the first layout
            // (onGeometryChange) can come too late, and the tab bar would show.
            GeometryReader { proxy in
                let isWide = Self.isWide(proxy.size)
                tabView
                    .tabViewStyle(.sidebarAdaptable)
                    .tabViewCustomization($customization)
                    .defaultAdaptableTabBarPlacement(isWide ? .sidebar : .tabBar)
                    .onChange(of: isWide, initial: true) { _, isWide in
                        navigation.isWideWindow = isWide
                    }
            }
        } else {
            tabView
        }
    }

    /// Room for the sidebar, or the schedule inspector, next to a usable content area: a landscape window at
    /// least 1,100 pt wide (iPad Pro and iPad Air in landscape, iPad mini in landscape).
    static func isWide(_ size: CGSize) -> Bool {
        size.width >= 1_100 && size.width > size.height
    }

    private var tabView: some View {
        @Bindable var navigation = navigation
        return TabView(selection: $navigation.tab) {
            Tab("Home", systemImage: "play.tv", value: AppNavigation.Tab.home) {
                HomeView(player: player)
                    .channelScheduleInspector()
            }
            .customizationID("tab.home")
            .customizationBehavior(.disabled, for: .sidebar, .tabBar)

            Tab("Guide", systemImage: "calendar.day.timeline.left", value: AppNavigation.Tab.guide) {
                GuideView()
            }
            .customizationID("tab.guide")

            Tab("Favorites", systemImage: "star", value: AppNavigation.Tab.favorites) {
                NavigationStack(path: $navigation.favoritesPath) {
                    FavoritesView(playlistIDs: nil)
                        .channelDestinations()
                }
                .channelScheduleInspector()
            }
            .customizationID("tab.favorites")
            // Drop a channel on Favorites in the sidebar or the tab bar to add it; hovering opens the tab.
            .dropDestination(for: ChannelTransfer.self) { channels in
                ChannelTransfer.addToFavorites(channels, library: library)
            }
            .springLoadingBehavior(.enabled)

            // iPad sidebar only (iPhone reaches them from Home and Favorites). Not even declared on iPhone: its
            // plain tab bar would move them, and Settings, into a More tab.
            if DeviceIdiom.isPad {
                Tab("Recently Watched", systemImage: "clock", value: AppNavigation.Tab.history) {
                    NavigationStack {
                        HistoryView(playlistIDs: nil)
                            .channelDestinations()
                    }
                    .channelScheduleInspector()
                }
                .customizationID("tab.history")
                .defaultVisibility(.hidden, for: .tabBar)

                Tab("Recordings", systemImage: "film.stack", value: AppNavigation.Tab.recordings) {
                    RecordingsView(store: player.recordings, isRecordingActive: player.isRecording, showsDoneButton: false) { recording in
                        player.playRecording(recording)
                    }
                }
                .customizationID("tab.recordings")
                .defaultVisibility(.hidden, for: .tabBar)

                TabSection("Playlists") {
                    ForEach(playlists) { playlist in
                        Tab(value: AppNavigation.Tab.playlist(playlist.uuid)) {
                            HomeView(player: player, fixedPlaylistID: playlist.uuid)
                                .channelScheduleInspector()
                        } label: {
                            PlaylistTabLabel(playlist: playlist, isUpdating: importCenter.progress[playlist.uuid] != nil)
                        }
                        .customizationID("playlist.\(playlist.uuid.uuidString)")
                        .contextMenu {
                            PlaylistMenuItems(playlist: playlist)
                        }
                    }
                }
                .customizationID("section.playlists")
                .defaultVisibility(.hidden, for: .tabBar)
                .sectionActions {
                    Button("Add Playlist", systemImage: "plus") {
                        actions.add()
                    }
                }
            }

            Tab("Settings", systemImage: "gear", value: AppNavigation.Tab.settings) {
                NavigationStack {
                    SettingsView(player: player)
                        .navigationTitle("Settings")
                }
            }
            .customizationID("tab.settings")

            Tab("Search", systemImage: "magnifyingglass", value: AppNavigation.Tab.search, role: .search) {
                SearchView()
                    .channelScheduleInspector()
            }
            .customizationID("tab.search")
        }
        .playerAccessory(isVisible: player.currentChannel != nil) {
            PlayerBottomAccessory(viewModel: player)
        }
        .onChange(of: navigation.tab) { _, _ in
            // iPad: the schedule inspector belongs to the screen it was opened from.
            if DeviceIdiom.isPad {
                navigation.scheduleChannel = nil
            }
        }
        .onChange(of: playlists.map(\.uuid)) { _, uuids in
            // The playlist whose Home was selected in the sidebar was deleted.
            if case .playlist(let uuid) = navigation.tab, !uuids.contains(uuid) {
                navigation.tab = .home
            }
        }
        #if DEBUG
        .onAppear {
            if DebugGuideDemo.opensGuide {
                navigation.tab = .guide
            } else if DebugGuideDemo.opensFavorites {
                navigation.tab = .favorites
            }
        }
        #endif
    }
}

/// A playlist in the iPad sidebar: its name, and a spinner while it updates.
private struct PlaylistTabLabel: View {
    let playlist: Playlist
    let isUpdating: Bool

    var body: some View {
        Label {
            Text(playlist.name)
        } icon: {
            Image(systemName: isUpdating ? "arrow.triangle.2.circlepath" : "list.bullet.rectangle")
        }
    }
}

#Preview {
    AppTabView(player: AVPlayerViewModel())
        .fluxoPreviewEnvironment()
}
#endif
