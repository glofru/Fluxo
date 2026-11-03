//
//  StreamRemuxer.swift
//  Fluxo
//
//  Swift wrapper around the C remux engine (FluxoRemuxEngine), shared by iOS and macOS.
//

import Foundation

/// Remuxes a stream into an HLS playlist on disk using the shared libavformat engine.
///
/// The class is main-thread confined: call its methods and read its state from the main thread.
/// Events coming from the engine thread are delivered on the main queue.
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

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "The stream configuration is invalid."
            case .unableToStart(let code):
                return "Unable to start the stream engine (\(code))."
            case .notRunning:
                return "The stream is not running."
            }
        }
    }

    struct Configuration {
        var inputURL: URL
        var outputDirectory: URL
        /// Unique name of the session, used as prefix for the playlist and the segments.
        var name: String
        /// Live inputs are reconnected when they drop; on-demand inputs end with EXT-X-ENDLIST.
        var isLive: Bool = true
        var segmentDuration: Double = 2
        /// Longest time-shift (DVR) window. 0 keeps every segment.
        var maxWindowDuration: TimeInterval = 30 * 60
        /// Disk budget of the time-shift window. 0 means no limit.
        var maxWindowBytes: Int64 = 512 * 1024 * 1024
        var ioTimeout: TimeInterval = 15
        /// Consecutive reconnection attempts. 0 uses the engine default, negative is unlimited.
        var maxReconnectAttempts: Int = 0
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

        var segmentPathPrefix: String {
            outputDirectory.appendingPathComponent(filePrefix).path
        }
    }

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

    private static let teardownQueue = DispatchQueue(label: "dev.watermelon.Fluxo.StreamRemuxer.teardown", qos: .utility)

    deinit {
        stop()
    }

    /// Starts remuxing `configuration.inputURL`, stopping any running session first.
    func start(_ configuration: Configuration) throws {
        stop()

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
    func stop(recordingCompletion: ((URL) -> Void)? = nil) {
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
        if isProcessing {
            update(.cancelled)
        }

        // Joining the engine thread may wait for a blocking read to be interrupted: never on main.
        Self.teardownQueue.async {
            fluxo_remux_destroy(session)
            box?.release()
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
            if !event.state.isActive, let recordingURL {
                // The engine thread has ended and reports every recording before its final state, so
                // this request was never opened (e.g. it was queued after the engine's last check).
                self.recordingURL = nil
                onEvent?(.recordingStopped(RecordingProgress(url: recordingURL, duration: 0, bytes: 0)))
            }
            update(event.state)
        case .segmentWritten:
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
            onEvent?(.recordingFailed(progress?.url, event.message ?? "Recording failed"))
        }
    }

    private static func makeSession(_ configuration: Configuration, context: UnsafeMutableRawPointer) -> OpaquePointer? {
        let input = configuration.inputURL.isFileURL ? configuration.inputURL.path : configuration.inputURL.absoluteString
        let playlist = configuration.playlistURL.path
        let prefix = configuration.segmentPathPrefix
        let userAgent = configuration.userAgent ?? ""

        return input.withCString { inputPointer in
            playlist.withCString { playlistPointer in
                prefix.withCString { prefixPointer in
                    userAgent.withCString { userAgentPointer in
                        var config = FluxoRemuxConfig()
                        config.input_url = inputPointer
                        config.user_agent = userAgentPointer
                        config.io_timeout_us = Int64(configuration.ioTimeout * 1_000_000)
                        config.is_live = configuration.isLive ? 1 : 0
                        config.max_reconnect_attempts = Int32(clamping: configuration.maxReconnectAttempts)
                        config.hls.playlist_path = playlistPointer
                        config.hls.segment_path_prefix = prefixPointer
                        config.hls.segment_duration = configuration.segmentDuration
                        config.hls.max_window_duration = configuration.maxWindowDuration
                        config.hls.max_window_bytes = configuration.maxWindowBytes
                        config.hls.min_window_segments = 3
                        return fluxo_remux_create(&config, StreamRemuxer.engineCallback, context)
                    }
                }
            }
        }
    }

    private static func removeFiles(of configuration: Configuration) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: configuration.outputDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(configuration.filePrefix) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Removes the files of every session (e.g. left over by a crash). Call before the first session.
    static func removeAllFiles(in directory: URL) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("stream-") {
            try? fileManager.removeItem(at: file)
        }
    }

    private static let engineCallback: FluxoRemuxEventCallback = { context, eventPointer in
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

    init(_ event: FluxoRemuxEvent) {
        kind = event.kind
        message = event.message.map { String(cString: $0) }
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
            state = .failed(event.message.map { String(cString: $0) } ?? "Unknown error")
        }
        statistics = StreamRemuxer.WindowStatistics(
            segmentsWritten: Int(event.segments_written),
            segmentCount: Int(event.window_segment_count),
            duration: event.window_duration,
            bytes: event.window_bytes
        )
        recordingPath = event.recording_path.map { String(cString: $0) }
        recordingDuration = event.recording_duration
        recordingBytes = event.recording_bytes
    }
}

/// Bridges engine callbacks back to the owning remuxer. Retained for the whole life of a C session.
private final class CallbackBox {
    weak var owner: StreamRemuxer?

    init(owner: StreamRemuxer) {
        self.owner = owner
    }
}
