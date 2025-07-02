//
//  HomeView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-03.
//

import SwiftData
import SwiftUI

struct HomeView: View {
    @State private var displayedSheet: HomeViewSheet? = .addPlaylist

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]

    var body: some View {
        NavigationView {
            List(playlists) { playlist in
                Text("\(playlist.name) (\(playlist.url.absoluteString)")
            }
                .navigationTitle("Home")
                .toolbar {
                    Button(action: {
                        displayedSheet = .addPlaylist
                    }, label: {
                        Image(systemName: "plus")
                            .accessibilityLabel("Add a playlist")
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
