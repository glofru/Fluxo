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
    @StateObject private var importCenter: PlaylistImportCenter
    /// The single player of the app. It owns the AVPlayer, the Picture in Picture surface, the remux
    /// engine, the loopback HLS server and the recordings, so there must never be more than one.
    @StateObject private var player: AVPlayerViewModel

    init() {
        let container = ModelContainerFactory.make()
        self.container = container
        _importCenter = StateObject(wrappedValue: PlaylistImportCenter(container: container))
        _player = StateObject(wrappedValue: AVPlayerViewModel())
    }

    var body: some Scene {
        #if os(macOS)
        // A single main window: the player, its PiP surface and the local server are app-wide.
        Window("Fluxo", id: "main") {
            mainContent
        }
        .modelContainer(container)
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
            .environmentObject(importCenter)
    }
}
