//
//  FluxoApp.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-05-31.
//

import SwiftUI
import SwiftData

@main
struct FluxoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: ModelRegistry.all)
    }
}
