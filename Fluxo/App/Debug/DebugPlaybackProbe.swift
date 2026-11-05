//
//  DebugPlaybackProbe.swift
//  Fluxo
//
//  Debug harness: checks that the player really plays, for the `skip:`, `seek:` and `probe-playback` routes
//  (see Tools/Simulator/README.md, "On-demand seeking"): the position advances and the video output delivers
//  frames that are not black. Compiled out of Release builds.
//

#if DEBUG
import AVFoundation
import CoreVideo

@MainActor
enum DebugPlaybackProbe {

    /// The video output added to the item being probed (an item keeps its outputs while it lives). The item is
    /// held weakly: a later item may reuse its address.
    private static weak var probedItem: AVPlayerItem?
    private static var output: AVPlayerItemVideoOutput?

    struct Sample: CustomStringConvertible {
        var state: String
        var time: TimeInterval
        var duration: TimeInterval
        var advanced: TimeInterval
        /// Mean brightness (0–255) of the latest video frame; nil without a frame.
        var brightness: Double?

        var description: String {
            let frame = brightness.map { String(format: "%.0f", $0) } ?? "none"
            return String(format: "state=%@ time=%.1f duration=%.1f advanced=%.1f brightness=%@", state, time, duration, advanced, frame)
        }
    }

    /// Waits (at most `timeout` seconds) until the player plays (near `target`, when given: a seek just made
    /// lands asynchronously), lets it play `seconds`, and describes it.
    static func sample(_ player: AVPlayerViewModel, near target: TimeInterval? = nil, timeout: TimeInterval = 30, seconds: TimeInterval = 3) async -> Sample {
        if let item = player.player.currentItem {
            attachOutput(to: item)
        }
        let deadline = ContinuousClock.now + .seconds(timeout)
        // A short skip (5 s back) lands within 8 s of where it started: the tolerance shrinks with the distance, so the
        // sample does not start before the seek has landed.
        let before = player.player.currentItem?.currentTime().seconds ?? 0
        let tolerance = target.map { max(1.5, min(8, abs($0 - before) / 2)) } ?? 8
        func isThere() -> Bool {
            guard player.playbackState == .playing else {
                return false
            }
            guard let target, let time = player.player.currentItem?.currentTime().seconds, time.isFinite else {
                return true
            }
            return abs(time - target) <= tolerance
        }
        while !isThere() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let start = player.player.currentItem?.currentTime().seconds ?? 0
        try? await Task.sleep(for: .seconds(seconds))
        let item = player.player.currentItem
        let time = item?.currentTime().seconds ?? 0
        let duration = item.map { $0.duration.isNumeric ? $0.duration.seconds : 0 } ?? 0
        return Sample(state: player.playbackState.label, time: time, duration: duration, advanced: time - start,
                      brightness: item.flatMap(brightness(of:)))
    }

    /// Fails unless the player plays near `target` with real frames.
    static func check(_ player: AVPlayerViewModel, near target: TimeInterval?, route: String) async throws {
        let sample = await sample(player, near: target)
        DebugLaunchOptions.logger.notice("Playback probe after \(route, privacy: .public): \(sample.description, privacy: .public)")
        var problems: [String] = []
        if player.playbackState != .playing {
            problems.append("not playing (\(sample.state))")
        }
        if sample.advanced < 1.5 {
            problems.append("stuck")
        }
        if (sample.brightness ?? 0) < 20 {
            problems.append("no video frames")
        }
        if let target, abs(sample.time - sample.advanced - target) > 8 {
            problems.append(String(format: "at %.0f s instead of %.0f s", sample.time - sample.advanced, target))
        }
        if !problems.isEmpty {
            throw DebugRouteError.check("\(route): \(problems.joined(separator: ", ")) [\(sample.description)]")
        }
    }

    /// Fails unless the playing item has enabled tracks of the expected kinds (`a`: audio, `v`: video), and logs
    /// their formats (`avc1` and `aac` for streams the engine converted; see Tools/Simulator/format-matrix.sh).
    static func checkTracks(_ player: AVPlayerViewModel, expecting: String, route: String) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while player.playbackState != .playing && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        var video: [String] = []
        var audio: [String] = []
        for track in player.player.currentItem?.tracks ?? [] where track.isEnabled {
            guard let asset = track.assetTrack else {
                continue
            }
            let formats = ((try? await asset.load(.formatDescriptions)) ?? []).map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
            if asset.mediaType == .video {
                video += formats.isEmpty ? ["?"] : formats
            } else if asset.mediaType == .audio {
                audio += formats.isEmpty ? ["?"] : formats
            }
        }
        let description = "video=\(video) audio=\(audio) route=\(String(describing: player.route))"
        DebugLaunchOptions.logger.notice("Playback tracks after \(route, privacy: .public): \(description, privacy: .public)")
        var problems: [String] = []
        if expecting.contains("v") && video.isEmpty {
            problems.append("no video track")
        }
        if expecting.contains("a") && audio.isEmpty {
            problems.append("no audio track")
        }
        if !problems.isEmpty {
            throw DebugRouteError.check("\(route): \(problems.joined(separator: ", ")) [\(description)]")
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }

    private static func attachOutput(to item: AVPlayerItem) {
        guard probedItem !== item else {
            return
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        probedItem = item
        self.output = output
    }

    private static func brightness(of item: AVPlayerItem) -> Double? {
        guard probedItem === item, let output else {
            return nil
        }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var total = 0
        var count = 0
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let pixel = base + y * row + x * 4
                total += Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])
                count += 3
            }
        }
        return count > 0 ? Double(total) / Double(count) : nil
    }
}
#endif
