//
//  StreamRemuxer.swift
//  Fluxo
//
//  Swift wrapper around the C remux engine (FluxoRemuxEngine), shared by iOS and macOS.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Engine")

/// Remuxes a stream into an HLS playlist on disk using the shared libavformat engine.
///
/// The class is isolated to the main actor: call its methods and read its state there. Events coming from the
/// engine thread are delivered on the main queue.
///
/// On-demand inputs get a complete VOD playlist at once; its segments are produced when the player asks
/// for them: the loopback server calls `requestFile(named:)` for every segment request, which tells the
/// engine and waits until the segment is on disk (see `fluxo_remux_request_segment`).
@MainActor
final class StreamRemuxer {

    enum State: Equatable {
        case idle
        case opening
        case running
        case reconnecting(attempt: Int)
        case finished
        case cancelled
        case failed(String)

        var isActive: Bool {
            switch self {
            case .opening, .running, .reconnecting:
                return true
            case .idle, .finished, .cancelled, .failed:
                return false
            }
        }
    }

    /// Time-shift window statistics, updated with every completed segment.
    struct WindowStatistics: Equatable {
        var segmentsWritten: Int = 0
        var segmentCount: Int = 0
        var duration: TimeInterval = 0
        var bytes: Int64 = 0
        /// The input has extra audio tracks or text subtitles: the engine wrote a master playlist
        /// (`Configuration.masterPlaylistURL`) with them as renditions, and the player should open it.
        var hasMasterPlaylist = false
        var audioTrackCount = 0
        var subtitleTrackCount = 0
    }

    struct RecordingProgress: Equatable {
        var url: URL
        var duration: TimeInterval
        var bytes: Int64
    }

    enum Event {
        case state(State)
        case segmentWritten(WindowStatistics)
        case recordingStarted(URL)
        case recordingProgress(RecordingProgress)
        /// The recording file is complete.
        case recordingStopped(RecordingProgress)
        /// The recording failed; `url` is set when a (partial) file may exist.
        case recordingFailed(URL?, String)
    }

    enum RemuxError: LocalizedError {
        case invalidConfiguration
        case unableToStart(Int32)
        case notRunning
        /// A multicast address (`udp://@239.…`): iPhone and iPad receive multicast only with Apple's multicast
        /// networking entitlement, which Fluxo does not have, so the stream would wait for data that never comes.
        case multicastUnavailable

        var errorDescription: String? {
            switch self {
            case .multicastUnavailable:
                return String(localized: "Multicast streams (udp://@239…) can't be played on iPhone and iPad. Ask your provider for an http:// address of this channel.", comment: "Player error for a multicast IPTV stream address, which iOS does not let the app receive.")
            case .invalidConfiguration:
                return String(localized: "The stream configuration is invalid.", comment: "Player error from the streaming engine.")
            case .unableToStart(let code):
                return String(localized: "Unable to start the stream engine (\(code)).", comment: "Player error; the number is a technical error code.")
            case .notRunning:
                return String(localized: "The stream is not running.", comment: "Player error from the streaming engine.")
            }
        }
    }

    struct Configuration {
        var inputURL: URL
        var outputDirectory: URL
        /// Unique name of the session, used as prefix for the playlist and the segments.
        var name: String
        /// Live inputs are reconnected when they drop; on-demand inputs get a complete VOD playlist.
        var isLive: Bool = true
        var segmentDuration: Double = 2
        /// On-demand inputs: media produced ahead of the player before the engine pauses reading (it reads in
        /// bursts, so the radio can rest in between).
        var readAheadDuration: TimeInterval = 60
        /// Longest time-shift (DVR) window. 0 keeps every segment.
        var maxWindowDuration: TimeInterval = 30 * 60
        /// Disk budget of the time-shift window. 0 means no limit.
        var maxWindowBytes: Int64 = 512 * 1024 * 1024
        var ioTimeout: TimeInterval = 15
        /// Consecutive reconnection attempts. 0 uses the engine default, negative is unlimited.
        var maxReconnectAttempts: Int = 0
        /// On-demand inputs: where the player starts (a resume), so the engine produces that segment first.
        var startTime: TimeInterval = 0
        /// The first open of the input makes one connection per attempt of the engine (`FluxoRemuxConfig.quick_open`):
        /// an unreachable server fails in about 4 s instead of 20 s.
        var quickOpen = false
        var userAgent: String?

