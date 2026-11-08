//
//  main.swift
//  VODCheck
//
//  Plays an on-demand URL the way AVPlayerViewModel does: PlaybackRoute picks AVPlayer or the remux engine;
//  the engine route uses the app's StreamRemuxer and SimpleHTTPServer (on a free loopback port, with its session
//  token, like the app). Then it seeks like the player controls (skip +30 s, scrub to 25 / 50 / 90 %, skip back),
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
    /// The app's seek coordinator (SCENARIO=stress, see Stress.swift).
    lazy var seeker = PlayerSeeker(player: player)
    let frames = FrameWatcher()
    var jumpObserver: (any NSObjectProtocol)?
    var bufferObserver: Any?
    /// AVPlayerViewModel.sampledBufferedEnd.
    var sampledBufferedEnd: Double?
    /// AVPlayerViewModel.isPictureInPictureActive, for itemTimeJumped.
    var simulatesPictureInPicture = false
    /// SCENARIO=livepause: the last segment the engine wrote, and the one before its input closed (InputSuspended).
    var lastSegmentIndex = -1
    var suspendedAfterSegment: Int?
    /// The dates of the media playlist when the input closed, and the item's clock then (AVPlayerViewModel.Suspension).
    var frozenDates: Range<Date>?
    var suspendedClock: PausedTimeShiftPolicy.MediaClock?
    /// The clock of the item open() started, read before it played (AVPlayerViewModel.itemClock).
    var itemClock: PausedTimeShiftPolicy.MediaClock?

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
            lastSegmentIndex = statistics.segmentIndex
            firstSegment?.resume()
            firstSegment = nil
        case .inputSuspended(let lastSegmentIndex):
            print("[engine] input suspended after segment \(lastSegmentIndex)")
            suspendedAfterSegment = lastSegmentIndex
            let frozenPlaylist = remuxer.configuration.flatMap { try? String(contentsOf: $0.playlistURL, encoding: .utf8) }
            frozenDates = frozenPlaylist.flatMap(PausedTimeShiftPolicy.dateRange(ofPlaylist:))
            if ProcessInfo.processInfo.environment["LIVEPAUSE_SCAN"] == "1" {
                print("[scan] frozen playlist:\n\(frozenPlaylist ?? "-")")
            }
            if let item {
                suspendedClock = itemClock ?? PausedTimeShiftPolicy.MediaClock(itemTime: item.currentTime().seconds, date: item.currentDate())
            }
        default:
            break
        }
    }

    func run(for seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// Opens the URL like AVPlayerViewModel.start(_:url:), then waits until it plays (at most 30 s).
    func open(resumeAt: Double?, quiet: Bool = false) async -> Bool {
        print("[check] route \(route)")
        let item: AVPlayerItem
        switch route {
        case .direct:
            item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 30
            seeker.onWillSeek = nil
            seeker.stallLimit = .seconds(8)
        case .remux(let isLive):
            server.beginSession()
            server.start(root: directory)
            var configuration = StreamRemuxer.Configuration(inputURL: url, outputDirectory: directory, name: "check-\(UUID().uuidString.prefix(8))", isLive: isLive)
            if isLive {
                // WINDOW_SECONDS: a short time-shift window, which lets go of its oldest segments (SCENARIO=livepause).
                configuration.maxWindowDuration = Double(ProcessInfo.processInfo.environment["WINDOW_SECONDS"] ?? "") ?? 30 * 60
                configuration.maxWindowBytes = 512 * 1024 * 1024
            } else {
                configuration.segmentDuration = 4
                configuration.readAheadDuration = 60
                configuration.maxWindowDuration = 0
                configuration.maxWindowBytes = Int64(ProcessInfo.processInfo.environment["CACHE_BYTES"].flatMap(Int64.init) ?? 512 * 1024 * 1024)
                // AVPlayerViewModel.start: a resume starts the engine there.
                if let resumeAt, resumeAt >= 10, ProcessInfo.processInfo.environment["STARTTIME"] != "0" {
                    configuration.startTime = resumeAt
                }
                let remuxer = remuxer
                let verbose = ProcessInfo.processInfo.environment["VERBOSE"] != nil
                server.setFileProvider { fileName in
                    let begin = Date()
                    if verbose {
                        print(String(format: "[serve] %@ requested at %.2f", fileName, begin.timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))
                    }
                    let available = await remuxer.requestFile(named: fileName)
                    if verbose {
                        print(String(format: "[serve] %@ -> %@ after %.2fs at %.2f", fileName, available ? "200" : "404", Date().timeIntervalSince(begin), Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))
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
            // AVPlayerViewModel.configureSeeker: every seek tells the engine where it goes (NOTE_SEEK=0 does not,
            // as before fluxo_remux_note_seek).
            if ProcessInfo.processInfo.environment["NOTE_SEEK"] != "0" {
                seeker.onWillSeek = { [remuxer] time in remuxer.noteSeek(to: time) }
            } else {
                seeker.onWillSeek = nil
            }
            // AVPlayerViewModel.engineSeekStallLimit.
            seeker.stallLimit = .seconds(20)
            await withCheckedContinuation { firstSegment = $0 }
            if let engineFailure {
                failures.append("engine: \(engineFailure)")
                return false
            }
            guard await server.waitUntilListening() else {
                failures.append("loopback server: not listening")
                return false
            }
            if !isLive {
                checkPlaylist(at: directory.appendingPathComponent(configuration.playlistFileName), segmentDuration: configuration.segmentDuration)
            }
            // AVPlayerViewModel: extra audio tracks or text subtitles are renditions of the master playlist.
            let playlist = hasMasterPlaylist ? configuration.masterPlaylistFileName : configuration.playlistFileName
            item = AVPlayerItem(url: server.url(forFileNamed: playlist)!)
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
        if route == .remux(isLive: false), ProcessInfo.processInfo.environment["NOTE_JUMP"] != "0" {
            // AVPlayerViewModel.itemTimeJumped: a seek the seeker did not make (Picture in Picture's skip buttons)
            // past the buffer is made again through the seeker (NOTE_JUMP=0 does not). On the posting queue, like the app.
            sampledBufferedEnd = nil
            bufferObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let item = self.item else {
                        return
                    }
                    self.sampledBufferedEnd = item.loadedTimeRanges.map(\.timeRangeValue).map { $0.start.seconds + $0.duration.seconds }.filter(\.isFinite).max()
                }
            }
            jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: nil) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.timeJumped()
                    }
                } else {
                    Task { @MainActor in
                        self?.timeJumped()
                    }
                }
            }
        }
        frames.start(output: output) { [weak self] _ in self?.frameBrightness() }
        player.replaceCurrentItem(with: item)
        player.play()
        let begin = Date()
        // AVPlayerViewModel.itemClock: a live item's clock, read before it plays (PausedTimeShiftPolicy.MediaClock).
        let isLiveRemux = route == .remux(isLive: true)
        itemClock = nil
        while player.timeControlStatus != .playing && Date().timeIntervalSince(begin) < 40 && item.status != .failed {
            if isLiveRemux, itemClock == nil {
                itemClock = PausedTimeShiftPolicy.MediaClock(itemTime: item.currentTime().seconds, date: item.currentDate())
            }
            await run(for: isLiveRemux ? 0.01 : 0.1)
        }
        print(String(format: "[check] playing after %.1fs", Date().timeIntervalSince(begin)))
        if item.status == .failed {
            // AVPlayerViewModel.handleItemFailure: a movie AVPlayer cannot open plays through the engine.
            if route == .direct, let fallback = PlaybackRoute.onDemandFallback(for: url) {
                print("[check] AVPlayer failed (\(item.error?.localizedDescription ?? "-")): falling back to the engine")
                fellBack = true
                close()
                route = fallback
                return await open(resumeAt: resumeAt, quiet: quiet)
            }
            failures.append("start: \(item.error?.localizedDescription ?? "failed")")
            return false
        }
        // AVPlayerViewModel.checkTracksAreDecodable: video AVPlayer cannot decode (hev1) or audio it cannot decode or
        // does not even list (DTS) plays through the engine, which converts it.
        if route == .direct, let fallback = PlaybackRoute.onDemandFallback(for: url) {
            func tracks(_ mediaType: AVMediaType) async -> [PlaybackRoute.DirectTrack] {
                var result: [PlaybackRoute.DirectTrack] = []
                for track in (try? await item.asset.loadTracks(withMediaType: mediaType)) ?? [] {
                    let format = (try? await track.load(.formatDescriptions))?.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
                    result.append(PlaybackRoute.DirectTrack(format: format, isPlayable: (try? await track.load(.isPlayable)) ?? false))
                }
                return result
            }
            let expectsAudio = ProcessInfo.processInfo.environment["EXPECT_AUDIO"] != "0"
            let video = await tracks(.video)
            let audio = await tracks(.audio)
            // (A test file without sound would move to the engine like a movie whose audio AVPlayer does not list.)
            if let reason = PlaybackRoute.engineReason(video: video, audio: audio), expectsAudio || !audio.isEmpty || !reason.hasPrefix("no audio") {
                print("[check] AVPlayer: \(reason): falling back to the engine")
                fellBack = true
                close()
                route = fallback
                return await open(resumeAt: resumeAt, quiet: quiet)
            }
        }
        if let resumeAt {
            // WatchProgressRecorder: once the item can seek that far.
            while (range()?.1 ?? 0) < resumeAt && Date().timeIntervalSince(begin) < 20 {
                await run(for: 0.1)
            }
            seekLandings.append(resumeAt)
            if quiet {
                // Stress.swift measures the resume itself.
                if usesSeeker {
                    seeker.seek(to: resumeAt)
                } else {
                    let tolerance = CMTime(value: 1, timescale: 4)
                    for _ in 1...3 {
                        _ = await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
                        await run(for: 0.5)
                        if abs(currentTime - resumeAt) <= 5 {
                            break
                        }
                    }
                }
                return true
            }
            await step("resume \(Int(resumeAt))s", attempts: 3) { resumeAt }
        } else if !quiet {
            await run(for: 3)
            report("start")
            await checkTracks()
        }
        return true
    }

    /// The tracks AVPlayer plays (their formats tell copied from converted streams), and that the audio is real:
    /// an enabled audio track (unless EXPECT_AUDIO=0) and, for the engine's output, sound in its latest segment.
    func checkTracks() async {
        guard let item else {
            return
        }
        var video: [String] = []
        var audio: [String] = []
        for track in item.tracks where track.isEnabled {
            guard let asset = track.assetTrack else {
                continue
            }
            let formats = ((try? await asset.load(.formatDescriptions)) ?? []).map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) }
            if asset.mediaType == .video {
                video += formats.isEmpty ? ["?"] : formats
            } else if asset.mediaType == .audio {
                audio += formats.isEmpty ? ["?"] : formats
            }
        }
        let expectsAudio = ProcessInfo.processInfo.environment["EXPECT_AUDIO"] != "0"
        let expectsVideo = ProcessInfo.processInfo.environment["EXPECT_VIDEO"] != "0"
        var level = "-"
        // The sound check needs ffmpeg (FFMPEG, exported by run_formats.sh).
        if route != .direct, expectsAudio, ProcessInfo.processInfo.environment["FFMPEG"] != nil {
            let mean = await segmentAudioLevel()
            level = mean.map { String(format: "%.1f dB", $0) } ?? "none"
            if (mean ?? -100) <= -60 {
                failures.append("audio: no sound in the engine's segment (\(level))")
            }
        }
        print("[check] formats video=\(video) audio=\(audio) segment-audio=\(level)")
        if expectsAudio && audio.isEmpty {
            failures.append("audio: no audio track")
        }
        if expectsVideo && video.isEmpty {
            failures.append("video: no video track")
        }
    }

    static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }

    /// Mean volume (dB) of the newest main segment of the engine (with its initialization segment for fMP4), with
    /// FFMPEG's volumedetect; nil without ffmpeg, a segment or audio.
    func segmentAudioLevel() async -> Double? {
        guard let ffmpeg = ProcessInfo.processInfo.environment["FFMPEG"], let configuration = remuxer.configuration else {
            return nil
        }
        let prefix = configuration.filePrefix
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let segments = files.filter { file in
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix + "-"), name.hasSuffix(".ts") || name.hasSuffix(".m4s") else {
                return false
            }
            return configuration.segmentFile(named: name)?.rendition == nil
        }
        guard let newest = segments.max(by: {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }) else {
            return nil
        }
        var input = newest
        if newest.pathExtension == "m4s" {
            let joined = directory.appendingPathComponent("level-check.mp4")
            guard let initData = try? Data(contentsOf: directory.appendingPathComponent("\(prefix)-init.mp4")),
                  let segmentData = try? Data(contentsOf: newest), (try? (initData + segmentData).write(to: joined)) != nil else {
                return nil
            }
            input = joined
        }
        // Off the main actor: the loopback server's requests are answered there while ffmpeg runs.
        let path = input.path
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-hide_banner", "-nostats", "-i", path, "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            guard (try? process.run()) != nil else {
                return nil
            }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard let range = output.range(of: "mean_volume: ") else {
                return nil
            }
            return Double(output[range.upperBound...].prefix { $0 != " " })
        }.value
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
        // (run_seek.sh's movie has key frames 10 s apart: MAX_SEGMENT raises the limit.)
        let limit = ProcessInfo.processInfo.environment["MAX_SEGMENT"].flatMap(Double.init) ?? segmentDuration * 3
        if longest > limit {
            failures.append(String(format: "playlist: a segment of %.1f s", longest))
        }
    }

    /// AVPlayerViewModel.itemTimeJumped (JUMP_MODE=note only tells the engine, which comes too late: AVPlayer asks
    /// for the segment before it posts the jump).
    func timeJumped() {
        // (The app: in Picture in Picture only; here during Stress.swift's "PiP past the buffer".)
        guard simulatesPictureInPicture, let item, !seeker.isMoving, let bufferedEnd = sampledBufferedEnd else {
            return
        }
        let time = item.currentTime().seconds
        guard time.isFinite, time > bufferedEnd - 0.5 else {
            return
        }
        if ProcessInfo.processInfo.environment["VERBOSE"] != nil {
            print(String(format: "[jump] time jumped to %.1f past the buffer (%.1f) outside the seeker at %.2f", time, bufferedEnd,
                         Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))
        }
        if ProcessInfo.processInfo.environment["JUMP_MODE"] == "note" {
            remuxer.noteSeek(to: time)
        } else {
            seeker.seek(to: time)
        }
    }

    func close() {
        if let jumpObserver {
            NotificationCenter.default.removeObserver(jumpObserver)
            self.jumpObserver = nil
        }
        if let bufferObserver {
            player.removeTimeObserver(bufferObserver)
            self.bufferObserver = nil
        }
        frames.stop()
        seeker.reset()
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
        // Audio-only inputs (EXPECT_VIDEO=0) have no frames to look at.
        // MIN_BRIGHTNESS: dark sample files (a night sky) still count as frames.
        let minimum = Double(ProcessInfo.processInfo.environment["MIN_BRIGHTNESS"] ?? "") ?? 20
        let framesOK = ProcessInfo.processInfo.environment["EXPECT_VIDEO"] == "0" || (brightness ?? 0) > minimum
        let ok = player.timeControlStatus == .playing && advanced > 1.5 && framesOK && abs(landed - target) < 6
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
        await checkTracks()
        await selectTracks()
        await run(for: 8)
        await step("time-shift -10") { currentTime - 10 }
        await step("back to live") { range().map { $0.1 - 3 } }
        close()
    }

    /// A coarse picture of the frame at `time` of the current item (32 x 18 blocks of mean brightness), after an exact
    /// seek there with the player paused; nil when no frame comes.
    func frameSignature(at time: Double) async -> [Double]? {
        guard let item, let output else {
            return nil
        }
        _ = await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        for _ in 0..<50 {
            if let buffer = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) {
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                let width = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                let row = CVPixelBufferGetBytesPerRow(buffer)
                guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self), width >= 32, height >= 18 else {
                    return nil
                }
                var blocks = [Double](repeating: 0, count: 32 * 18)
                var counts = [Double](repeating: 0, count: 32 * 18)
                for y in stride(from: 0, to: height, by: 2) {
                    for x in stride(from: 0, to: width, by: 2) {
                        let pixel = base + y * row + x * 4
                        let block = (y * 18 / height) * 32 + x * 32 / width
                        blocks[block] += (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3
                        counts[block] += 1
                    }
                }
                return zip(blocks, counts).map { $1 > 0 ? $0 / $1 : 0 }
            }
            await run(for: 0.1)
        }
        return nil
    }

    static func difference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(max(1, a.count))
    }

    /// A paused live channel whose input the engine closes (AVPlayerViewModel.updatePausedTimeShift and
    /// PausedTimeShiftPolicy), for longer than AVPlayer would keep reloading a live playlist that does not change
    /// (about 40 s, CoreMedia -12888; the engine marks it as ended meanwhile, so it must not), then played on as the app
    /// does (AVPlayerViewModel.play, continueAfterSuspension and resumeAfterSuspension): the input opens again, and once
    /// the engine wrote a segment after the resume a new item continues at the media where the old one was, by their
    /// dates (PausedTimeShiftPolicy.MediaClock). Its frame at the paused media must be the paused one (closer to it than
    /// the frame 2 s later), and it must play on past the media of the pause into what the engine writes now, its clock
    /// the same across the discontinuity. LIVEPAUSE_SECONDS: how long the input stays closed (default 70);
    /// WINDOW_SECONDS makes the window slide (30: it fills during the pause), and the input closes when
    /// PausedTimeShiftPolicy.decide says so (the window full behind the paused position);  The new item
    /// must also show the old item's frame where it continues. LIVEPAUSE_SCAN=1 logs the playlists and where
    /// around the computed position the paused frame is. LIVEPAUSE_KEEP_ITEM=1 plays the old item on instead, as the app did
    /// before: it never gets the media written after the resume (the check fails).
    func livePauseScenario() async {
        guard await open(resumeAt: nil) else {
            return
        }
        await step("live edge") { currentTime }
        await run(for: 6)
        player.pause()
        await run(for: 1)
        frames.stop()
        let pausedPosition = currentTime
        if ProcessInfo.processInfo.environment["LIVEPAUSE_SCAN"] == "1", let clock = PausedTimeShiftPolicy.MediaClock(itemTime: currentTime, date: item?.currentDate()) {
            print(String(format: "[scan] old item paused at %.3f: clock %.3f; seekable from %.3f", currentTime, clock.origin, range()?.0 ?? -1))
        }
        let pausedFrame = await frameSignature(at: pausedPosition)
        let windowAtPause = range()?.0
        if ProcessInfo.processInfo.environment["WINDOW_SECONDS"].flatMap(Double.init) != nil {
            // AVPlayerViewModel.updatePausedTimeShift: the policy closes the input once the full window lets go of media.
            let begin = Date()
            var decided = false
            while !decided && Date().timeIntervalSince(begin) < 40 {
                await run(for: 0.5)
                let decision = PausedTimeShiftPolicy.decide(PausedTimeShiftPolicy.Conditions(
                    pausedFor: Date().timeIntervalSince(begin), position: currentTime, windowStartAtPause: windowAtPause, windowStart: range()?.0))
                if case .suspend(let reason) = decision {
                    print(String(format: "[check] the policy suspends after %.1f s: %@ (window from %.1f, at the pause %.1f)", Date().timeIntervalSince(begin),
                                 reason, range()?.0 ?? -1, windowAtPause ?? -1))
                    decided = true
                }
            }
            if !decided {
                failures.append("live pause: the policy did not suspend a full window")
            }
        }
        remuxer.setInputSuspended(true)
        let suspendBegin = Date()
        while suspendedAfterSegment == nil && Date().timeIntervalSince(suspendBegin) < 10 {
            await run(for: 0.1)
        }
        guard let last = suspendedAfterSegment, let frozenDates, let oldItem = item else {
            failures.append("live pause: the engine did not report the suspension (or its playlist has no dates)")
            close()
            return
        }
        let seconds = Double(ProcessInfo.processInfo.environment["LIVEPAUSE_SECONDS"] ?? "") ?? 70
        let writtenAtSuspension = lastSegmentIndex
        print(String(format: "[check] paused at %.1f (window from %.1f), input suspended after segment %d; paused for %.0f s", pausedPosition,
                     range()?.0 ?? -1, last, seconds))
        await run(for: seconds)
        report("suspended")
        if lastSegmentIndex != writtenAtSuspension {
            failures.append("live pause: segments written while the input was suspended")
        }
        // The engine marks the playlist as ended while suspended: AVPlayer does not reload it, so it does not give up
        // on it (-12888 seven times, then a frozen item on macOS, a failed one on iOS).
        let reloadErrors = oldItem.errorLog()?.events.filter { $0.errorStatusCode == -12888 }.count ?? 0
        let oldItemOK = reloadErrors == 0 && oldItem.status == .readyToPlay
        print("[check] the old item logged \(reloadErrors) unchanged-playlist errors (-12888) during the pause, status \(oldItem.status.rawValue) => \(oldItemOK ? "OK" : "FAIL")")
        if !oldItemOK {
            failures.append("live pause: the old item gave up on the playlist during the pause")
        }
        // AVPlayerViewModel.seekableRange while suspended: the frozen media, by the item's clock (AVPlayer's own range
        // has no length past the media on macOS).
        guard let oldClock = suspendedClock else {
            failures.append("live pause: the old item has no date")
            close()
            return
        }
        let frozenRange = PausedTimeShiftPolicy.itemRange(of: frozenDates, clock: oldClock)
        // (AVPlayer's dates while it plays are a few frames off the playlist's: PausedTimeShiftPolicy.MediaClock.)
        let playingClock = PausedTimeShiftPolicy.MediaClock(itemTime: currentTime, date: oldItem.currentDate())
        let rangeOK = frozenRange.start <= pausedPosition && pausedPosition < frozenRange.end && abs((playingClock?.origin ?? .infinity) - oldClock.origin) < 0.25
        print(String(format: "[check] the frozen media in the old item: %.2f...%.2f, the paused position in it, its dates now %+.3f s off => %@", frozenRange.start,
                     frozenRange.end, (playingClock?.origin ?? .nan) - oldClock.origin, rangeOK ? "OK" : "FAIL"))
        if !rangeOK {
            failures.append("live pause: the old item's frozen media do not hold the paused position")
        }

        // Play on (AVPlayerViewModel.play): no seek to the oldest media while suspended; the input opens again at once.
        if PausedTimeShiftPolicy.continuesFromOldestMedia(position: currentTime, windowStart: frozenRange.start, isSuspended: true) {
            failures.append("live pause: play seeks to the oldest media while suspended")
        }
        remuxer.setInputSuspended(false)
        player.play()
        let resumed = Date()
        if ProcessInfo.processInfo.environment["LIVEPAUSE_KEEP_ITEM"] == "1" {
            await run(for: 25)
            let advanced = currentTime - pausedPosition
            report("old item")
            let ok = player.timeControlStatus == .playing && advanced > 20
            print(String(format: "[check] old item after the suspension advanced=%.1f => %@", advanced, ok ? "OK" : "FAIL"))
            if !ok {
                failures.append("live pause: the old item did not play on")
            }
            close()
            return
        }
        while lastSegmentIndex <= last && Date().timeIntervalSince(resumed) < 20 {
            await run(for: 0.1)
        }
        guard lastSegmentIndex > last else {
            failures.append("live pause: no segment after the resume")
            close()
            return
        }
        // AVPlayerViewModel.continueAfterSuspension (the old item plays the frozen media meanwhile).
        let oldPosition = currentTime
        let resumeDate = PausedTimeShiftPolicy.resumeDate(position: oldPosition, seekTarget: nil, clock: oldClock, frozen: frozenDates)
        let pausedDate = oldClock.date(atItemTime: pausedPosition)
        // The frame where the old item was, which the new item must show where it continues.
        player.pause()
        let resumeFrame = await frameSignature(at: oldPosition)
        print(String(format: "[check] segment %d written %.1f s after the resume; old item at %.1f (%.1f s into the frozen media)", lastSegmentIndex,
                     Date().timeIntervalSince(resumed), oldPosition, resumeDate.timeIntervalSince(frozenDates.lowerBound)))
        guard let configuration = remuxer.configuration else {
            close()
            return
        }
        let fileName = hasMasterPlaylist ? configuration.masterPlaylistFileName : configuration.playlistFileName
        let newItem = AVPlayerItem(url: server.url(forFileNamed: fileName)!)
        newItem.preferredForwardBufferDuration = 8
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        newItem.add(output)
        item = newItem
        self.output = output
        // AVPlayerViewModel.attachRemuxedStream: the new item plays at once.
        player.replaceCurrentItem(with: newItem)
        player.play()
        while newItem.status == .unknown && Date().timeIntervalSince(resumed) < 30 {
            await run(for: 0.01)
        }
        // AVPlayerViewModel.itemClock and resumeAfterSuspension: the new item's clock once it is ready (its date may come
        // a moment later).
        var newClock: PausedTimeShiftPolicy.MediaClock?
        for attempt in 0..<30 {
            if attempt > 0 {
                await run(for: 0.1)
            }
            newClock = PausedTimeShiftPolicy.MediaClock(itemTime: newItem.currentTime().seconds, date: newItem.currentDate())
            if newClock != nil {
                print("[check] the new item has its date after \(attempt) polls")
                break
            }
        }
        // (Paused for the frame comparison.)
        player.pause()
        guard let newClock else {
            failures.append("live pause: the new item has no date")
            close()
            return
        }
        let target = PausedTimeShiftPolicy.resumeItemTime(at: resumeDate, clock: newClock, window: range())
        let pausedInNewItem = newClock.itemTime(at: pausedDate)
        let resumeStart = newClock.itemTime(at: frozenDates.upperBound)
        print(String(format: "[check] new item (window %.1f...%.1f) at %.2f; the paused media at %.2f, the media of the resume at %.2f", range()?.0 ?? -1,
                     range()?.1 ?? -1, target, pausedInNewItem, resumeStart))
        if ProcessInfo.processInfo.environment["LIVEPAUSE_SCAN"] == "1", let pausedFrame {
            // Diagnostics: where around the computed position the paused frame really is.
            print("[scan] playlist now:\n\((try? String(contentsOf: configuration.playlistURL, encoding: .utf8)) ?? "-")")
            print(String(format: "[scan] old clock %.3f (at the event %.3f), new clock %.3f; new item at ready time=%.3f", oldClock.origin,
                         suspendedClock?.origin ?? -1, newClock.origin, newItem.currentTime().seconds))
            for step in -10...10 {
                let time = pausedInNewItem + Double(step) * 0.2
                if let frame = await frameSignature(at: time) {
                    print(String(format: "[scan] %+.1f s: difference %.2f", Double(step) * 0.2, Self.difference(pausedFrame, frame)))
                }
            }
        }
        // Where the new item continues: where the old item was, or the oldest media + 2 s when the window let go of it.
        let newWindow = range()
        let resumeInNewItem = newClock.itemTime(at: resumeDate)
        let expected = newWindow.map { resumeInNewItem < $0.0 ? min($0.0 + 2, $0.1) : min(resumeInNewItem, $0.1) } ?? resumeInNewItem
        if abs(target - expected) > 0.01 {
            failures.append("live pause: the new item does not continue where the old item was")
        }
        let resumeFrameNow = await frameSignature(at: target)
        if resumeInNewItem >= (newWindow?.0 ?? 0), let resumeFrame, let resumeFrameNow, let laterFrame = await frameSignature(at: target + 2) {
            let same = Self.difference(resumeFrame, resumeFrameNow)
            let later = Self.difference(resumeFrame, laterFrame)
            let ok = same < 4 && same * 3 < later
            print(String(format: "[check] the old item's frame where it was in the new item at %.2f: difference %.2f (the frame 2 s later: %.2f) => %@", target, same,
                         later, ok ? "OK" : "FAIL"))
            if !ok {
                failures.append("live pause: the new item does not continue with the media where the old item was")
            }
        } else if resumeInNewItem >= (newWindow?.0 ?? 0) {
            failures.append("live pause: no frame to compare where the new item continues")
        }
        // The paused frame, against the frame 2 s later: the new item must show the paused media.
        if let newWindow, pausedInNewItem < newWindow.0 {
            print(String(format: "[check] the paused media (%.2f) left the new item's window (from %.2f) => FAIL", pausedInNewItem, newWindow.0))
            failures.append("live pause: the window let go of the paused media")
        } else if let pausedFrame, let sameFrame = await frameSignature(at: pausedInNewItem), let laterFrame = await frameSignature(at: pausedInNewItem + 2) {
            let same = Self.difference(pausedFrame, sameFrame)
            let later = Self.difference(pausedFrame, laterFrame)
            let ok = same < 4 && same * 3 < later
            print(String(format: "[check] paused frame in the new item at %.2f: difference %.2f (the frame 2 s later: %.2f) => %@", pausedInNewItem, same, later,
                         ok ? "OK" : "FAIL"))
            if !ok {
                failures.append("live pause: the new item does not show the paused media")
            }
        } else {
            failures.append("live pause: no frame to compare")
        }
        frames.start(output: output) { [weak self] _ in self?.frameBrightness() }
        player.play()
        await step("after the suspension") { target }
        if ProcessInfo.processInfo.environment["LIVEPAUSE_SCAN"] == "1" {
            for _ in 0..<6 {
                if let clock = PausedTimeShiftPolicy.MediaClock(itemTime: currentTime, date: newItem.currentDate()) {
                    print(String(format: "[scan] new item playing at %.2f: clock %+.3f from the one at ready; seekable from %.3f", currentTime, clock.origin - newClock.origin, range()?.0 ?? -1))
                }
                await run(for: 1)
            }
        }
        // Past the media of the pause, into what the engine writes now: the new item follows the playlist.
        let goal = resumeStart + 8
        let begin = Date()
        while currentTime < goal && Date().timeIntervalSince(begin) < max(0, resumeStart - target) + 30 && newItem.status != .failed {
            await run(for: 0.5)
        }
        report("after the resume")
        let ok = currentTime >= goal && player.timeControlStatus == .playing
        print(String(format: "[check] played on to %.1f (past the resume at %.1f) %.1f s after play => %@", currentTime, resumeStart,
                     Date().timeIntervalSince(resumed), ok ? "OK" : "FAIL"))
        if !ok {
            failures.append("live pause: did not play on past the resume")
        }
        // The dates follow the media timeline across the discontinuity: the item's clock is the same after the resume (up
        // to the few frames AVPlayer's dates while it plays are off the playlist's, PausedTimeShiftPolicy.MediaClock).
        if let lateClock = PausedTimeShiftPolicy.MediaClock(itemTime: currentTime, date: newItem.currentDate()) {
            let drift = lateClock.origin - newClock.origin
            let clockOK = abs(drift) < 0.25
            print(String(format: "[check] the new item's clock after the resume differs by %.3f s => %@", drift, clockOK ? "OK" : "FAIL"))
            if !clockOK {
                failures.append("live pause: the item's dates do not follow its time across the resume")
            }
        } else {
            failures.append("live pause: the new item has no date after the resume")
        }
        close()
    }

    /// The format matrix (run_formats.sh): fewer steps, for short movies.
    func quickScenario() async {
        guard await open(resumeAt: nil) else {
            return
        }
        await selectTracks()
        await step("skip +30") { currentTime + 30 }
        await step("scrub 75%") { duration.map { $0 * 0.75 } }
        await step("skip -10") { currentTime - 10 }
        let saved = (duration ?? 0) * 0.4
        await step("scrub 40%") { saved }
        let position = currentTime
        checkCues()
        close()
        await run(for: 1)
        print("[check] reopen at \(Int(position))s")
        route = PlaybackRoute(url: url, kind: kind)
        fellBack = false
        guard await open(resumeAt: position) else {
            return
        }
        await step("skip +10 after resume") { currentTime + 10 }
        close()
    }

    /// Short sample files (run_formats.sh): the middle, then a little back.
    func shortScenario() async {
        guard await open(resumeAt: nil) else {
            return
        }
        await step("scrub 50%") { duration.map { $0 * 0.5 } }
        await step("skip -5") { currentTime - 5 }
        close()
    }

    /// A server slow to seek (run_vod.sh mkv-slow-segment): the segment after a far seek takes about 20 s, longer than
    /// the 15 s FlyingFox gives a request by default, shorter than the engine's wait (`LoopbackTimeouts`). The seek
    /// must play there, from that one request (no 500 from the loopback server, no new item).
    func slowSegmentScenario() async {
        guard await open(resumeAt: nil) else {
            return
        }
        await run(for: 3)
        guard let duration else {
            failures.append("slow segment: no duration")
            return
        }
        let target = duration * 0.5
        let begin = Date()
        _ = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(value: 1, timescale: 4))
        while (player.timeControlStatus != .playing || abs(currentTime - target) > 5) && Date().timeIntervalSince(begin) < 70 && item?.status != .failed {
            await run(for: 0.2)
        }
        let latency = Date().timeIntervalSince(begin)
        let landed = currentTime
        await run(for: 3)
        let advanced = currentTime - landed
        let errors = item?.errorLog()?.events ?? []
        let ok = player.timeControlStatus == .playing && abs(landed - target) < 6 && advanced > 1.5 && item?.status != .failed && errors.isEmpty
        print(String(format: "[check] slow segment target=%.1f landed=%.1f advanced=%.1f latency=%.1fs errors=%d => %@", target, landed, advanced, latency,
                     errors.count, ok ? "OK" : "FAIL"))
        for event in errors {
            print("[check]   error log: \(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "-") \(event.uri ?? "-")")
        }
        if !ok {
            failures.append("slow segment")
        } else if latency < 15 {
            // The case proves nothing unless the segment took longer than FlyingFox's default.
            failures.append(String(format: "slow segment: only %.1f s (the server should delay it about 20 s)", latency))
        }
        close()
    }

    func scenario() async {
        if ProcessInfo.processInfo.environment["SCENARIO"] == "slowsegment" {
            await slowSegmentScenario()
            return
        }
        if ProcessInfo.processInfo.environment["SCENARIO"] == "short" {
            await shortScenario()
            return
        }
        if ProcessInfo.processInfo.environment["SCENARIO"] == "stress" {
            await stressScenario()
            return
        }
        if ProcessInfo.processInfo.environment["SCENARIO"] == "livepause" {
            await livePauseScenario()
            return
        }
        if ProcessInfo.processInfo.environment["SCENARIO"] == "dropped" {
            await droppedScenario()
            return
        }
        if kind == .live {
            await liveScenario()
            return
        }
        if ProcessInfo.processInfo.environment["SCENARIO"] == "quick" {
            await quickScenario()
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
///
/// Main-actor isolated: the legible output calls its delegate on the main queue (`setDelegate(cues, queue: .main)`),
/// where `Check` reads the cues. The delegate protocol is `Sendable`, so its conformance cannot be isolated: the method
/// is `nonisolated` and asserts that it runs on the main actor.
@MainActor
final class CueCollector: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var expectsCues = false
    var cues: [(expected: Double, shown: Double)] = []

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        let texts = strings.map(\.string)
        let seconds = itemTime.seconds
        MainActor.assumeIsolated {
            collect(texts, at: seconds)
        }
    }

    private func collect(_ texts: [String], at itemSeconds: Double) {
        for text in texts {
            guard let range = text.range(of: "Cue at "), let seconds = Double(text[range.upperBound...].prefix { $0.isNumber }) else {
                continue
            }
            // Each cue is reported when it starts (a cue repeated in the next segment is not shown again).
            if !cues.contains(where: { $0.expected == seconds && abs($0.shown - itemSeconds) < 1 }) {
                cues.append((seconds, itemSeconds))
                print(String(format: "[cue] %.0f s shown at %.2f s", seconds, itemSeconds))
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
// A check that hangs (AVFoundation waiting on an item that never loads) fails instead of blocking the run.
let watchdog = Double(ProcessInfo.processInfo.environment["CHECK_TIMEOUT"] ?? "") ?? 300
DispatchQueue.global().asyncAfter(deadline: .now() + watchdog) {
    print("[check] result FAIL route=? failures=[\"timed out after \(Int(watchdog)) s\"]")
    exit(1)
}
Task { @MainActor in
    let check = Check(url: url, kind: kind)
    await check.scenario()
    try? FileManager.default.removeItem(at: check.directory)
    let routeName = switch check.route {
    case .direct: "direct"
    case .remux(let isLive): isLive ? "engine-live" : "engine"
    }
    print("[check] result \(check.failures.isEmpty ? "PASS" : "FAIL") route=\(routeName)\(check.fellBack ? "(fallback)" : "") failures=\(check.failures)")
    exit(check.failures.isEmpty ? 0 : 1)
}
RunLoop.main.run()
