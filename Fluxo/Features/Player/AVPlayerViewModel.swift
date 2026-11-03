//
//  AVPlayerViewModel.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import AVKit
import SwiftUI

final class AVPlayerViewModel: ObservableObject {

    private let server = SimpleHTTPServer()
    private let remuxer = StreamRemuxer()
    private let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls", isDirectory: true)
    private var playbackTask: Task<Void, Never>?

    @Published var isPresented: Bool = false

    @Published var currentChannel: PlayableChannel? {
        willSet {
            if let newValue {
                setChannel(newValue)
            }
        }
    }

    /// Last error reported by the stream engine for the current channel.
    @Published private(set) var streamError: String?

    let player = AVPlayer()

    init() {
        configureAudioSession()
        remuxer.onStateChange = { [weak self] state in
            if case .failed(let message) = state {
                self?.streamError = message
            }
        }
    }

    private func setChannel(_ channel: PlayableChannel) {
        guard let url = channel.url, channel != currentChannel else {
            // TODO
            return
        }

        playbackTask?.cancel()
        remuxer.stop()
        streamError = nil

        guard channel.isLiveContent else {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            return
        }

        server.start(root: outputDir)

        let configuration = StreamRemuxer.Configuration(
            inputURL: url,
            outputDirectory: outputDir,
            name: "\(channel.id)-\(UUID().uuidString)"
        )
        guard let streamURL = SimpleHTTPServer.url(forFileNamed: configuration.playlistFileName) else {
            return
        }

        do {
            try remuxer.start(configuration)
        } catch {
            streamError = error.localizedDescription
            return
        }

        let playlistPath = configuration.playlistURL.path
        playbackTask = Task { @MainActor [weak self] in
            // Wait for the first segment and playlist to be written, then attach the stream once.
            for _ in 0..<120 {
                guard !Task.isCancelled else {
                    return
                }
                if FileManager.default.fileExists(atPath: playlistPath) {
                    self?.player.replaceCurrentItem(with: AVPlayerItem(url: streamURL))
                    return
                }
                guard self?.remuxer.isProcessing == true else {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        currentChannel = nil
        playbackTask?.cancel()
        playbackTask = nil
        player.replaceCurrentItem(with: nil)
        remuxer.stop()
        server.stop()
    }

    private func configureAudioSession() {
        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            print("Setting category to AVAudioSessionCategoryPlayback failed.")
        }
        #endif
    }
}
