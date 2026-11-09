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
        /// The media sequence number of the segment just written (its index in an on-demand playlist).
        var segmentIndex = 0
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
        /// The live input closed for `setInputSuspended(true)`: the playlist stops changing until it opens again (the
        /// segments after the one numbered `lastSegmentIndex` follow a discontinuity). AVPlayer stops reloading a live
        /// playlist that does not change for long and never asks for it again, so playing on needs a new item.
        case inputSuspended(lastSegmentIndex: Int)
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
        /// a dead channel fails in about half a second, a server that refuses the account in about 4 s, instead of
        /// "Connecting…" for 20 s.
        var quickOpen = true
        var userAgent: String?
        /// How the engine reads http:// and https:// inputs (`FluxoRemuxConfig.http_input`).
        var httpInput: HTTPInput = .system

        /// How the engine reads http:// and https:// inputs.
        enum HTTPInput: Equatable {
            /// The system's URL loading system: TLS 1.3, HTTP/2, the system's proxy settings and trust store. A server it
            /// cannot talk to is opened with FFmpeg's http protocol instead (the engine decides that by itself).
            case system
            /// FFmpeg's own http protocol, as before (TLS 1.2 at most, no system proxy): for servers that only work with it
            /// (`PlayerPreferences.legacyNetworking`).
            case ffmpeg
        }

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

    /// Longest wait for a requested segment: a slow server, or a seek far into a file that cannot seek. The loopback
    /// server allows each request longer than this (`LoopbackTimeouts.request`).
    static let segmentRequestTimeout: Duration = LoopbackTimeouts.segmentWait

    /// Called on the main queue for every engine event.
    var onEvent: ((Event) -> Void)?

    private(set) var state: State = .idle

    private(set) var statistics = WindowStatistics()

    /// URL of the recording being written, if any.
    private(set) var recordingURL: URL?

    /// The input of the live session is closed while the player is paused (see `setInputSuspended(_:)`).
    private(set) var isInputSuspended = false

    /// FFmpeg's error code of the failure of the session (state `.failed`), 0 otherwise; see `EngineMessage.error(code:)`.
    private(set) var failureCode: Int32 = 0
    /// The failure of the session as an error (`EngineMessage.error(code:message:)`), nil without a code.
    private(set) var failureError: NSError?

    var isProcessing: Bool {
        state.isActive
    }

    private(set) var configuration: Configuration?

    private var session: OpaquePointer?
    private var callbackBox: Unmanaged<CallbackBox>?
    /// A request of the player waiting for a segment, and the task that ends it at `segmentRequestTimeout`.
    private struct SegmentWaiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>

        func resume(returning available: Bool) {
            timeout.cancel()
            continuation.resume(returning: available)
        }
    }

    /// Requests of the player waiting for a segment (index -1 is the initialization segment).
    private var segmentWaiters: [SegmentFile: [UUID: SegmentWaiter]] = [:]

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
        self.failureCode = 0
        self.failureError = nil
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
        self.isInputSuspended = false

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
    /// (no such segment, the session ended or failed, or it took longer than `segmentRequestTimeout`), or when the
    /// request is cancelled (the server stopped, or ended it at its own limit); the server then answers 404, and
    /// AVPlayer reports the failure.
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
        guard isProcessing, !Task.isCancelled else {
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
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.segmentRequestTimeout)
                    guard !Task.isCancelled, let self, self.removeSegmentWaiter(id, of: file) != nil else {
                        return
                    }
                    logger.error("Segment \(index) (\(file.rendition ?? "main", privacy: .public)) not produced in time")
                    continuation.resume(returning: false)
                }
                segmentWaiters[file, default: [:]][id] = SegmentWaiter(continuation: continuation, timeout: timeout)
                // Cancelled before the waiter existed: the handler below found nothing to resolve.
                if Task.isCancelled {
                    removeSegmentWaiter(id, of: file)?.resume(returning: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.removeSegmentWaiter(id, of: file)?.resume(returning: false)
            }
        }
    }

    @discardableResult
    private func removeSegmentWaiter(_ id: UUID, of file: SegmentFile) -> SegmentWaiter? {
        guard let waiter = segmentWaiters[file]?.removeValue(forKey: id) else {
            return nil
        }
        if segmentWaiters[file]?.isEmpty == true {
            segmentWaiters.removeValue(forKey: file)
        }
        return waiter
    }

    /// Live sessions: closes the input (true) while the player is paused, keeping the time-shift window and the
    /// playlist, or opens it again (false), the playlist continuing after a discontinuity (see
    /// `fluxo_remux_set_input_suspended` and `PausedTimeShiftPolicy`). The engine keeps the input open while it records.
    func setInputSuspended(_ suspended: Bool) {
        guard let session, let configuration, configuration.isLive, suspended != isInputSuspended else {
            return
        }
        isInputSuspended = suspended
        fluxo_remux_set_input_suspended(session, suspended ? 1 : 0)
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
        // A recording needs the input.
        setInputSuspended(false)
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

        if let raw = event.rawMessage, event.isFailure {
            // The engine's own words (the message shown is translated).
            logger.error("Engine: \(raw, privacy: .public) (\(event.errorCode))")
        }
        switch event.kind {
        case .stateChanged:
            if case .failed = event.state {
                failureCode = event.errorCode
                failureError = event.errorCode != 0 ? EngineMessage.error(code: event.errorCode, message: event.rawMessage) : nil
            }
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
        case .inputSuspended:
            onEvent?(.inputSuspended(lastSegmentIndex: event.segmentIndex))
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
                            config.http_input = configuration.httpInput == .ffmpeg ? .libavformat : .system
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
    /// The engine's English message (for the log), and its error code (FFmpeg's, 0 without one).
    let rawMessage: String?
    let errorCode: Int32
    let statistics: StreamRemuxer.WindowStatistics
    let recordingPath: String?
    let recordingDuration: TimeInterval
    let recordingBytes: Int64
    let segmentIndex: Int

    /// A failure of the session or of a recording.
    var isFailure: Bool {
        if case .failed = state, kind == .stateChanged {
            return true
        }
        return kind == .recordingFailed
    }

    init(_ event: FluxoRemuxEvent) {
        kind = event.kind
        segmentIndex = Int(event.segment_index)
        let raw = event.message.map { String(cString: $0) }
        let code = event.error_code
        rawMessage = raw
        errorCode = code
        message = raw.map { EngineMessage.localized($0, code: code) }
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
            subtitleTrackCount: Int(event.subtitle_rendition_count),
            segmentIndex: Int(event.segment_index)
        )
        recordingPath = event.recording_path.map { String(cString: $0) }
        recordingDuration = event.recording_duration
        recordingBytes = event.recording_bytes
    }
}

