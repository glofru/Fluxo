//
//  HomeView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-03.
//

import SwiftUI

struct HomeView: View {
    @State private var displayedSheet: HomeViewSheet? = nil
    
    var body: some View {
        NavigationView {
            Text("Home")
                .navigationTitle("Home")
                .toolbar {
                    Button(action: {
                        displayedSheet = .addPlaylist
                    }) {
                        Image(systemName: "plus")
                    }
                }
                .sheet(item: $displayedSheet) { sheet in
                    switch sheet {
                    case .addPlaylist: AddPlaylistView()
                    }
                }
        }
    }
}

fileprivate enum HomeViewSheet: Identifiable {
    case addPlaylist
    
    var id: String {
        switch self {
        case .addPlaylist: "AddPlaylist"
        }
    }
}

#Preview {
    HomeView()
}
