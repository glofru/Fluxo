//
//  AVVideoPlayer.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import AVKit
import SwiftUI

struct AVVideoPlayer: UIViewControllerRepresentable {
    @ObservedObject var viewModel: AVPlayerViewModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = viewModel.player
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let parent: AVVideoPlayer

        init(_ parent: AVVideoPlayer) {
            self.parent = parent
        }

//        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
//            parent.viewModel.pipStatus = .willStart
//        }
//
//        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
//            parent.viewModel.pipStatus = .didStart
//        }
//
//        func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
//            parent.viewModel.pipStatus = .willStop
//        }
//
//        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
//            parent.viewModel.pipStatus = .didStop
//        }
    }
}
