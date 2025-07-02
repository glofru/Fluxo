//
//  PlaylistView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-02.
//

import SwiftUI

struct PlaylistView: View {

    let playlist: Playlist

    var body: some View {
        Text("View playlist \(playlist.name)")
    }
}

#Preview {
    PlaylistView(playlist: .init(uuid: UUID(), name: "Test", url: URL(string: "https://example.com") ?? .homeDirectory, createdOn: Date()))
}
