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

    init() {
        let container = ModelContainerFactory.make()
        self.container = container
        _importCenter = StateObject(wrappedValue: PlaylistImportCenter(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(importCenter)
        }
        .modelContainer(container)
    }
}
