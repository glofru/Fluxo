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
    /// The single player of the app. It owns the AVPlayer, the Picture in Picture surface, the remux
    /// engine, the loopback HLS server and the recordings, so there must never be more than one.
    @State private var player: AVPlayerViewModel

    init() {
        let container = ModelContainerFactory.make()
        self.container = container
        _importCenter = State(initialValue: PlaylistImportCenter(container: container))
        _library = State(initialValue: ChannelLibrary(container: container))
        _player = State(initialValue: AVPlayerViewModel())
    }

    var body: some Scene {
        #if os(macOS)
        // A single main window: the player, its PiP surface and the local server are app-wide.
        Window("Fluxo", id: "main") {
            mainContent
        }
        .modelContainer(container)
        .defaultSize(width: 1_180, height: 780)

        Settings {
            SettingsView()
                .frame(minWidth: 420, minHeight: 260)
        }
        #else
        // Multiple scenes are disabled in the build settings for the same reason.
        WindowGroup {
            mainContent
        }
        .modelContainer(container)
        #endif
    }

    private var mainContent: some View {
        ContentView(viewModel: player)
            .environment(importCenter)
            .environment(library)
    }
}
