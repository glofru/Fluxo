//
//  FluxoApp.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-05-31.
//

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

    init() {
        let container = ModelContainerFactory.make()
        self.container = container
        let library = ChannelLibrary(container: container)
        let player = AVPlayerViewModel()
        player.zapper = ChannelZapper(container: container, library: library)
        _importCenter = State(initialValue: PlaylistImportCenter(container: container))
        _library = State(initialValue: library)
        _player = State(initialValue: player)
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
            FluxoCommands(player: player, actions: playlistActions, importCenter: importCenter, container: container)
        }

        Settings {
            SettingsView(player: player)
                .environment(library)
                .modelContainer(container)
        }
        #else
        // Multiple scenes are disabled in the build settings for the same reason.
        WindowGroup {
            mainContent
        }
        .modelContainer(container)
        .commands {
            FluxoCommands(player: player, actions: playlistActions, importCenter: importCenter, container: container)
        }
        #endif
    }

    private var mainContent: some View {
        ContentView(viewModel: player)
            .environment(importCenter)
            .environment(library)
            .environment(playlistActions)
    }
}
