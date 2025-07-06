//
//  AVPlayerViewModel.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import AVKit
import SwiftUI

import FFmpegKit

final class AVPlayerViewModel: ObservableObject {

    var runningInput: URL?
    var server: SimpleHTTPServer?
    let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("hls", isDirectory: true)

    let player = AVPlayer()

    init() {
        setAudioSessionCategory(to: .playback)
    }

    func setChannel(_ channel: PlaylistChannel) {
        guard let url = channel.url else {
            // TODO
            return
        }

        server?.stop()
        server = SimpleHTTPServer(path: outputDir)
        let transmuxedUrl = transmuxStream(url)
        player.replaceCurrentItem(with: AVPlayerItem(url: transmuxedUrl))
    }

    private func transmuxStream(_ inputUrl: URL) -> URL {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let fileName = "stream.m3u8"
        let playlistPath = outputDir.appendingPathComponent(fileName).path

        if runningInput?.absoluteString != inputUrl.absoluteString {
            Task {
                print("Starting transmuxing into \(playlistPath)")
                let args = [
                    "-i", inputUrl.absoluteString,
                    "-c", "copy",
                    "-f", "hls",
                    "-hls_time", "4",
                    "-hls_list_size", "30",
                    "-hls_flags", "delete_segments",
                    "-loglevel", "quiet",
                    playlistPath
                ]
                let command = args.joined(separator: " ")
                FFmpegKit.FF
                FFmpegKit.executeAsync(command) { session in
                    let returnCode = session?.getReturnCode()
                    print("Transmuxing ended with code \(returnCode?.getValue() ?? -1)")
                }
            }
        }

        runningInput = inputUrl

        return URL(string: "http://127.0.0.1:19123/\(fileName)")!
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
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