        var filePrefix: String {
            "stream-\(name)"
        }

        var playlistFileName: String {
            "\(filePrefix).m3u8"
        }

        var playlistURL: URL {
            outputDirectory.appendingPathComponent(playlistFileName)
        }

        /// The master playlist, written only when the input has several audio tracks or text subtitles.
        var masterPlaylistFileName: String {
            "\(filePrefix)-master.m3u8"
        }

        var masterPlaylistURL: URL {
            outputDirectory.appendingPathComponent(masterPlaylistFileName)
        }

        var segmentPathPrefix: String {
            outputDirectory.appendingPathComponent(filePrefix).path
        }

        /// The segment a file of this session holds: `<prefix>-000042.ts` (or `.m4s`) of the main playlist,
        /// `<prefix>-init.mp4` (index -1, the initialization segment of fMP4 playlists), or `<prefix>-a1-000042.ts`
        /// (`.m4s`, with `<prefix>-a1-init.mp4`, next to fMP4 video) and `<prefix>-s0-000042.vtt` of the audio and
        /// subtitle renditions. nil for any other file (the playlists, other sessions).
        func segmentFile(named fileName: String) -> SegmentFile? {
            if fileName == "\(filePrefix)-init.mp4" {
                return SegmentFile(rendition: nil, index: -1)
            }
            guard fileName.hasPrefix("\(filePrefix)-") else {
                return nil
            }
            var rest = fileName.dropFirst(filePrefix.count + 1)
            guard let dot = rest.lastIndex(of: ".") else {
                return nil
            }
            let fileExtension = rest[rest.index(after: dot)...]
            rest = rest[..<dot]
            var rendition: String?
            if let first = rest.first, first == "a" || first == "s", let dash = rest.firstIndex(of: "-") {
                let number = rest[rest.index(after: rest.startIndex)..<dash]
                guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                    return nil
                }
                rendition = String(rest[..<dash])
                rest = rest[rest.index(after: dash)...]
                if first == "a" && rest == "init" && fileExtension == "mp4" {
                    return SegmentFile(rendition: rendition, index: -1)
                }
                guard first == "a" ? fileExtension == "ts" || fileExtension == "m4s" : fileExtension == "vtt" else {
                    return nil
                }
            } else if fileExtension != "ts" && fileExtension != "m4s" {
                return nil
            }
            guard !rest.isEmpty, rest.allSatisfy({ $0.isASCII && $0.isNumber }), let index = Int(rest) else {
                return nil
            }
            return SegmentFile(rendition: rendition, index: index)
        }
    }

    /// A segment file the player asks for: the main playlist's (rendition nil) or a rendition's ("a1", "s0").
    struct SegmentFile: Hashable {
        var rendition: String?
        var index: Int
    }

    /// Longest wait for a requested segment: a slow server, or a seek far into a file that cannot seek.
    static let segmentRequestTimeout: Duration = .seconds(45)

    /// Called on the main queue for every engine event.
    var onEvent: ((Event) -> Void)?

    private(set) var state: State = .idle

    private(set) var statistics = WindowStatistics()

    /// URL of the recording being written, if any.
    private(set) var recordingURL: URL?

    var isProcessing: Bool {
        state.isActive
    }

    private(set) var configuration: Configuration?

    private var session: OpaquePointer?
    private var callbackBox: Unmanaged<CallbackBox>?
    /// Requests of the player waiting for a segment (index -1 is the initialization segment).
    private var segmentWaiters: [SegmentFile: [UUID: CheckedContinuation<Bool, Never>]] = [:]

    private static let teardownQueue = DispatchQueue(label: "dev.watermelon.Fluxo.StreamRemuxer.teardown", qos: .utility)

    isolated deinit {
        stop()
    }

    /// Starts remuxing `configuration.inputURL`, stopping any running session first.
    func start(_ configuration: Configuration) throws {
        stop()

        #if os(iOS)
        guard !Self.isMulticast(configuration.inputURL) else {
            throw RemuxError.multicastUnavailable
        }
        #endif

        try FileManager.default.createDirectory(at: configuration.outputDirectory, withIntermediateDirectories: true)

        let box = CallbackBox(owner: self)
        let unmanagedBox = Unmanaged.passRetained(box)

        let newSession = Self.makeSession(configuration, context: unmanagedBox.toOpaque())
        guard let newSession else {
            unmanagedBox.release()
            throw RemuxError.invalidConfiguration
        }

        let result = fluxo_remux_start(newSession)
        guard result == 0 else {
            fluxo_remux_destroy(newSession)
            unmanagedBox.release()
            throw RemuxError.unableToStart(result)
        }

        self.session = newSession
        self.callbackBox = unmanagedBox
        self.configuration = configuration
        self.statistics = WindowStatistics()
        update(.opening)
    }

    /// Stops the running session (if any) without blocking the caller, then removes its files.
    ///
    /// - Parameter recordingCompletion: called on the main queue once an active recording file is
    ///   complete on disk. A recording is always finalized, even when the session is stopped.
    func stop(recordingCompletion: (@MainActor (URL) -> Void)? = nil) {
        guard let session else {
            return
        }

        let box = callbackBox
        let configuration = configuration
        let recordingURL = recordingURL
        self.session = nil
        self.callbackBox = nil
        self.configuration = nil
        self.recordingURL = nil

        // Ignore any late callback of the stopped session.
        box?.takeUnretainedValue().owner = nil
        fluxo_remux_cancel(session)
        resolveAllSegmentWaiters()
        if isProcessing {
            update(.cancelled)
        }

        // Joining the engine thread may wait for a blocking read to be interrupted: never on main.
        let teardown = Teardown(session: session, box: box)
        Self.teardownQueue.async {
            fluxo_remux_destroy(teardown.session)
            teardown.box?.release()
            if let configuration {
                Self.removeFiles(of: configuration)
            }
            if let recordingURL, let recordingCompletion {
                DispatchQueue.main.async {
                    recordingCompletion(recordingURL)
                }
            }
        }
    }

    /// Called by the loopback server for every file the player requests. Segment files of an on-demand
    /// session are produced on request: this tells the engine (which seeks the input when the segment is far
    /// from what it reads) and waits until the file is on disk. Returns false when the file will not come
    /// (no such segment, the session ended or failed, or it took longer than `segmentRequestTimeout`);
    /// the server then answers 404, and AVPlayer reports the failure.
    @MainActor
    func requestFile(named fileName: String) async -> Bool {
        guard let session, let configuration, !configuration.isLive,
              let file = configuration.segmentFile(named: fileName) else {
            // Live sessions and playlists: the file is on disk or it is not.
            return true
        }
        // Only the main playlist moves the reader; a rendition's segment is written with the main one.
        let result = fluxo_remux_request_segment(session, Int64(file.index), file.rendition == nil ? 0 : 1)
        if result != 0 {
            return result > 0
        }
        guard isProcessing else {
            return false
        }
        // A request far from the others of the same playlist supersedes them (the player seeked): the engine no
        // longer produces those, so they fail now instead of at the timeout (and free the player's connections).
        let index = file.index
        for (waiting, _) in segmentWaiters where index >= 0 && waiting.index >= 0 && waiting.rendition == file.rendition
            && (waiting.index < index || waiting.index > index + 8) {
            resolveSegmentWaiters(for: waiting, with: false)
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            segmentWaiters[file, default: [:]][id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.segmentRequestTimeout)
                guard let self, let waiter = self.segmentWaiters[file]?.removeValue(forKey: id) else {
                    return
                }
                logger.error("Segment \(index) (\(file.rendition ?? "main", privacy: .public)) not produced in time")
                waiter.resume(returning: false)
            }
        }
    }

    /// The player is about to seek an on-demand session to `seconds` (item time): the segment it asks for next
    /// is produced as a seek target, starting with a key frame (see `fluxo_remux_note_seek`). Without it, a seek
    /// just past what the player buffered asks for the next segment as if it played on, and a segment the engine
    /// wrote ahead inside a GOP plays from its next key frame, seconds after the target.
    func noteSeek(to seconds: TimeInterval) {
        guard let session, let configuration, !configuration.isLive, seconds.isFinite else {
            return
        }
        fluxo_remux_note_seek(session, seconds)
    }

    /// A new player item of the running on-demand session starts at `seconds` (its playlist says so), not where
    /// the first item started: otherwise the engine produces media there first, only for the player to seek away.
    @discardableResult
    func setPlaylistStart(_ seconds: TimeInterval) -> Bool {
        guard let session, let configuration, !configuration.isLive, seconds.isFinite else {
            return false
        }
        return fluxo_remux_set_start_time(session, max(0, seconds)) == 0
    }

    private func resolveSegmentWaiters(for file: SegmentFile, with available: Bool) {
        guard let waiters = segmentWaiters.removeValue(forKey: file) else {
            return
        }
        for waiter in waiters.values {
            waiter.resume(returning: available)
        }
    }

    /// Resolves the requests for segment `index` of every playlist (the engine writes them together).
    private func resolveSegmentWaiters(forIndex index: Int, with available: Bool) {
        for file in segmentWaiters.keys where file.index == index {
            resolveSegmentWaiters(for: file, with: available)
        }
    }

    private func resolveAllSegmentWaiters() {
        let waiters = segmentWaiters
        segmentWaiters.removeAll()
        for waiter in waiters.values.flatMap(\.values) {
            waiter.resume(returning: false)
        }
    }

    /// Starts recording the stream to `url` (an MPEG-TS file) from the next key frame.
    func startRecording(to url: URL) throws {
        guard let session, isProcessing else {
            throw RemuxError.notRunning
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = url.path.withCString { fluxo_remux_start_recording(session, $0) }
        guard result == 0 else {
            throw RemuxError.unableToStart(result)
        }
        recordingURL = url
    }

    /// Closes the active (or still queued) recording. `.recordingStopped` is delivered when the file is
    /// complete, also for a request the engine never opened, so every started recording gets a terminal event.
    func stopRecording() {
        guard let session, recordingURL != nil else {
            return
        }
        fluxo_remux_stop_recording(session)
    }

    private func update(_ newState: State) {
        guard newState != state else {
            return
        }
        state = newState
        onEvent?(.state(newState))
    }

    private func handle(_ event: EngineEvent, from box: CallbackBox) {
        guard callbackBox?.takeUnretainedValue() === box else {
            return
        }
        if event.statistics != statistics {
            statistics = event.statistics
        }
        let progress = event.recordingPath.map {
            RecordingProgress(url: URL(fileURLWithPath: $0), duration: event.recordingDuration, bytes: event.recordingBytes)
        }

        switch event.kind {
        case .stateChanged:
            if !event.state.isActive {
                // Nothing more will be produced.
                resolveAllSegmentWaiters()
            }
            if !event.state.isActive, let recordingURL {
                // The engine thread has ended and reports every recording before its final state, so
                // this request was never opened (e.g. it was queued after the engine's last check).
                self.recordingURL = nil
                onEvent?(.recordingStopped(RecordingProgress(url: recordingURL, duration: 0, bytes: 0)))
            }
            update(event.state)
        case .segmentWritten:
            // The initialization segment of an fMP4 playlist is written with the first segment.
            resolveSegmentWaiters(forIndex: event.segmentIndex, with: true)
            resolveSegmentWaiters(forIndex: -1, with: true)
            onEvent?(.segmentWritten(event.statistics))
            if let progress, recordingURL != nil {
                onEvent?(.recordingProgress(progress))
            }
        case .recordingStarted:
            if let progress {
                onEvent?(.recordingStarted(progress.url))
            }
        case .recordingStopped:
            if let progress {
                if recordingURL == progress.url {
                    recordingURL = nil
                }
                onEvent?(.recordingStopped(progress))
            }
        case .recordingFailed:
            if recordingURL == progress?.url {
                recordingURL = nil
            }
            onEvent?(.recordingFailed(progress?.url, event.message ?? String(localized: "Recording failed", comment: "Recording error shown when the engine gives no reason.")))
        }
    }

    /// Whether `url` is a UDP or RTP multicast address: IPv4 224.0.0.0/4 (`udp://@239.1.1.1:1234`) or IPv6 ff00::/8.
    nonisolated static func isMulticast(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "udp" || scheme == "rtp",
              let host = url.host(percentEncoded: false)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else {
            return false
        }
        if host.hasPrefix("ff") && host.contains(":") {
            return true
        }
        let octets = host.split(separator: ".")
        guard octets.count == 4, let first = Int(octets[0]) else {
            return false
        }
        return (224...239).contains(first)
    }

    private static func makeSession(_ configuration: Configuration, context: UnsafeMutableRawPointer) -> OpaquePointer? {
        let input = configuration.inputURL.isFileURL ? configuration.inputURL.path : configuration.inputURL.absoluteString
        let playlist = configuration.playlistURL.path
        let master = configuration.masterPlaylistURL.path
        let prefix = configuration.segmentPathPrefix
        let userAgent = configuration.userAgent ?? ""

        return input.withCString { inputPointer in
            playlist.withCString { playlistPointer in
                prefix.withCString { prefixPointer in
                    master.withCString { masterPointer in
                        userAgent.withCString { userAgentPointer in
                            var config = FluxoRemuxConfig()
                            config.input_url = inputPointer
                            config.user_agent = userAgentPointer
                            config.io_timeout_us = Int64(configuration.ioTimeout * 1_000_000)
                            config.is_live = configuration.isLive ? 1 : 0
                            config.max_reconnect_attempts = Int32(clamping: configuration.maxReconnectAttempts)
                            config.read_ahead_duration = configuration.readAheadDuration
                            config.start_time = configuration.startTime
                            config.quick_open = configuration.quickOpen ? 1 : 0
                            config.hls.playlist_path = playlistPointer
                            config.hls.segment_path_prefix = prefixPointer
                            config.hls.segment_duration = configuration.segmentDuration
                            config.hls.max_window_duration = configuration.maxWindowDuration
                            config.hls.max_window_bytes = configuration.maxWindowBytes
                            config.hls.min_window_segments = 3
                            // Extra audio tracks and text subtitles become renditions of a master playlist.
                            config.hls.master_playlist_path = masterPointer
                            return fluxo_remux_create(&config, StreamRemuxer.engineCallback, context)
                        }
                    }
                }
            }
        }
    }

    private nonisolated static func removeFiles(of configuration: Configuration) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: configuration.outputDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(configuration.filePrefix) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Removes the files of every session (e.g. left over by a crash). Call before the first session.
    nonisolated static func removeAllFiles(in directory: URL) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("stream-") {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Called on the engine thread (see `FluxoRemuxEventCallback`).
    private nonisolated static let engineCallback: FluxoRemuxEventCallback = { context, eventPointer in
        guard let context, let eventPointer else {
            return
        }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        // Copy everything now: the C pointers are only valid during the call.
        let event = EngineEvent(eventPointer.pointee)
        DispatchQueue.main.async {
            box.owner?.handle(event, from: box)
        }
    }
}

/// Swift copy of a FluxoRemuxEvent.
private struct EngineEvent {
    let kind: FluxoRemuxEventKind
    let state: StreamRemuxer.State
    let message: String?
    let statistics: StreamRemuxer.WindowStatistics
    let recordingPath: String?
    let recordingDuration: TimeInterval
    let recordingBytes: Int64
    let segmentIndex: Int

    init(_ event: FluxoRemuxEvent) {
        kind = event.kind
        segmentIndex = Int(event.segment_index)
        message = event.message.map { EngineMessage.localized(String(cString: $0)) }
        switch event.state {
        case .idle:
            state = .idle
        case .opening:
            state = .opening
        case .running:
            state = .running
        case .reconnecting:
            state = .reconnecting(attempt: Int(event.reconnect_attempt))
        case .finished:
            state = .finished
        case .cancelled:
            state = .cancelled
        case .failed:
            state = .failed(message ?? String(localized: "Unknown error", comment: "Player error shown when the streaming engine gives no reason."))
        }
        statistics = StreamRemuxer.WindowStatistics(
            segmentsWritten: Int(event.segments_written),
            segmentCount: Int(event.window_segment_count),
            duration: event.window_duration,
            bytes: event.window_bytes,
            hasMasterPlaylist: event.master_playlist_written != 0,
            audioTrackCount: Int(event.audio_rendition_count),
            subtitleTrackCount: Int(event.subtitle_rendition_count)
        )
        recordingPath = event.recording_path.map { String(cString: $0) }
        recordingDuration = event.recording_duration
        recordingBytes = event.recording_bytes
    }
}

/// Translates the messages of the C engine (FluxoRemuxEngine.c), which are English: "<what failed>: <FFmpeg reason>",
/// or the unsupported-protocol message. The part that says what failed is localized; FFmpeg's technical reason
/// ("Connection refused", "Server returned 404 Not Found") is kept as it is.
enum EngineMessage {
    static func localized(_ message: String) -> String {
        if message.hasPrefix("Unsupported stream type") {
            if let start = message.range(of: ": ")?.upperBound, let end = message.range(of: "://")?.lowerBound, start < end {
                let scheme = String(message[start..<end])
                return String(localized: "Unsupported stream type: \(scheme):// streams cannot be played", comment: "Player error; the placeholder is a URL scheme such as srt.")
            }
            return String(localized: "Unsupported stream type", comment: "Player error: the stream uses a protocol the app cannot open.")
        }
        if let sentence = formatSentence(message) {
            return sentence
        }
        let parts = message.split(separator: ": ", maxSplits: 1).map(String.init)
        guard let stage = parts.first, let localizedStage = stages[stage] else {
            return message
        }
        guard parts.count == 2 else {
            return localizedStage
        }
        return String(localized: "\(localizedStage): \(parts[1])", comment: "Player or recording error: what failed, then the technical reason (in English).")
    }

    /// The whole sentence for an engine message that says the video (or, without video, the audio) is in a format
    /// the engine can neither copy nor convert ("Unsupported video format: AV1"); nil for any other message.
    /// The codec name comes from FFmpeg ("Windows Media Video 9 Screen", "AV1"), in English.
    static func formatSentence(_ message: String) -> String? {
        for (prefix, isVideo) in [("Unsupported video format", true), ("Unsupported audio format", false)] where message.hasPrefix(prefix) {
            let codec = message.dropFirst(prefix.count).drop { $0 == ":" || $0 == " " }
            if codec.isEmpty || codec == "unknown" {
                return isVideo
                    ? String(localized: "This video can't be played: its video format isn't supported.", comment: "Player error: the video is in a format (codec) the app cannot decode or convert.")
                    : String(localized: "This can't be played: its audio format isn't supported.", comment: "Player error: an audio-only stream is in a format (codec) the app cannot decode or convert.")
            }
            let name = String(codec)
            return isVideo
                ? String(localized: "This video can't be played: its video format (\(name)) isn't supported.", comment: "Player error: the video is in a format the app cannot decode or convert; the placeholder is the technical name of the video codec, in English (for example AV1).")
                : String(localized: "This can't be played: its audio format (\(name)) isn't supported.", comment: "Player error: an audio-only stream is in a format the app cannot decode or convert; the placeholder is the technical name of the audio codec, in English.")
        }
        return nil
    }

    /// The `what` / `stage` strings of FluxoRemuxEngine.c.
    private static var stages: [String: String] {
        [
            "Unable to open the stream": String(localized: "Unable to open the stream", comment: "Player error."),
            "Unable to create the HLS output": String(localized: "Unable to prepare the stream for playback", comment: "Player error: the app could not write the local copy of the stream."),
            "Stream interrupted": String(localized: "Stream interrupted", comment: "Player error."),
            "Connection lost": String(localized: "Connection lost", comment: "Player error: the live stream could not be reconnected."),
            "Unable to write the stream": String(localized: "Unable to write the stream", comment: "Player error: the app could not write the local copy of the stream (for example, the disk is full)."),
            "Recording failed": String(localized: "Recording failed", comment: "Recording error."),
            "Unable to start the recording": String(localized: "Unable to start the recording", comment: "Recording error."),
            "Recording stopped": String(localized: "Recording stopped", comment: "Recording error: the recording stopped because of a problem."),
            "Unable to open the recording": String(localized: "Unable to open the recording", comment: "Error while saving a recording."),
            "Unable to create the output file": String(localized: "Unable to create the output file", comment: "Error while saving a recording."),
            "Unable to convert the recording": String(localized: "Unable to convert the recording", comment: "Error while saving a recording."),
            "Video encoder unavailable": String(localized: "The video can't be converted while the app is in the background. Try again with the app open.", comment: "Error while saving a recording or a download whose video must be converted: the system does not allow it while the app is in the background."),
        ]
    }
}

/// A stopped session on its way to `teardownQueue`, which destroys it. The engine's functions may be called from any
/// thread except its own callback (`fluxo_remux_destroy`, FluxoRemuxEngine.h), and once `stop()` has handed the session
/// over, the queue is its only user: the raw pointers cross threads exactly once, so the unchecked conformance is safe.
private struct Teardown: @unchecked Sendable {
    let session: OpaquePointer
    let box: Unmanaged<CallbackBox>?
}

/// Bridges engine callbacks back to the owning remuxer. Retained for the whole life of a C session. The engine
/// thread only passes the box to the main queue; `owner` is read and written on the main actor.
@MainActor
private final class CallbackBox {
    weak var owner: StreamRemuxer?

    init(owner: StreamRemuxer) {
        self.owner = owner
    }
}