/// Translates the messages of the C engine (FluxoRemuxEngine.c and the FluxoEngine*.c files), which are English:
/// "<what failed>: <FFmpeg reason>", or the unsupported-protocol message. The part that says what failed is localized,
/// and so are the reasons the network and servers commonly cause (`Reason`, from the engine's error code, or from
/// FFmpeg's text when there is no code); any other reason of FFmpeg is kept as it is, in English. The raw message goes
/// to the log.
enum EngineMessage {
    /// The domain of the errors made from the engine's codes (`error(code:)`): FFmpeg's error codes (AVERROR).
    static let errorDomain = "dev.watermelon.Fluxo.Engine"

    /// The key of the `userInfo` of `error(code:message:)` with the stage of the engine's message (what failed, in
    /// English: "Unable to open the stream").
    static let stageKey = "FluxoEngineStage"

    /// An error with the engine's code, so that a screen can tell what happened by its code (`reason(of:)`).
    /// `message`: the engine's (English) message, whose stage tells what a code of no particular meaning means.
    static func error(code: Int32, message: String? = nil) -> NSError {
        NSError(domain: errorDomain, code: Int(code), userInfo: message.flatMap(stage(of:)).map { [stageKey: $0] } ?? [:])
    }

    /// The common reason of an error of `error(code:message:)`; nil for others.
    static func reason(of error: NSError) -> Reason? {
        guard error.domain == errorDomain else {
            return nil
        }
        return reason(code: Int32(truncatingIfNeeded: error.code), stage: error.userInfo[stageKey] as? String)
    }

    /// What failed in an engine message ("<what failed>: <reason>"), nil without it.
    private static func stage(of message: String) -> String? {
        message.range(of: ": ").map { String(message[..<$0.lowerBound]) }
    }

    /// The stage of the engine's messages that opens the input.
    private static let openStage = "Unable to open the stream"

