//
//  FluxoApp.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-05-31.
//

import AppIntents
import SwiftData
import SwiftUI

@main
struct FluxoApp: App {

    private let container: ModelContainer
    @State private var importCenter: PlaylistImportCenter
    /// Favorites and watch history.
    @State private var library: ChannelLibrary
    /// Add / rename / delete requests, shared by the screens and the menu bar commands.
    @State private var playlistActions = PlaylistActions()
    /// The single player of the app. It owns the AVPlayer, the Picture in Picture surface, the remux
    /// engine, the loopback HLS server and the recordings, so there must never be more than one.
    @State private var player: AVPlayerViewModel
    /// The TV guide: sources, refreshes, matching and reminders.
    @State private var epg: EPGStore
    /// Apple Intelligence (on device): availability, recommendations and summaries.
    @State private var intelligence: FluxoIntelligence
    /// Tab / sidebar selection and navigation paths; App Intents move the UI through it too.
    @State private var navigation: AppNavigation
    /// The objects above, for App Intents (Siri, Shortcuts, Spotlight).
    private let services: AppServices

    init() {
        let container = ModelContainerFactory.make()
        self.container = container
        let library = ChannelLibrary(container: container)
        // Chromecast through the Google Cast SDK on iOS; unsupported (no cast UI) on macOS.
        let player = AVPlayerViewModel(cast: .makeDefault())
        player.zapper = ChannelZapper(container: container, library: library)
        let importCenter = PlaylistImportCenter(container: container)
        let epg = EPGStore(container: container)
        importCenter.onPlaylistImported = { [weak epg] playlistID in
            epg?.playlistDidImport(playlistID)
        }
        importCenter.onPlaylistDeleted = { [weak epg] playlistID in
            epg?.playlistWasDeleted(playlistID)
        }
        // Now, not when the first view appears: the reminder notification delegate must be installed before a
        // notification that launched the app is delivered.
        epg.start()
        let intelligence = FluxoIntelligence(container: container, epg: epg)
        let navigation = AppNavigation()
        let services = AppServices(container: container, library: library, player: player, epg: epg, navigation: navigation, intelligence: intelligence)
        // Before any intent runs: intents launched by Siri or Shortcuts read it with @Dependency.
        AppDependencyManager.shared.add(dependency: services)
        self.services = services
        _intelligence = State(initialValue: intelligence)
        _navigation = State(initialValue: navigation)
        _importCenter = State(initialValue: importCenter)
        _library = State(initialValue: library)
        _player = State(initialValue: player)
        _epg = State(initialValue: epg)
    }

    var body: some Scene {
        #if os(macOS)
        // A single main window: the player, its PiP surface and the local server are app-wide.
        Window("Fluxo", id: "main") {
            mainContent
                .frame(minWidth: 820, minHeight: 540)
        }
        .modelContainer(container)
        .defaultSize(width: 1_240, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            FluxoCommands(player: player, actions: playlistActions, importCenter: importCenter, container: container, epg: epg)
        }

        Settings {
            SettingsView(player: player)
                .environment(library)
                .environment(epg)
                .environment(intelligence)
                .modelContainer(container)
                .defaultAppStorage(.fluxo)
        }
        #else
        // Multiple scenes are disabled in the build settings for the same reason.
        WindowGroup {
            mainContent
        }
        .modelContainer(container)
        .commands {
            FluxoCommands(player: player, actions: playlistActions, importCenter: importCenter, container: container, epg: epg)
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(EPGBackgroundRefresh.taskIdentifier)) { [epg] in
            // Ask for the next run first, so a refresh that runs out of time is still followed by another.
            EPGBackgroundRefresh.schedule()
            await epg.performBackgroundRefresh()
        }
        #endif
        #endif
    }

    private var mainContent: some View {
        ContentView(viewModel: player, navigation: navigation)
            .appServicesLifecycle(services)
            .environment(intelligence)
            .environment(importCenter)
            .environment(library)
            .environment(playlistActions)
            .environment(epg)
    }
}
