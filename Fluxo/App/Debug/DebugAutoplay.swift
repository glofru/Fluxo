//
//  DebugAutoplay.swift
//  Fluxo
//
//  Debug-only smoke test hook, compiled out of release builds:
//  `-FluxoDebugAutoplayURL <url>` plays a stream at launch and
//  `-FluxoDebugRecordSeconds <n>` records it for n seconds.
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
        let recordSeconds = defaults.integer(forKey: "FluxoDebugRecordSeconds")
        guard recordSeconds > 0 else {
            return
        }
        try? await Task.sleep(for: .seconds(8))
        viewModel.startRecording()
        try? await Task.sleep(for: .seconds(recordSeconds))
        viewModel.stopRecording()
    }
}
#endif
