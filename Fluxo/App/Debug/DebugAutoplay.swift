//
//  DebugAutoplay.swift
//  Fluxo
//
//  Debug-only smoke test hook, compiled out of release builds:
//  `-FluxoDebugAutoplayURL <url>` plays a stream at launch and
//  `-FluxoDebugRecordSeconds <n>` records it for n seconds.
//  `-FluxoDebugPictureInPicture YES` starts Picture in Picture once possible, closes the player screen,
//  then stops PiP after a few seconds (the player screen is restored).
//  `-FluxoDebugStopDuringPictureInPicture YES` (with the PiP flag) stops playback while PiP runs instead;
//  the player screen must stay closed.
//

#if DEBUG
import SwiftUI

extension View {
    func debugAutoplay(_ viewModel: AVPlayerViewModel) -> some View {
        task {
            await DebugAutoplay.run(viewModel)
        }
    }
}

@MainActor
private enum DebugAutoplay {
    private static var didRun = false

    static func run(_ viewModel: AVPlayerViewModel) async {
        let defaults = UserDefaults.standard
        guard !didRun, let value = defaults.string(forKey: "FluxoDebugAutoplayURL"), let url = URL(string: value) else {
            return
        }
        didRun = true
        viewModel.play(PlayableChannel(id: UUID(), name: "Debug stream", logo: nil, url: url))
        if defaults.bool(forKey: "FluxoDebugPictureInPicture") {
            await exercisePictureInPicture(viewModel)
        }
        let recordSeconds = defaults.integer(forKey: "FluxoDebugRecordSeconds")
        guard recordSeconds > 0 else {
            return
        }
        try? await Task.sleep(for: .seconds(8))
        viewModel.startRecording()
        try? await Task.sleep(for: .seconds(recordSeconds))
        viewModel.stopRecording()
    }

    private static func exercisePictureInPicture(_ viewModel: AVPlayerViewModel) async {
        for _ in 0..<60 where !viewModel.isPictureInPicturePossible {
            try? await Task.sleep(for: .milliseconds(500))
        }
        viewModel.togglePictureInPicture()
        try? await Task.sleep(for: .seconds(6))
        if UserDefaults.standard.bool(forKey: "FluxoDebugStopDuringPictureInPicture") {
            viewModel.stop()
            try? await Task.sleep(for: .seconds(3))
            NSLog("FluxoDebug: after stop during PiP isPresented=%d", viewModel.isPresented ? 1 : 0)
            return
        }
        // Starting PiP closes the player screen; stopping it asks the app to restore the screen.
        viewModel.togglePictureInPicture()
        try? await Task.sleep(for: .seconds(3))
    }
}
#endif
