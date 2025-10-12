//
//  AVPlayerViewModel.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import AVKit
import SwiftUI

final class AVPlayerViewModel: ObservableObject {

    private var runningInput: URL?
    private var server = SimpleHTTPServer()
    private let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls", isDirectory: true)

    @Published var isPresented: Bool = false

    @Published var currentChannel: PlaylistChannel? {
        willSet {
            if let newValue {
                setChannel(newValue)
            }
        }
    }

    let ffmpegManager = FFmpegManager()

    let player = AVPlayer()

    init() {
        setAudioSessionCategory(to: .playback)
    }

    private func setChannel(_ channel: PlaylistChannel) {
        guard let url = channel.url, channel != currentChannel else {
            // TODO
            return
        }

        guard channel.isLiveContent else {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            return
        }

        server.start(path: outputDir)
        let (transmuxedUrl, playlistPath) = transmuxStream(url, name: "\(channel.uuid)-\(UUID().uuidString)")

        Task {
            for _ in 0..<10 {
                guard FileManager.default.fileExists(atPath: playlistPath) else {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                await MainActor.run { [weak self] in
                    self?.player.replaceCurrentItem(with: AVPlayerItem(url: transmuxedUrl))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.player.replaceCurrentItem(with: AVPlayerItem(url: transmuxedUrl))
        }
    }

    private func transmuxStream(_ inputUrl: URL, name: String) -> (URL, String) {
        if ffmpegManager.isProcessing {
            print("Stopping FFmpeg")
            ffmpegManager.stopExecution()
        }

        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let fileName = "stream-\(name).m3u8"
        let playlistPath = outputDir.appendingPathComponent(fileName).path

        if runningInput?.absoluteString != inputUrl.absoluteString {
            Task {
                print("Starting transmuxing into \(playlistPath)")
                let args = [
                    "-i \(inputUrl.absoluteString)",
                    "-c copy",
                    "-f hls",
                    "-hls_time 1",
                    "-hls_list_size 30",
                    "-hls_flags delete_segments",
                    "-loglevel quiet",
                    playlistPath
                ]
                let command = args.joined(separator: " ")
                ffmpegManager.executeCommand(command) { success, errorMessage in
                    print("FFmpeg: \(success). Error: \(errorMessage)")
                }
            }
        }

        runningInput = inputUrl

        return (URL(string: "http://127.0.0.1:19123/\(fileName)")!, playlistPath)
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        currentChannel = nil
        if ffmpegManager.isProcessing {
            ffmpegManager.stopExecution()
        }
        server.stop()
    }

    func setAudioSessionCategory(to value: AVAudioSession.Category) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
           try audioSession.setCategory(value)
        } catch {
           print("Setting category to AVAudioSessionCategoryPlayback failed.")
        }
    }
}
