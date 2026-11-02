//
//  StreamRemuxer.swift
//  Fluxo
//
//  Swift wrapper around the C remux engine (FluxoRemuxEngine). It replaces the previous
//  ffmpegkit based FFmpegManager and is shared by iOS and macOS.
//

import Foundation

/// Remuxes a stream into an HLS playlist on disk using the shared libavformat engine.
///
/// The class is main-thread confined: call its methods and read its state from the main thread.
/// State changes coming from the engine thread are delivered on the main queue.
final class StreamRemuxer {

    enum State: Equatable {
        case idle
        case opening
        case running
        case finished
        case cancelled
        case failed(String)
    }

    enum RemuxError: LocalizedError {
        case invalidConfiguration
        case unableToStart(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "The stream configuration is invalid."
            case .unableToStart(let code):
                return "Unable to start the stream engine (\(code))."
            }
        }
    }

    struct Configuration {
        var inputURL: URL
        var outputDirectory: URL
        /// Unique name of the session, used as prefix for the playlist and the segments.
        var name: String
        var segmentDuration: Double = 2
        /// Number of segments kept in the live playlist. 0 keeps every segment.
        var playlistSize: Int = 15
        var deleteOldSegments: Bool = true
        var ioTimeout: TimeInterval = 15
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

        var segmentPathPattern: String {
            outputDirectory.appendingPathComponent("\(filePrefix)-%05d.ts").path
        }
    }

    /// Called on the main queue every time the state changes.
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .idle {
        didSet {
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }

    var isProcessing: Bool {
        state == .opening || state == .running
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
        self.state = .opening
    }

    /// Stops the running session (if any) without blocking the caller, then removes its files.
    func stop() {
        guard let session else {
            return
        }

        let box = callbackBox
        let configuration = configuration
        self.session = nil
        self.callbackBox = nil
        self.configuration = nil

        // Ignore any late callback of the stopped session.
        box?.takeUnretainedValue().owner = nil
        fluxo_remux_cancel(session)
        if isProcessing {
            state = .cancelled
        }

        // Joining the engine thread may wait for a blocking read to be interrupted: never on main.
        Self.teardownQueue.async {
            fluxo_remux_destroy(session)
            box?.release()
            if let configuration {
                Self.removeFiles(of: configuration)
            }
        }
    }

    private func handle(_ newState: State, from box: CallbackBox) {
        guard callbackBox?.takeUnretainedValue() === box else {
            return
        }
        state = newState
    }

    private static func makeSession(_ configuration: Configuration, context: UnsafeMutableRawPointer) -> OpaquePointer? {
        let input = configuration.inputURL.absoluteString
        let playlist = configuration.playlistURL.path
        let pattern = configuration.segmentPathPattern
        let userAgent = configuration.userAgent ?? ""

        return input.withCString { inputPointer in
            playlist.withCString { playlistPointer in
                pattern.withCString { patternPointer in
                    userAgent.withCString { userAgentPointer in
                        var config = FluxoRemuxConfig()
                        config.input_url = inputPointer
                        config.user_agent = userAgentPointer
                        config.io_timeout_us = Int64(configuration.ioTimeout * 1_000_000)
                        config.hls.playlist_path = playlistPointer
                        config.hls.segment_path_pattern = patternPointer
                        config.hls.segment_duration = configuration.segmentDuration
                        config.hls.playlist_size = Int32(configuration.playlistSize)
                        config.hls.delete_old_segments = configuration.deleteOldSegments ? 1 : 0
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

    private static let engineCallback: FluxoRemuxStateCallback = { context, state, _, message in
        guard let context else {
            return
        }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        let newState: State
        switch state {
        case .idle:
            newState = .idle
        case .opening:
            newState = .opening
        case .running:
            newState = .running
        case .finished:
            newState = .finished
        case .cancelled:
            newState = .cancelled
        case .failed:
            newState = .failed(message.map { String(cString: $0) } ?? "Unknown error")
        }

        DispatchQueue.main.async {
            box.owner?.handle(newState, from: box)
        }
    }
}

/// Bridges engine callbacks back to the owning remuxer. Retained for the whole life of a C session.
private final class CallbackBox {
    weak var owner: StreamRemuxer?

    init(owner: StreamRemuxer) {
        self.owner = owner
    }
}
