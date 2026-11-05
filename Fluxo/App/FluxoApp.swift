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
    /// The windows of the app (iPad): which one shows the player and the app-wide sheets, and the navigation
    /// App Intents move.
    @State private var windows: WindowCoordinator
    /// Offline downloads of movies and episodes (the transfers continue in the background).
    @State private var downloads: DownloadCenter
    /// The objects above, for App Intents (Siri, Shortcuts, Spotlight).
    private let services: AppServices

    init() {
        let container = ModelContainerFactory.make()
        self.container = container
        // First: the player, the guide and the downloads ask whether the device is online.
        NetworkMonitor.shared.start()
        // Low Power Mode, the thermal state and the background: the player and the guide adapt to them.
        PowerMonitor.shared.start()
        let library = ChannelLibrary(container: container)
        // Chromecast through the Google Cast SDK on iOS; unsupported (no cast UI) on macOS.
        let player = AVPlayerViewModel(cast: .makeDefault())
        player.zapper = ChannelZapper(container: container, library: library)
        player.resumePosition = { [weak library] item in
            library?.watchProgress(for: item)?.position
        }
        let downloads = DownloadCenter(container: container)
        player.downloads = downloads
        downloads.currentlyPlayingItem = { [weak player] in
            player?.currentItem
        }
        downloads.willDeleteMedia = { [weak player] in
            player?.stopIfPlayingDownload()
        }
        library.onFinishedWatching = { [weak downloads] item in
            downloads?.itemWasWatched(item)
        }
        // Now, not when a view appears: transfers that finished while the app was not running are collected, and
        // the queue goes on.
        downloads.start()
        let importCenter = PlaylistImportCenter(container: container)
        let epg = EPGStore(container: container)
        importCenter.onPlaylistImported = { [weak epg] playlistID in
            epg?.playlistDidImport(playlistID)
        }
        importCenter.onPlaylistDeleted = { [weak epg, weak downloads] playlistID in
            epg?.playlistWasDeleted(playlistID)
            downloads?.playlistWasDeleted(playlistID)
        }
        // Now, not when the first view appears: the reminder notification delegate must be installed before a
        // notification that launched the app is delivered.
        epg.start()
        let intelligence = FluxoIntelligence(container: container, epg: epg)
        let windows = WindowCoordinator()
        let services = AppServices(container: container, library: library, player: player, epg: epg, windows: windows, intelligence: intelligence)
        // Before any intent runs: intents launched by Siri or Shortcuts read it with @Dependency.
        AppDependencyManager.shared.add(dependency: services)
        self.services = services
        _intelligence = State(initialValue: intelligence)
        _windows = State(initialValue: windows)
        _importCenter = State(initialValue: importCenter)
        _library = State(initialValue: library)
        _player = State(initialValue: player)
        _epg = State(initialValue: epg)
        _downloads = State(initialValue: downloads)
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
            FluxoCommands(player: player, actions: playlistActions, importCenter: importCenter, container: container, epg: epg, windows: windows)
        }

        Settings {
            SettingsView(player: player)
                .environment(library)
                .environment(downloads)
                .environment(epg)
                .environment(intelligence)
                .modelContainer(container)
                .defaultAppStorage(.fluxo)
        }
        #else
        // iPad: several windows of the app (File › New Window, or the app's windows in Stage Manager). They share
        // the single player, which shows in one window at a time (see `WindowCoordinator`).
        WindowGroup(id: Self.mainWindowID) {
            mainContent
        }
        .modelContainer(container)
        .commands {
            FluxoCommands(player: player, actions: playlistActions, importCenter: importCenter, container: container, epg: epg, windows: windows)
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(EPGBackgroundRefresh.taskIdentifier)) { [epg] in
            // Ask for the next run first, so a refresh that runs out of time is still followed by another.
            EPGBackgroundRefresh.schedule()
            await epg.performBackgroundRefresh()
        }
        // Downloads that progressed or finished while the app was suspended or not running: the system relaunches
        // it in the background to deliver their events, and waits until they are handled.
        .backgroundTask(.urlSession(matching: { $0.hasPrefix(DownloadTransport.identifierPrefix) })) { identifier in
            await DownloadTransport.shared.handleBackgroundEvents(for: identifier)
        }
        #endif

        #if os(iOS)
        // iPad: a channel in a window of its own ("Open in New Window"). A window restored at the next launch waits
        // for a tap instead of playing on its own (see `WindowCoordinator.pendingPlayerWindows`).
        WindowGroup("Player", id: PlayerWindowValue.windowID, for: PlayerWindowValue.self) { $value in
            PlayerWindowView(value: value, player: player)
                .modifier(AppEnvironment(importCenter: importCenter, library: library, actions: playlistActions, epg: epg, intelligence: intelligence, windows: windows, player: player, downloads: downloads))
        }
        .modelContainer(container)
        .defaultSize(width: 960, height: 600)
        #endif
        #endif
    }

    /// The main window group (iOS).
    static let mainWindowID = "main"

    private var mainContent: some View {
        // Each main window has its own navigation; the first one adopts the navigation App Intents may already
        // have moved at launch.
        ContentView(viewModel: player, navigation: windows.makeMainWindowNavigation())
            .appServicesLifecycle(services)
            .environment(intelligence)
            .environment(importCenter)
            .environment(library)
            .environment(playlistActions)
            .environment(epg)
            .environment(windows)
            .environment(downloads)
    }
}

/// The app's shared objects, for a window that is not a `ContentView` (the iPad player window).
private struct AppEnvironment: ViewModifier {
    let importCenter: PlaylistImportCenter
    let library: ChannelLibrary
    let actions: PlaylistActions
    let epg: EPGStore
    let intelligence: FluxoIntelligence
    let windows: WindowCoordinator
    let player: AVPlayerViewModel
    let downloads: DownloadCenter

    @State private var navigation = AppNavigation()

    func body(content: Content) -> some View {
        content
            // The player is already in this window: playing another channel from it keeps it here.
            .environment(\.playChannel, PlayChannelAction(library: library, player: player))
            .environment(importCenter)
            .environment(library)
            .environment(actions)
            .environment(epg)
            .environment(intelligence)
            .environment(windows)
            .environment(downloads)
            .environment(navigation)
            .defaultAppStorage(.fluxo)
            .tint(Theme.accent)
    }
}
