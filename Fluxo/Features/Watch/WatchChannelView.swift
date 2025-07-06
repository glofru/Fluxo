//
//  WatchChannelView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import SwiftUI

struct WatchChannelView: View {
    @ObservedObject private var viewModel = AVPlayerViewModel()

    let channel: PlaylistChannel

    var body: some View {
        VStack {
            Button("Play") {
                viewModel.play()
            }

            AVVideoPlayer(viewModel: viewModel)
        }
        .onAppear {
            viewModel.setChannel(channel)
            print("Playling \(channel.name): \(channel.url?.absoluteString)")
        }
    }
}

#Preview {
    WatchChannelView(channel: PlaylistChannel(uuid: UUID(), playlist: .init(uuid: UUID(), name: "Test", url: .applicationDirectory, createdOn: .distantPast)))
}
