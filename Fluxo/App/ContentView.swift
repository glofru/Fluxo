//
//  ContentView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-05-31.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var themeManager = ThemeManager()

    var body: some View {
        TabView {
            WatchView()
                .environmentObject(themeManager)
                .tabItem {
                    Label("Watch", systemImage: "play.tv")
                }

            Text("Settings")
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}

#Preview {
    ContentView()
}
