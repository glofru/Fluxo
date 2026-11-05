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
        func isThere() -> Bool {
            guard player.playbackState == .playing else {
                return false
            }
            guard let target, let time = player.player.currentItem?.currentTime().seconds, time.isFinite else {
                return true
            }
            return abs(time - target) <= 8
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
