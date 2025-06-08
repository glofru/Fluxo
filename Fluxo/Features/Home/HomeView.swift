//
//  HomeView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-03.
//

import SwiftUI

struct HomeView: View {
    @State private var displayedSheet: HomeViewSheet? = .addPlaylist

    var body: some View {
        NavigationView {
            Text("Home")
                .navigationTitle("Home")
                .toolbar {
                    Button(action: {
                        displayedSheet = .addPlaylist
                    }, label: {
                        Image(systemName: "plus")
                    })
                }
                .sheet(item: $displayedSheet) { sheet in
                    switch sheet {
                    case .addPlaylist: AddPlaylistView()
                    }
                }
        }
    }
}

private enum HomeViewSheet: Identifiable {
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
