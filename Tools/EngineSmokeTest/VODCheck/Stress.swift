//
//  Stress.swift
//  VODCheck
//
//  SCENARIO=stress: seeks the way people use the scrubber and the skip buttons on a phone, and measures each
//  seek: from the release of the scrubber (or the last tap) until the player plays at the target with fresh
//  video frames. Drags, rapid skip taps that add up, a release just past the player's buffer, two releases in a
//  row, a seek near the end, a seek while paused, a resume. After every seek, playback must advance with video frames that keep up with the clock
//  (a frozen picture over running audio fails, as does a black one).
//
//  SEEKER=legacy seeks like the player did before PlayerSeeker (every action starts its own AVPlayer seek, a
//  skip adds to the player's current time); otherwise the app's PlayerSeeker is used (PlayerSeeker.swift).
//

import AVFoundation
import CoreVideo
import Foundation

@MainActor
final class FrameWatcher {
    /// Item time of the latest frame the video output delivered.
    private(set) var lastFrameTime: Double?
    private(set) var lastBrightness: Double?
    private(set) var frames = 0
    private var task: Task<Void, Never>?

    func start(output: AVPlayerItemVideoOutput, brightness: @escaping (CVPixelBuffer) -> Double?) {
        task?.cancel()
        lastFrameTime = nil
        frames = 0
        task = Task { @MainActor [weak self] in
            var count = 0
            while !Task.isCancelled {
                let time = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: time) {
                    var display = CMTime.invalid
                    if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &display) {
                        self?.frames += 1
                        if display.isNumeric {
                            self?.lastFrameTime = display.seconds
                        }
                        count += 1
                        if count % 5 == 1 {
                            self?.lastBrightness = brightness(buffer)
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

struct SeekMeasurement {
    var label: String
    var latency: Double
    var ok: Bool
}

extension Check {
    var usesSeeker: Bool {
        ProcessInfo.processInfo.environment["SEEKER"] != "legacy"
    }

    func clamp(_ time: Double) -> Double {
        guard let r = range() else {
            return time
        }
        return min(max(time, r.0 + 0.5), max(r.0 + 0.5, r.1))
    }

    /// The scrubber released at `time`, or a VoiceOver adjustment.
    func userSeek(_ time: Double) {
        let time = clamp(time)
        if usesSeeker {
            seeker.seek(to: time)
        } else {
            let tolerance = CMTime(value: 1, timescale: 4)
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }

    /// The finger moving the scrubber (no release yet).
    func userDrag(_ time: Double) {
        guard usesSeeker else {
            // The scrubber seeks only when released.
            return
        }
        // AVPlayerViewModel.scrub(toSeconds:): local files follow the finger with key frame seeks; streams do not seek.
        if url.isFileURL {
            seeker.seek(to: clamp(time), precision: .keyFrame, isFinal: false)
        }
    }

    /// A skip button tap. Returns where it should lead.
    @discardableResult
    func userSkip(_ seconds: Double) -> Double {
        if usesSeeker {
            let base = seeker.target ?? currentTime
            let time = clamp(base + seconds)
            seeker.seek(to: time, isBurst: true)
            return time
        }
        let time = clamp(currentTime + seconds)
        let tolerance = CMTime(value: 1, timescale: 4)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        return time
    }

    /// Waits until the player plays at `expected` with frames that keep up (at most 30 s, the engine fallback after
    /// `AVPlayerViewModel.stallTimeout` of a movie AVPlayer plays directly), then watches it play for 3 s.
    func measure(_ label: String, expected: Double, from begin: Date = Date(), paused: Bool = false) async -> SeekMeasurement {
        var latency = -1.0
        var fellBackHere = false
        while Date().timeIntervalSince(begin) < 30 {
            let now = currentTime
            let frameLag = frames.lastFrameTime.map { now - $0 } ?? .infinity
            let near = abs(now - expected) < 6
            if paused {
                if player.timeControlStatus == .paused, near, abs(frameLag) < 1.5, (!usesSeeker || !seeker.isBusy) {
                    latency = Date().timeIntervalSince(begin)
                    break
                }
            } else if player.timeControlStatus == .playing, near, abs(frameLag) < 1.0, !usesSeeker || !seeker.isBusy {
                // (With PlayerSeeker, only once the seek is over: a target a few seconds ahead is "near" before it.)
                latency = Date().timeIntervalSince(begin)
                break
            }
            if !fellBack, route == .direct, let fallback = PlaybackRoute.onDemandFallback(for: url),
               Date().timeIntervalSince(begin) > 12, player.timeControlStatus != .playing {
                print("[stress] \(label): AVPlayer stalled for 12 s: falling back to the engine")
                fellBack = true
                fellBackHere = true
                close()
                route = fallback
                _ = await open(resumeAt: expected, quiet: true)
            }
            await run(for: 0.05)
        }
        if paused {
            report(label)
            let ok = latency >= 0
            print(String(format: "[stress] %-22@ expected=%7.1f time=%7.1f latency=%5.2fs frames=%@ => %@", label as NSString, expected, currentTime, latency,
                         frames.lastFrameTime.map { String(format: "%.1f", $0) } ?? "none", ok ? "OK" : "FAIL"))
            return SeekMeasurement(label: label, latency: latency, ok: ok)
        }
        let landed = currentTime
        // Where playback started, against the target: AVPlayer lands within its tolerance (a quarter of a second)
        // when the segment there starts with a key frame; a segment cut inside a GOP plays from its next key frame.
        let landingError = latency >= 0 ? landed - expected : .infinity
        let framesBefore = frames.frames
        // Playback must go on, with frames that follow the clock.
        var worstLag = 0.0
        for _ in 0..<30 {
            await run(for: 0.1)
            if let frame = frames.lastFrameTime {
                worstLag = max(worstLag, currentTime - frame)
            } else {
                worstLag = .infinity
            }
        }
        let advanced = currentTime - landed
        let newFrames = frames.frames - framesBefore
        let brightness = frames.lastBrightness ?? 0
        let ok = latency >= 0 && abs(landingError) < 3 && advanced > 2 && newFrames > 30 && worstLag < 1.0 && brightness > 20
        report(label)
        print(String(format: "[stress] %-22@ expected=%7.1f landed=%7.1f (%+.1f) latency=%5.2fs advanced=%.1f frames=%d worst-video-lag=%.2fs brightness=%.0f%@ => %@",
                     label as NSString, expected, landed, landingError, latency, advanced, newFrames, worstLag, brightness, fellBackHere ? " (engine fallback)" : "",
                     ok ? "OK" : "FAIL"))
        if !ok {
            failures.append("stress \(label)")
            for event in item?.errorLog()?.events.suffix(4) ?? [] {
                print("[stress]   error log: \(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "-") \(event.uri ?? "-")")
            }
        }
        return SeekMeasurement(label: label, latency: latency, ok: ok)
    }

    /// The end of the media the player buffered from the current position, nil when none is.
    func bufferedEnd() -> Double? {
        let now = currentTime
        for range in item?.loadedTimeRanges.map(\.timeRangeValue) ?? [] where range.start.isNumeric && range.duration.isNumeric {
            let start = range.start.seconds
            let end = start + range.duration.seconds
            if start <= now + 0.5 && end >= now {
                return end
            }
        }
        return nil
    }

    /// A seek just past what the player buffered (the scrubber released a little ahead, e.g. after a burst of skips):
    /// the engine wrote the segment there while it read ahead, without a key frame at its start (inputs without an
    /// index), and the player asks for it as the next segment of the one it loaded last. It must still play from the
    /// target, not from the next key frame (the picture frozen, or the playback starting several seconds late).
    /// `direct`: AVPlayer seeks itself, not through PlayerSeeker, as Picture in Picture's skip buttons do (the
    /// engine hears of it from the time jump, `Check.timeJumped()`).
    func seekPastBuffer(_ results: inout [SeekMeasurement], direct: Bool = false) async {
        let label = direct ? "PiP past the buffer" : "past the buffer"
        guard let duration, let end = bufferedEnd(), end + 1 < duration - 20 else {
            print("[stress] \(label): skipped (buffered to \(bufferedEnd().map { String(format: "%.1f", $0) } ?? "none"))")
            return
        }
        let target = end + 1
        let begin = Date()
        simulatesPictureInPicture = direct
        defer {
            simulatesPictureInPicture = false
        }
        if direct {
            let tolerance = CMTime(value: 1, timescale: 4)
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in }
            // The time jump comes a moment later and may start a seek through the seeker (Check.timeJumped): measured
            // from the seek, but not judged before (AVPlayer still says it plays where it went).
            await run(for: 0.5)
        } else {
            userSeek(target)
        }
        results.append(await measure(label, expected: target, from: begin))
    }

    /// SCENARIO=dropped: AVPlayer dropping seeks (completing them as not finished, as it does while it starts an
    /// item) through PlayerSeeker.seekInterceptor. A seek must never stay busy: after one or a few drops it plays at
    /// the target (the seeker makes it again, then recovers); when every seek is dropped it ends failed (Try Again).
    func droppedScenario() async {
        guard await open(resumeAt: nil) else {
            return
        }
        guard let duration, duration > 120 else {
            failures.append("dropped: no duration")
            return
        }
        await run(for: 2)
        for (label, drops, fraction) in [("1 drop", 1, 0.3), ("3 drops", 3, 0.6), ("4 drops", 4, 0.2), ("7 drops", 7, 0.5), ("every seek dropped", Int.max, 0.8)] {
            var remaining = drops
            var dropped = 0
            seeker.seekInterceptor = { completion in
                guard remaining > 0 else {
                    return false
                }
                remaining -= 1
                dropped += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    completion(false)
                }
                return true
            }
            let target = clamp(duration * fraction)
            let begin = Date()
            userSeek(target)
            while seeker.isBusy && Date().timeIntervalSince(begin) < 40 {
                await run(for: 0.05)
            }
            let elapsed = Date().timeIntervalSince(begin)
            seeker.seekInterceptor = nil
            let phase = seeker.phase
            print(String(format: "[dropped] %-20@ drops=%d phase=%@ after %.2fs time=%.1f", label as NSString, dropped, String(describing: phase), elapsed, currentTime))
            if drops == Int.max {
                if phase != .failed {
                    failures.append("dropped \(label): \(phase) instead of failed")
                }
                seeker.clearFailure()
                // Playback goes on where it was; the next seek works again.
                let next = clamp(duration * 0.4)
                let again = Date()
                userSeek(next)
                _ = await measure("seek after the failure", expected: next, from: again)
            } else if phase != .idle {
                failures.append("dropped \(label): \(phase) after \(elapsed) s")
            } else {
                _ = await measure(label, expected: target, from: begin)
            }
        }
        close()
    }

    func stressScenario() async {
        guard await open(resumeAt: nil) else {
            return
        }
        guard let duration, duration > 120 else {
            failures.append("stress: no duration")
            return
        }
        var results: [SeekMeasurement] = []
        if ProcessInfo.processInfo.environment["STRESS_BURST"] != nil {
            // Four +30 taps after a seek to 40 %, alone (with VERBOSE=1 and FLUXO_ENGINE_TRACE=1 for a close look).
            let begin = Date()
            userSeek(duration * 0.4)
            _ = await measure("seek to 40%", expected: duration * 0.4, from: begin)
            var expected = currentTime
            for _ in 0..<4 {
                expected = userSkip(30)
                await run(for: 0.15)
            }
            print(String(format: "[stress] last tap at %.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))
            _ = await measure("4x skip +30", expected: expected, from: Date())
            var results: [SeekMeasurement] = []
            await seekPastBuffer(&results)
            close()
            return
        }
        if let only = ProcessInfo.processInfo.environment["STRESS_SEEK"].flatMap(Double.init) {
            // One seek, to that many seconds before the end (negative) or to that time (with VERBOSE=1 and
            // FLUXO_ENGINE_TRACE=1 for a close look).
            let target = only < 0 ? duration + only : only
            let begin = Date()
            userSeek(target)
            _ = await measure("seek to \(Int(target))", expected: target, from: begin)
            close()
            return
        }

        // 1. A drag from about 10 % to 40 %, 20 finger moves in 0.8 s, then the release.
        var position = duration * 0.1
        for i in 1...20 {
            position = duration * (0.1 + 0.3 * Double(i) / 20)
            userDrag(position)
            await run(for: 0.04)
        }
        var begin = Date()
        print(String(format: "[stress] release at %.2f", begin.timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))
        userSeek(position)
        results.append(await measure("drag to 40%", expected: position, from: begin))
        if ProcessInfo.processInfo.environment["STRESS_STEPS"] == "1" {
            // A quick look at one seek (with VERBOSE=1 and FLUXO_ENGINE_TRACE=1).
            close()
            return
        }

        // 2. +30 tapped four times, 150 ms apart: one seek to +120.
        var expected = currentTime
        for _ in 0..<4 {
            expected = userSkip(30)
            await run(for: 0.15)
        }
        begin = Date()
        if !usesSeeker {
            expected = clamp(currentTime)
        }
        results.append(await measure("4x skip +30", expected: usesSeeker ? expected : currentTime, from: begin))

        // 2b. Released just past what the player buffered after the skips (see seekPastBuffer), then Picture in
        // Picture's skip button just past it again (AVPlayer seeks itself).
        await seekPastBuffer(&results)
        if usesSeeker {
            await seekPastBuffer(&results, direct: true)
        }

        // 3. -10 tapped three times.
        for _ in 0..<3 {
            expected = userSkip(-10)
            await run(for: 0.15)
        }
        begin = Date()
        results.append(await measure("3x skip -10", expected: usesSeeker ? expected : currentTime, from: begin))

        // 4. Released at 70 %, then again at 55 % 300 ms later (a correction).
        userSeek(duration * 0.7)
        await run(for: 0.3)
        begin = Date()
        userSeek(duration * 0.55)
        results.append(await measure("release twice", expected: duration * 0.55, from: begin))

        // 5. A short drag back and forth around 80 %, then the release (fine positioning).
        for i in 0..<12 {
            userDrag(duration * (0.8 + (i % 2 == 0 ? 0.01 : -0.01)))
            await run(for: 0.05)
        }
        begin = Date()
        userSeek(duration * 0.8)
        results.append(await measure("fine drag at 80%", expected: duration * 0.8, from: begin))

        // 6. Near the end (8 s before it).
        begin = Date()
        userSeek(duration - 8)
        let nearEnd = await measure("8 s before the end", expected: duration - 8, from: begin)
        results.append(nearEnd)
        await run(for: 7)

        // 7. Back to 20 % (after the end, or about it).
        begin = Date()
        userSeek(duration * 0.2)
        player.play()
        results.append(await measure("back to 20%", expected: duration * 0.2, from: begin))

        // 8. Seek, pause right away, play 2 s later.
        userSeek(duration * 0.35)
        player.pause()
        begin = Date()
        results.append(await measure("seek then pause", expected: duration * 0.35, from: begin, paused: true))
        await run(for: 2)
        begin = Date()
        player.play()
        results.append(await measure("then play", expected: duration * 0.35, from: begin))

        // 9. Close and resume at the saved position, then skip.
        let saved = currentTime
        close()
        await run(for: 1)
        route = PlaybackRoute(url: url, kind: kind)
        fellBack = false
        begin = Date()
        guard await open(resumeAt: saved, quiet: true) else {
            failures.append("stress: reopen failed")
            return
        }
        results.append(await measure("resume", expected: saved, from: begin))
        begin = Date()
        expected = userSkip(30)
        results.append(await measure("skip +30 after resume", expected: expected, from: begin))
        close()

        let latencies = results.filter { $0.latency >= 0 }.map(\.latency).sorted()
        let median = latencies.isEmpty ? -1 : latencies[latencies.count / 2]
        print(String(format: "[stress] summary seeker=%@ route=%@ seeks=%d failed=%d median=%.2fs worst=%.2fs", usesSeeker ? "PlayerSeeker" : "legacy",
                     String(describing: route), results.count, results.filter { !$0.ok }.count, median, latencies.last ?? -1))
    }
}
