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
        Group {
            if #available(iOS 26, *) {
                TabView {
                    Tab("Watch", systemImage: "play.tv") {
                        WatchView()
                            .environmentObject(themeManager)
                    }

                    Tab("Settings", systemImage: "gear") {
                        Text("Settings")
                    }

                    Tab("Seach", systemImage: "magnifyingglass", role: .search) {
                        List(0..<100) { i in
                            Text("Row \(i)")
                        }
                    }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
            } else {
                TabView {
                    Tab("Watch", systemImage: "play.tv") {
                        WatchView()
                            .environmentObject(themeManager)
                    }

                    Tab("Settings", systemImage: "gear") {
                        Text("Settings")
                    }

                    Tab("Seach", systemImage: "magnifyingglass", role: .search) {
                        List(0..<100) { i in
                            Text("Row \(i)")
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
