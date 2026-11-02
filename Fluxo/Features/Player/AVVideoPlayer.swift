//
//  AVVideoPlayer.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import AVKit
import SwiftUI

#if os(macOS)

/// macOS player backed by AVPlayerView.
struct AVVideoPlayer: NSViewRepresentable {
    @ObservedObject var viewModel: AVPlayerViewModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = viewModel.player
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== viewModel.player {
            nsView.player = viewModel.player
        }
    }
}

#else

/// iOS / visionOS player backed by AVPlayerViewController.
struct AVVideoPlayer: UIViewControllerRepresentable {
    @ObservedObject var viewModel: AVPlayerViewModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = viewModel.player
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== viewModel.player {
            uiViewController.player = viewModel.player
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let parent: AVVideoPlayer

        init(_ parent: AVVideoPlayer) {
            self.parent = parent
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            parent.viewModel.isPresented = false
            print("Will start")
        }

        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            parent.viewModel.isPresented = false
            print("Did start")
        }
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

#endif
