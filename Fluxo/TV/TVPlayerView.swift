//
//  TVPlayerView.swift
//  Fluxo
//
//  The player on Apple TV: the system's `AVPlayerViewController` on the app's single `AVPlayer`. Its transport bar
//  is the one Apple TV users know (the Siri Remote's clickpad scrubs, swipes skip, the info and audio and subtitle
//  panels), it shows live streams with their live edge, and it reads the HLS that the remux engine serves on the
//  loopback address like any other stream. Everything else (routing through the engine, reconnection, time shift,
//  recording, watch progress) is the shared `AVPlayerViewModel`.
//
//  Before the first frame (connecting, the engine opening a raw MPEG-TS input) and after a failure there is no video
//  to show yet, so the channel and the player's state are drawn over the black screen.
//

#if os(tvOS)
import AVKit
import SwiftUI

struct TVPlayerView: View {

    let viewModel: AVPlayerViewModel

    var body: some View {
        SystemPlayerController(player: viewModel.player)
            .ignoresSafeArea()
            .overlay {
                if showsStatus {
                    TVPlayerStatus(viewModel: viewModel)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showsStatus)
    }

    /// Until the video starts (the engine creates the player item once its first segment exists), and when
    /// playback failed or ended. Buffering later is shown by the system player itself.
    private var showsStatus: Bool {
        switch viewModel.playbackState {
        case .idle, .connecting, .failed, .ended:
            return true
        case .buffering:
            return viewModel.player.currentItem == nil
        case .playing, .paused, .reconnecting:
            return false
        }
    }
}

/// The channel and what the player does, centered over the black screen.
private struct TVPlayerStatus: View {
    let viewModel: AVPlayerViewModel

    var body: some View {
        VStack(spacing: 24) {
            if case .failed = viewModel.playbackState {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
            } else if viewModel.playbackState != .ended {
                ProgressView()
                    .controlSize(.large)
            }
            if let name = viewModel.currentChannel?.name {
                Text(name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
            }
            Text(viewModel.playbackState.label)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(80)
        .frame(maxWidth: 1_200)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// `AVPlayerViewController` on the app's player. The controller is created once per presentation and lets go of
/// the player when the presentation ends.
private struct SystemPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        // Picture in Picture needs the player to stay alive when its screen closes, and closing the player stops
        // playback on Apple TV for now (no mini player): off until the TV player handles it.
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}
#endif