    /// The common reasons of a failure, from FFmpeg's error codes.
    enum Reason: Equatable {
        case connectionRefused
        case timedOut
        case connectionReset
        case networkUnreachable
        case badRequest
        case unauthorized
        case forbidden
        case notFound
        case tooManyRequests
        case otherClientError
        case serverError
        case invalidData
        case endOfStream
        case noSpace
        /// An input/output error (EIO) while opening the input: FFmpeg's failed name lookup has no code of its own
        /// (tcp.c, "Failed to resolve hostname"), nor do some other failures to reach the server.
        case serverNotFound
        /// The server's TLS certificate is not trusted (`FLUXO_REMUX_ERROR_TLS_CERTIFICATE`).
        case untrustedCertificate
        /// No secure connection could be made with the server (`FLUXO_REMUX_ERROR_TLS_HANDSHAKE`).
        case secureConnectionFailed

        var localizedDescription: String {
            switch self {
            case .connectionRefused:
                String(localized: "The server refused the connection", comment: "Player or recording error, the technical reason after 'Unable to open the stream:' and similar: the server did not accept the connection (it is down, or the address or port is wrong).")
            case .timedOut:
                String(localized: "The server didn't respond in time", comment: "Player or recording error, the technical reason after 'Unable to open the stream:' and similar: the connection timed out.")
            case .connectionReset:
                String(localized: "The server closed the connection", comment: "Player or recording error, the technical reason after 'Stream interrupted:' and similar: the connection was reset by the server.")
            case .networkUnreachable:
                String(localized: "The server can't be reached from this network", comment: "Player or recording error, the technical reason after 'Unable to open the stream:' and similar: no route to the server (the network is down or blocks it).")
            case .badRequest:
                String(localized: "The server didn't understand the request (400)", comment: "Player or recording error, the technical reason after 'Unable to open the stream:': the server answered HTTP 400. Keep the number.")
            case .unauthorized:
                String(localized: "The server didn't accept the account (401)", comment: "Player or recording error, the technical reason after 'Unable to open the stream:': the server answered HTTP 401 (wrong user name or password). Keep the number.")
            case .forbidden:
                String(localized: "The server refused access (403)", comment: "Player or recording error, the technical reason after 'Unable to open the stream:': the server answered HTTP 403 (an expired subscription, or the account's connections are in use). Keep the number.")
            case .notFound:
                String(localized: "The server doesn't have this stream (404)", comment: "Player or recording error, the technical reason after 'Unable to open the stream:': the server answered HTTP 404. Keep the number.")
            case .tooManyRequests:
                String(localized: "The server is limiting connections (429)", comment: "Player or recording error, the technical reason after 'Unable to open the stream:': the server answered HTTP 429 (too many requests). Keep the number.")
            case .otherClientError:
                String(localized: "The server refused the request", comment: "Player or recording error, the technical reason after 'Unable to open the stream:': the server answered with another HTTP 4xx error.")
            case .serverError:
                String(localized: "The server has a problem (5xx)", comment: "Player or recording error, the technical reason after 'Unable to open the stream:': the server answered with an HTTP 5xx error. Keep '5xx'.")
            case .invalidData:
                String(localized: "The stream's data is damaged or isn't video", comment: "Player or recording error, the technical reason after 'Unable to open the stream:' and similar: FFmpeg found invalid data (a web page instead of a stream, or a damaged file).")
            case .endOfStream:
                String(localized: "The stream ended unexpectedly", comment: "Player or recording error, the technical reason after 'Stream interrupted:' and similar: the input ended (end of file).")
            case .noSpace:
                String(localized: "There isn't enough storage space", comment: "Player or recording error, the technical reason after 'Unable to write the stream:' and similar: the device's storage is full.")
            case .serverNotFound:
                String(localized: "The server couldn't be found or reached", comment: "Player error, the technical reason after 'Unable to open the stream:': the server's name did not resolve, or it could not be reached (an input/output error while connecting).")
            case .untrustedCertificate:
                String(localized: "The server's security certificate isn't valid", comment: "Player or recording error, the technical reason after 'Unable to open the stream:' and similar: the HTTPS server's certificate is expired, for another server, or not from an authority the device trusts.")
            case .secureConnectionFailed:
                String(localized: "A secure connection to the server couldn't be made", comment: "Player or recording error, the technical reason after 'Unable to open the stream:' and similar: the TLS (HTTPS) handshake with the server failed.")
            }
        }
    }

