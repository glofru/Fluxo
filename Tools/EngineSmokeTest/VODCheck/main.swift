//
//  main.swift
//  VODCheck
//
//  Plays an on-demand URL the way AVPlayerViewModel does: PlaybackRoute picks AVPlayer or the remux engine;
//  the engine route uses the app's StreamRemuxer and SimpleHTTPServer (on another loopback port, see
//  run_vod.sh). Then it seeks like the player controls (skip +30 s, scrub to 25 / 50 / 90 %, skip back),
//  closes the item and reopens it at the saved position (resume), and checks after every step that
//  playback continues with real (non-black) video frames. Inputs with several audio tracks or text subtitles
//  play the engine's master playlist, like the app: the check then switches the audio track and turns subtitles
//  on, and the cues AVPlayer shows must come at their own time ("Cue at <seconds> s"), after every seek too.
//  macOS only. See run_vod.sh.
//
//  Usage: VODCheck <url> [movie|series|live|none]
//

import AVFoundation
import CoreVideo
import Foundation

@MainActor
final class Check {
    let url: URL
    let kind: ChannelContentKind?
    let server = SimpleHTTPServer()
    let remuxer = StreamRemuxer()
    let player = AVPlayer()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fluxo-vod-check-\(getpid())", isDirectory: true)
    var item: AVPlayerItem?
    var output: AVPlayerItemVideoOutput?
    var route: PlaybackRoute
    var failures: [String] = []
    var firstSegment: CheckedContinuation<Void, Never>?
    var engineFailure: String?
    /// The engine wrote a master playlist (audio tracks or subtitles to choose from).
    var hasMasterPlaylist = false
    var subtitleTrackCount = 0
    /// The movie moved from AVPlayer to the engine (once, like the app).
    var fellBack = false
    let cues = CueCollector()
    /// Where the seeks landed (item times), for the subtitle check.
    var seekLandings: [Double] = []

