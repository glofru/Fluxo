//
//  HomeView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-03.
//

import SwiftData
import SwiftUI

struct HomeView: View {

    @Environment(\.modelContext) private var modelContext

    @State private var displayedSheet: HomeViewSheet?

    @State private var playlistToDelete: Playlist?

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]

    var body: some View {
        NavigationStack {
            List(playlists) { playlist in
                NavigationLink(playlist.name) {
                    PlaylistView(playlist: playlist)
                }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            playlistToDelete = playlist
                        }

                        Button("Rename", systemImage: "pencil") {
                            displayedSheet = .updatePlaylist(playlist)
                        }
                    }
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
                    case .updatePlaylist(let playlist): AddPlaylistView(playlist: playlist)
                    }
                }
                .alert("Delete playlist", isPresented: .init(get: { playlistToDelete != nil }, set: { _ in playlistToDelete = nil }), presenting: playlistToDelete) { playlist in
                    Button("Cancel", role: .cancel) {}

                    Button("Delete", role: .destructive) {
                        modelContext.delete(playlist)
                        try? modelContext.save()
                    }
                } message: { playlist in
                    Text("Are you sure to delete playlist \"\(playlist.name)\"?")
                }
        }
    }
}

private enum HomeViewSheet: Identifiable {
    case addPlaylist
    case updatePlaylist(Playlist)

    var id: String {
        switch self {
        case .addPlaylist: "AddPlaylist"
        case .updatePlaylist(let playlist): "UpdatePlaylist\(playlist.id)"
        }
    }
}

#Preview {
    HomeView()
}
