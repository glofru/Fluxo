//
//  WatchChannelView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import AVKit
import SwiftUI

struct WatchChannelView: View {

    @ObservedObject var viewModel: AVPlayerViewModel

    var body: some View {
        ZStack {
            Color.red

            VStack {
                Button(action: {
                    viewModel.isPresented = false
                }, label: {
                    Text("Bye")
                })

                AVVideoPlayer(viewModel: viewModel)
                    .frame(height: 200)
                    .onAppear {
                        viewModel.play()
                    }

                if let streamError = viewModel.streamError {
                    Text(streamError)
                        .foregroundStyle(.white)
                        .padding()
                }
            }
        }
    }
}

#Preview {
    WatchChannelView(viewModel: AVPlayerViewModel())
}