    init(url: URL, kind: ChannelContentKind?) {
        self.url = url
        self.kind = kind
        self.route = PlaybackRoute(url: url, kind: kind)
        remuxer.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func handle(_ event: StreamRemuxer.Event) {
        switch event {
        case .state(let state):
            print("[engine] state \(state)")
            if case .failed(let message) = state {
                engineFailure = message
                firstSegment?.resume()
                firstSegment = nil
            }
        case .segmentWritten(let statistics):
            if firstSegment != nil {
                hasMasterPlaylist = statistics.hasMasterPlaylist
                subtitleTrackCount = statistics.subtitleTrackCount
                if hasMasterPlaylist {
                    print("[check] master playlist: \(statistics.audioTrackCount) audio, \(statistics.subtitleTrackCount) subtitle tracks")
                }
            }
            if statistics.segmentsWritten == 1 || statistics.segmentsWritten % 25 == 0 {
                print("[engine] segments written=\(statistics.segmentsWritten) on disk=\(statistics.segmentCount) bytes=\(statistics.bytes)")
            }
            firstSegment?.resume()
            firstSegment = nil
        default:
            break
        }
    }

    func run(for seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// Opens the URL like AVPlayerViewModel.start(_:url:), then waits until it plays (at most 30 s).
    func open(resumeAt: Double?) async -> Bool {
        print("[check] route \(route)")
        let item: AVPlayerItem
        switch route {
        case .direct:
            item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 30
        case .remux(let isLive):
            server.start(root: directory)
            var configuration = StreamRemuxer.Configuration(inputURL: url, outputDirectory: directory, name: "check-\(UUID().uuidString.prefix(8))", isLive: isLive)
            if isLive {
                configuration.maxWindowDuration = 30 * 60
                configuration.maxWindowBytes = 512 * 1024 * 1024
            } else {
                configuration.segmentDuration = 4
                configuration.readAheadDuration = 60
                configuration.maxWindowDuration = 0
                configuration.maxWindowBytes = Int64(ProcessInfo.processInfo.environment["CACHE_BYTES"].flatMap(Int64.init) ?? 512 * 1024 * 1024)
                let remuxer = remuxer
                let verbose = ProcessInfo.processInfo.environment["VERBOSE"] != nil
                server.setFileProvider { fileName in
                    let begin = Date()
                    let available = await remuxer.requestFile(named: fileName)
                    if verbose {
                        print(String(format: "[serve] %@ -> %@ after %.2fs", fileName, available ? "200" : "404", Date().timeIntervalSince(begin)))
                    }
                    return available
                }
            }
            do {
                try remuxer.start(configuration)
            } catch {
                failures.append("engine start: \(error)")
                return false
            }
            await withCheckedContinuation { firstSegment = $0 }
            if let engineFailure {
                failures.append("engine: \(engineFailure)")
                return false
            }
            await server.waitUntilListening()
            if !isLive {
                checkPlaylist(at: directory.appendingPathComponent(configuration.playlistFileName), segmentDuration: configuration.segmentDuration)
            }
            // AVPlayerViewModel: extra audio tracks or text subtitles are renditions of the master playlist.
            let playlist = hasMasterPlaylist ? configuration.masterPlaylistFileName : configuration.playlistFileName
            item = AVPlayerItem(url: SimpleHTTPServer.url(forFileNamed: playlist)!)
            item.preferredForwardBufferDuration = 8
            if hasMasterPlaylist {
                // An output belongs to one item.
                let legibleOutput = AVPlayerItemLegibleOutput()
                legibleOutput.setDelegate(cues, queue: .main)
                item.add(legibleOutput)
            }
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        self.item = item
        self.output = output
        player.replaceCurrentItem(with: item)
        player.play()
        let begin = Date()
        while player.timeControlStatus != .playing && Date().timeIntervalSince(begin) < 40 && item.status != .failed {
            await run(for: 0.1)
        }
        print(String(format: "[check] playing after %.1fs", Date().timeIntervalSince(begin)))
        if item.status == .failed {
            // AVPlayerViewModel.handleItemFailure: a movie AVPlayer cannot open plays through the engine.
            if route == .direct, let fallback = PlaybackRoute.onDemandFallback(for: url) {
                print("[check] AVPlayer failed (\(item.error?.localizedDescription ?? "-")): falling back to the engine")
                fellBack = true
                close()
                route = fallback
                return await open(resumeAt: resumeAt)
            }
            failures.append("start: \(item.error?.localizedDescription ?? "failed")")
            return false
        }
        // AVPlayerViewModel.checkVideoIsDecodable: video AVPlayer cannot decode (hev1) plays through the engine.
        if route == .direct, let fallback = PlaybackRoute.onDemandFallback(for: url),
           let tracks = try? await item.asset.loadTracks(withMediaType: .video), !tracks.isEmpty {
            var playable = false
            for track in tracks where (try? await track.load(.isPlayable)) == true {
                playable = true
            }
            if !playable {
                print("[check] AVPlayer cannot decode the video track: falling back to the engine")
                close()
                route = fallback
                return await open(resumeAt: resumeAt)
            }
        }
        if let resumeAt {
            // WatchProgressRecorder: once the item can seek that far.
            while (range()?.1 ?? 0) < resumeAt && Date().timeIntervalSince(begin) < 20 {
                await run(for: 0.1)
            }
            seekLandings.append(resumeAt)
            await step("resume \(Int(resumeAt))s", attempts: 3) { resumeAt }
        } else {
            await run(for: 3)
            report("start")
        }
        return true
    }

    /// The playlist of an on-demand input: short segments (a seek reads one), whether it is planned whole
    /// (VOD) or grows while the input is read (EVENT).
    func checkPlaylist(at url: URL, segmentDuration: Double) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            failures.append("playlist: unreadable")
            return
        }
        let durations = text.split(separator: "\n").compactMap { line -> Double? in
            guard line.hasPrefix("#EXTINF:") else {
                return nil
            }
            return Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
        }
        let type = text.contains("#EXT-X-PLAYLIST-TYPE:VOD") ? "VOD" : text.contains("#EXT-X-PLAYLIST-TYPE:EVENT") ? "EVENT" : "other"
        let longest = durations.max() ?? 0
        print(String(format: "[check] playlist %@ segments=%d total=%.1fs longest=%.1fs%@", type, durations.count, durations.reduce(0, +), longest,
                     text.contains("#EXT-X-MAP") ? " fMP4" : ""))
        // Segments are cut at the next key frame after the planned time: a GOP longer than 2.5 s lengthens them.
        if longest > segmentDuration * 3 {
            failures.append(String(format: "playlist: a segment of %.1f s", longest))
        }
    }

    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        remuxer.stop()
        server.setFileProvider(nil)
    }

    func range() -> (Double, Double)? {
        guard let r = item?.seekableTimeRanges.last?.timeRangeValue, r.start.isNumeric, r.duration.isNumeric else {
            return nil
        }
        return (r.start.seconds, r.start.seconds + r.duration.seconds)
    }

    var duration: Double? {
        if let item, item.duration.isNumeric, item.duration.seconds > 0 {
            return item.duration.seconds
        }
        return range()?.1
    }