    /// FFmpeg's error code of a message whose stage (what failed) is `stage` as a common reason; nil for others. An
    /// input/output error (EIO) means that the server could not be found or reached only while the input opens.
    static func reason(code: Int32, stage: String?) -> Reason? {
        if code == -EIO, stage == openStage {
            return .serverNotFound
        }
        return reason(code: code)
    }

    /// FFmpeg's error code (AVERROR: a negative POSIX error, or a tag of FFmpeg's) as a common reason; nil for others.
    static func reason(code: Int32) -> Reason? {
        switch code {
        case -ECONNREFUSED:
            return .connectionRefused
        case -ETIMEDOUT:
            return .timedOut
        case -ECONNRESET, -EPIPE:
            return .connectionReset
        case -ENETUNREACH, -EHOSTUNREACH, -ENETDOWN, -EHOSTDOWN:
            return .networkUnreachable
        case -ENOSPC:
            return .noSpace
        case errorTag(0xF8, "4", "0", "0"):
            return .badRequest
        case errorTag(0xF8, "4", "0", "1"):
            return .unauthorized
        case errorTag(0xF8, "4", "0", "3"):
            return .forbidden
        case errorTag(0xF8, "4", "0", "4"):
            return .notFound
        case errorTag(0xF8, "4", "2", "9"):
            return .tooManyRequests
        case errorTag(0xF8, "4", "X", "X"):
            return .otherClientError
        case errorTag(0xF8, "5", "X", "X"):
            return .serverError
        case errorTag("I", "N", "D", "A"):
            return .invalidData
        case errorTag("E", "O", "F", " "):
            return .endOfStream
        case Int32(FLUXO_REMUX_ERROR_TLS_CERTIFICATE):
            return .untrustedCertificate
        case Int32(FLUXO_REMUX_ERROR_TLS_HANDSHAKE):
            return .secureConnectionFailed
        default:
            return nil
        }
    }

    /// The reason of FFmpeg's text for it (`av_strerror`, in English): the messages of `fluxo_remux_convert_file`
    /// have no code.
    static func reason(text: String) -> Reason? {
        switch text {
        case "Connection refused":
            return .connectionRefused
        case "Operation timed out":
            return .timedOut
        case "Connection reset by peer", "Broken pipe":
            return .connectionReset
        case "Network is unreachable", "No route to host", "Network is down", "Host is down":
            return .networkUnreachable
        case "No space left on device":
            return .noSpace
        case "Server returned 400 Bad Request":
            return .badRequest
        case "Server returned 401 Unauthorized (authorization failed)":
            return .unauthorized
        case "Server returned 403 Forbidden (access denied)":
            return .forbidden
        case "Server returned 404 Not Found":
            return .notFound
        case "Server returned 429 Too Many Requests":
            return .tooManyRequests
        case "Server returned 4XX Client Error, but not one of 40{0,1,3,4}":
            return .otherClientError
        case "Server returned 5XX Server Error reply":
            return .serverError
        case "Invalid data found when processing input":
            return .invalidData
        case "End of file":
            return .endOfStream
        case "Server certificate not trusted":
            return .untrustedCertificate
        case "Secure connection failed":
            return .secureConnectionFailed
        default:
            return nil
        }
    }

    /// FFERRTAG(a, b, c, d) of libavutil/error.h: -MKTAG(a, b, c, d). The HTTP codes start with the byte 0xF8, which is
    /// not ASCII (so not a `Character` with an `asciiValue`).
    private static func errorTag(_ a: UInt8, _ b: Character, _ c: Character, _ d: Character) -> Int32 {
        let bytes = [UInt32(a)] + [b, c, d].map { UInt32($0.asciiValue ?? 0) }
        return -Int32(bitPattern: bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24)
    }

    private static func errorTag(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> Int32 {
        errorTag(a.asciiValue ?? 0, b, c, d)
    }

    /// `code`: the engine's error code for the message (`FluxoRemuxEvent.error_code`), 0 when there is none.
    static func localized(_ message: String, code: Int32 = 0) -> String {
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
        let reason = (code != 0 ? self.reason(code: code, stage: stage) : nil)
            ?? self.reason(text: parts[1])
            ?? (stage == openStage && parts[1] == "Input/output error" ? .serverNotFound : nil)
        return String(localized: "\(localizedStage): \(reason?.localizedDescription ?? parts[1])", comment: "Player or recording error: what failed, then the reason (localized for the common ones, otherwise FFmpeg's technical reason in English).")
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

    /// The `what` / `stage` strings of the C engine.
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
