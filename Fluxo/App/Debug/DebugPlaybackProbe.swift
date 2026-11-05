//
//  DebugPlaybackProbe.swift
//  Fluxo
//
//  Debug harness: checks that the player really plays, for the `skip:`, `seek:` and `probe-playback` routes
//  (see Tools/Simulator/README.md, "On-demand seeking"): the position advances and the video output delivers
//  frames that are not black and keep up with the clock (a picture frozen over running audio fails), and how long
//  the seek took to play. Compiled out of Release builds.
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
        /// How far the latest video frame is behind the playback position at its worst while sampling: about 0
        /// when the picture follows the audio, growing when it is frozen. nil without frames from where playback
        /// started (the screenshots' burned-in counter, and VODCheck's frame watcher on macOS, then tell).
        var videoLag: TimeInterval?
        /// From the start of the probe (right after the seek) until playback was there; nil when it never was.
        var latency: TimeInterval?

        var description: String {
            let frame = brightness.map { String(format: "%.0f", $0) } ?? "none"
            let lag = videoLag.map { String(format: "%.2f", $0) } ?? "none"
            let latency = latency.map { String(format: "%.2fs", $0) } ?? "never"
            return String(format: "state=%@ time=%.1f duration=%.1f advanced=%.1f brightness=%@ video-lag=%@ latency=%@", state, time, duration, advanced,
                          frame, lag, latency)
        }
    }

    /// Waits (at most `timeout` seconds) until the player plays (near `target`, when given: a seek just made
    /// lands asynchronously), lets it play `seconds`, and describes it.
    static func sample(_ player: AVPlayerViewModel, near target: TimeInterval? = nil, timeout: TimeInterval = 30, seconds: TimeInterval = 3) async -> Sample {
        if let item = player.player.currentItem {
            attachOutput(to: item)
        }
        let began = ContinuousClock.now
        let deadline = began + .seconds(timeout)
        // A short skip (5 s back) lands within 8 s of where it started: the tolerance shrinks with the distance, so the
        // sample does not start before the seek has landed.
        let before = player.player.currentItem?.currentTime().seconds ?? 0
        let tolerance = target.map { max(1.5, min(8, abs($0 - before) / 2)) } ?? 8
        func isThere() -> Bool {
            guard player.playbackState == .playing, !player.seeker.isBusy else {
                return false
            }
            guard let target, let time = player.player.currentItem?.currentTime().seconds, time.isFinite else {
                return true
            }
            return abs(time - target) <= tolerance
        }
        while !isThere() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = ContinuousClock.now - began
        let latency: TimeInterval? = isThere() ? Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18 : nil
        let start = player.player.currentItem?.currentTime().seconds ?? 0
        // Only frames delivered from now on count: the output may still hold one from before the seek (it reports
        // no new frame until the next one), which would look like a picture frozen far behind the audio.
        latestFrame = nil
        var worstLag: TimeInterval?
        var brightness: Double?
        let steps = max(1, Int(seconds * 10))
        for step in 0..<steps {
            try? await Task.sleep(for: .milliseconds(100))
            if let item = player.player.currentItem, let frame = frame(of: item) {
                brightness = frame.brightness ?? brightness
                // A frame from before where playback started is one the output still had queued from before the
                // seek (it does that for items AVPlayer plays directly): it says nothing about the picture now.
                // Judged over the second half: just after the landing the output may still vend a frame queued a
                // moment before it, while a frozen picture falls further behind until the end.
                if frame.time >= start - 1, step >= steps / 2 {
                    let lag = item.currentTime().seconds - frame.time
                    worstLag = max(worstLag ?? lag, lag)
                }
            }
        }
        let item = player.player.currentItem
        let time = item?.currentTime().seconds ?? 0
        let duration = item.map { $0.duration.isNumeric ? $0.duration.seconds : 0 } ?? 0
        return Sample(state: player.playbackState.label, time: time, duration: duration, advanced: time - start,
                      brightness: brightness, videoLag: worstLag, latency: latency)
    }

    /// Fails unless the player plays near `target` (within `tolerance` seconds of where it started) with real frames.
    static func check(_ player: AVPlayerViewModel, near target: TimeInterval?, route: String, tolerance: TimeInterval = 8) async throws {
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
        if let lag = sample.videoLag, lag > 1 {
            problems.append(String(format: "video frozen (%.1f s behind the audio)", lag))
        } else if sample.videoLag == nil, sample.brightness != nil, player.route != .direct {
            // Through the engine the output delivers every frame: none since playback started there is a frozen
            // picture (items AVPlayer plays directly may keep vending a queued one, see `sample`).
            problems.append("video frozen (no frame since the seek)")
        }
        if let target, abs(sample.time - sample.advanced - target) > tolerance {
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
        latestFrame = nil
    }

    /// The latest frame of the probed item: its time and brightness.
    private static var latestFrame: (time: TimeInterval, brightness: Double?)?

    private static func frame(of item: AVPlayerItem) -> (time: TimeInterval, brightness: Double?)? {
        guard probedItem === item, let output else {
            return nil
        }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time) else {
            // No new frame since the last one: the picture still shows that one.
            return latestFrame
        }
        var display = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &display) else {
            return latestFrame
        }
        let frame = (time: display.isNumeric ? display.seconds : time.seconds, brightness: brightness(of: buffer))
        latestFrame = frame
        return frame
    }

    private static func brightness(of buffer: CVPixelBuffer) -> Double? {
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