    var currentTime: Double {
        item?.currentTime().seconds ?? 0
    }

    /// Mean brightness (0...255) of the latest video frame, or nil when there is none.
    func frameBrightness() -> Double? {
        guard let output else {
            return nil
        }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
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

    func report(_ label: String) {
        guard let item else {
            return
        }
        let control = ["paused", "waiting", "playing"][player.timeControlStatus.rawValue]
        let status = ["unknown", "ready", "failed"][item.status.rawValue]
        let r = range()
        print(String(format: "[check] %-16@ status=%@ control=%@ time=%7.1f duration=%7.1f seekable=%.1f...%.1f%@", label as NSString, status, control,
                     currentTime, duration ?? -1, r?.0 ?? -1, r?.1 ?? -1, item.error.map { " error=\($0.localizedDescription)" as NSString } ?? ""))
    }

    /// Seeks like AVPlayerViewModel.seek(to:) and checks that playback continues with real frames there.
    func step(_ label: String, attempts: Int = 1, target: () -> Double?) async {
        guard let target = target() else {
            failures.append("\(label): no seekable range")
            print("[check] \(label): no seekable range => FAIL")
            return
        }
        let tolerance = CMTime(value: 1, timescale: 4)
        let begin = Date()
        seekLandings.append(target)
        // A resume is made again until playback is there, like WatchProgressRecorder and
        // AVPlayerViewModel.resume(at:in:) do: AVPlayer can drop a seek made while it starts an item.
        for attempt in 1...attempts {
            let finished = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
            if !finished {
                print("[check] \(label): the seek was interrupted (attempt \(attempt))")
            }
            await run(for: 0.5)
            if abs(currentTime - target) <= 5 {
                break
            }
        }
        // AVPlayerViewModel.stallTimeout for a movie AVPlayer plays itself.
        let wait: Double = route == .direct && !fellBack && PlaybackRoute.onDemandFallback(for: url) != nil ? 12 : 20
        while player.timeControlStatus != .playing && Date().timeIntervalSince(begin) < wait && item?.status != .failed {
            await run(for: 0.1)
        }
        // AVPlayerViewModel.watchForStall / handleItemFailure: a movie AVPlayer keeps waiting for (or fails on)
        // plays through the engine from there.
        if player.timeControlStatus != .playing, route == .direct, !fellBack, let fallback = PlaybackRoute.onDemandFallback(for: url) {
            print("[check] \(label): AVPlayer \(item?.status == .failed ? "failed" : "stalled"): falling back to the engine")
            fellBack = true
            // What AVPlayer did before is what the fallback is for (servers that allow one connection per account).
            if !failures.isEmpty {
                print("[check] before the fallback: \(failures)")
                failures.removeAll()
            }
            close()
            route = fallback
            guard await open(resumeAt: target) else {
                failures.append("\(label): the engine did not start")
                return
            }
            return
        }
        let latency = Date().timeIntervalSince(begin)
        let landed = currentTime
        seekLandings.append(landed)
        await run(for: 3)
        let advanced = currentTime - landed
        let brightness = frameBrightness()
        report(label)
        let ok = player.timeControlStatus == .playing && advanced > 1.5 && (brightness ?? 0) > 20 && abs(landed - target) < 6
        print(String(format: "[check] %@ target=%.1f landed=%.1f advanced=%.1f latency=%.1fs brightness=%@ => %@", label, target, landed, advanced, latency,
                     brightness.map { String(format: "%.0f", $0) } ?? "none", ok ? "OK" : "FAIL"))
        if !ok {
            failures.append(label)
            for event in item?.errorLog()?.events ?? [] {
                print("[check]   error log: \(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "-") \(event.uri ?? "-")")
            }
        }
    }

    /// Master playlist: switches to the last audio track and turns on the first full subtitles; playback must go
    /// on (an audio track the device cannot decode would fail the item).
    func selectTracks() async {
        guard hasMasterPlaylist, let item else {
            return
        }
        do {
            let audible = try await item.asset.loadMediaSelectionGroup(for: .audible)
            let legible = try await item.asset.loadMediaSelectionGroup(for: .legible)
            print("[check] tracks audio=\(audible?.options.map(\.displayName) ?? []) subtitles=\(legible?.options.map(\.displayName) ?? [])")
            if let audible, let last = audible.options.last, audible.options.count > 1 {
                item.select(last, in: audible)
            } else {
                failures.append("tracks: fewer than 2 audio options")
            }
            // (AVPlayer may list a legible option of its own; only the engine's subtitles have cues to check.)
            if subtitleTrackCount > 0, let legible, let full = AVMediaSelectionGroup.mediaSelectionOptions(from: legible.options, withoutMediaCharacteristics: [.containsOnlyForcedSubtitles]).first {
                item.select(full, in: legible)
                cues.expectsCues = true
            }
        } catch {
            failures.append("tracks: \(error)")
        }
        await step("audio switch") { currentTime + 1 }
        if let audible = try? await item.asset.loadMediaSelectionGroup(for: .audible),
           item.currentMediaSelection.selectedMediaOption(in: audible) != audible.options.last {
            failures.append("audio switch not applied")
        }
    }

    /// The cues shown so far: some, each at its own time.
    func checkCues() {
        guard cues.expectsCues else {
            return
        }
        // A cue already on screen where a seek landed is shown there.
        let late = cues.cues.filter { cue in
            abs(cue.shown - cue.expected) > 1 && !seekLandings.contains { cue.expected <= $0 + 0.5 && cue.shown >= $0 - 0.5 && cue.shown <= $0 + 2 }
        }
        print(String(format: "[check] subtitles cues=%d mistimed=%d%@ => %@", cues.cues.count, late.count,
                     late.first.map { String(format: " (cue of %.0f s shown at %.1f s)", $0.expected, $0.shown) } ?? "",
                     cues.cues.count >= 3 && late.isEmpty ? "OK" : "FAIL"))
        if cues.cues.count < 3 {
            failures.append("subtitles: \(cues.cues.count) cues shown")
        }
        if !late.isEmpty {
            failures.append("subtitles: \(late.count) cues at the wrong time")
        }
    }

    /// A live channel (kind `live`): plays from the live edge with video, then within the time-shift window.
    func liveScenario() async {
        guard await open(resumeAt: nil) else {
            return
        }
        await step("live edge") { currentTime }
        await selectTracks()
        await run(for: 8)
        await step("time-shift -10") { currentTime - 10 }
        await step("back to live") { range().map { $0.1 - 3 } }
        close()
    }

    func scenario() async {
        if kind == .live {
            await liveScenario()
            return
        }
        guard await open(resumeAt: nil) else {
            return
        }
        await selectTracks()
        await step("skip +30") { currentTime + 30 }
        await step("skip +30 again") { currentTime + 30 }
        for fraction in [0.25, 0.5, 0.9] {
            await step("scrub \(Int(fraction * 100))%") { duration.map { $0 * fraction } }
        }
        await step("skip -10") { currentTime - 10 }
        await step("scrub 10%") { duration.map { $0 * 0.1 } }
        // Close and reopen at the saved position, like Continue Watching.
        let saved = (duration ?? 0) * 0.6
        await step("scrub 60%") { saved }
        let position = currentTime
        checkCues()
        close()
        await run(for: 1)
        print("[check] reopen at \(Int(position))s")
        // A new start takes the route of the URL again (and falls back again if it has to).
        route = PlaybackRoute(url: url, kind: kind)
        fellBack = false
        guard await open(resumeAt: position) else {
            return
        }
        await step("skip +30 after resume") { currentTime + 30 }
        close()
    }
}

/// Subtitle cues AVPlayer delivers. The test subtitles say when they start ("Cue at 125 s").
final class CueCollector: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var expectsCues = false
    var cues: [(expected: Double, shown: Double)] = []

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        for string in strings {
            let text = string.string
            guard let range = text.range(of: "Cue at "), let seconds = Double(text[range.upperBound...].prefix { $0.isNumber }) else {
                continue
            }
            // Each cue is reported when it starts (a cue repeated in the next segment is not shown again).
            if !cues.contains(where: { $0.expected == seconds && abs($0.shown - itemTime.seconds) < 1 }) {
                cues.append((seconds, itemTime.seconds))
                print(String(format: "[cue] %.0f s shown at %.2f s", seconds, itemTime.seconds))
            }
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count > 1, let url = URL(string: arguments[1]) else {
    print("usage: VODCheck <url> [movie|series|live|none]")
    exit(2)
}
let kind: ChannelContentKind? = switch arguments.count > 2 ? arguments[2] : "movie" {
case "live": .live
case "series": .series
case "none": nil
default: .movie
}
setvbuf(stdout, nil, _IOLBF, 0)
Task { @MainActor in
    let check = Check(url: url, kind: kind)
    await check.scenario()
    try? FileManager.default.removeItem(at: check.directory)
    print("[check] result \(check.failures.isEmpty ? "PASS" : "FAIL") route=\(check.route) failures=\(check.failures)")
    exit(check.failures.isEmpty ? 0 : 1)
}
RunLoop.main.run()
