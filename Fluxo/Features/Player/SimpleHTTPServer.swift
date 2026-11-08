//
//  SimpleHTTPServer.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import FlyingFox
import FlyingSocks
import Foundation
import OSLog
import Synchronization

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "HTTPServer")

/// Time limits of the loopback HLS path. They come from one constant, so the server never ends a request that the
/// engine still works on.
enum LoopbackTimeouts {
    /// Longest wait for an on-demand segment (`StreamRemuxer.requestFile(named:)`): a slow server, or a seek far into
    /// a file that cannot seek.
    static let segmentWait: Duration = .seconds(45)
    /// The server's limit for one request: the segment wait, plus the time to read the file from disk and send it.
    /// FlyingFox answers 500 after its limit, so it must be longer than `segmentWait` (FlyingFox's default is 15 s).
    static let request: Duration = segmentWait + .seconds(15)
}

/// Serves the HLS files produced by the remux engine to AVPlayer.
///
/// Exposure: the server listens only on the IPv4 loopback interface (127.0.0.1), so only this device can reach it,
/// never the local network. Inside the device it accepts only requests that:
/// - use the port the system gave it (an ephemeral port, different at every start, so no other app can expect it);
/// - send the `Host` header of that address (`127.0.0.1:<port>`): a web page that a DNS rebinding attack points at
///   127.0.0.1 sends its own host name, and gets 421;
/// - name the random token of the current playback session as the first path component
///   (`/<token>/<file>`, see `beginSession()`): a request without it, or with the token of an earlier session, gets 404.
/// It serves flat file names from a single directory and only the HLS file types it knows.
///
/// Segments of on-demand playlists are produced when they are requested: before a file is read, the
/// `fileProvider` is asked for it and may wait until the engine has written it.
@MainActor
final class SimpleHTTPServer {

    /// Called for every file request with its name, before the file is read. Returns false when the file
    /// will not exist (the server answers 404 at once).
    typealias FileProvider = @Sendable @concurrent (String) async -> Bool
    nonisolated static let host = "127.0.0.1"

    /// Why the server is not listening.
    enum StartError: LocalizedError {
        /// The socket could not be bound or could not listen (the reason is in the log).
        case unavailable
        /// The server did not start listening in time.
        case timedOut

        var errorDescription: String? {
            String(localized: "The player couldn't start its local stream server. Try again.", comment: "Player error: the app's internal streaming server (on this device only) could not start.")
        }
    }

    /// Debug builds can ask for a fixed port (`-FluxoDebugLoopbackPort <port>`, for test scripts that look at the
    /// server). The server stays on 127.0.0.1 either way. Otherwise the system picks a free port.
    private nonisolated static var debugPortOverride: UInt16? {
        #if DEBUG
        let value = UserDefaults.standard.integer(forKey: "FluxoDebugLoopbackPort")
        return (1024...65535).contains(value) ? UInt16(value) : nil
        #else
        return nil
        #endif
    }

    private enum Listening {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed
    }

    private var task: Task<Void, Never>?
    private var server: HTTPServer?
    private var root: URL?
    private var listening: Listening = .stopped
    private var listeningWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// The port of the latest server that listened: a server started again (e.g. after iOS reclaimed the socket while
    /// the app was suspended) asks for it first, so the player items of the session keep their addresses.
    private var lastPort: UInt16?
    /// Shutdown of the previous server; the next server waits for it so that the port is free.
    private var pendingStop: Task<Void, Never>?
    /// What every request is checked against (requests run off the main actor).
    private nonisolated let gate = RequestGate()

    /// Sets (or clears) the file provider of the session being served.
    func setFileProvider(_ fileProvider: FileProvider?) {
        gate.setProvider(fileProvider)
    }

    /// Starts a new playback session: its files get addresses with a new random token, and the addresses of earlier
    /// sessions stop working.
    func beginSession() {
        gate.setToken(Self.makeToken())
    }

    var isRunning: Bool {
        task != nil
    }

    init() {
        gate.setToken(Self.makeToken())
    }

    deinit {
        task?.cancel()
        if let server {
            Task {
                await server.stop()
            }
        }
    }

    /// Returns the loopback URL AVPlayer has to use for a file of the served directory in the current session, or nil
    /// while the server is not listening (its port is known only then).
    func url(forFileNamed fileName: String) -> URL? {
        guard case .listening(let port) = listening else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = Self.host
        components.port = Int(port)
        components.path = "/\(gate.token())/\(fileName)"
        return components.url
    }

    /// Starts serving `root`. Calling it again for the same directory while running is a no-op.
    /// If the server stopped on its own (e.g. iOS reclaimed the socket while the app was suspended),
    /// calling it again starts a new server.
    func start(root: URL) {
        if task != nil, self.root == root {
            return
        }
        stop()
        // The port of the previous server first, then any free one: the system picks it (port 0).
        var ports: [UInt16] = [Self.debugPortOverride ?? lastPort ?? 0]
        if Self.debugPortOverride == nil, ports[0] != 0 {
            ports.append(0)
        }
        self.root = root
        setListening(.starting)
        let previousStop = pendingStop
        let gate = gate
        self.task = Task { @MainActor [weak self] in
            // stop() releases the socket asynchronously: binding before it is closed would fail.
            await previousStop?.value
            for port in ports {
                let server: HTTPServer
                do {
                    server = try Self.makeServer(port: port)
                } catch {
                    logger.error("Invalid loopback address: \(error.localizedDescription, privacy: .public)")
                    break
                }
                await server.appendRoute("GET /*") { request in
                    await Self.response(for: request, root: root, gate: gate)
                }
                // (The owner is not retained while the server runs: the task must not keep it alive.)
                guard !Task.isCancelled, let watcher = self?.adopt(server) else {
                    return
                }
                do {
                    try await server.run()
                    watcher.cancel()
                    break
                } catch {
                    watcher.cancel()
                    logger.error("Server on port \(port) stopped: \(error.localizedDescription, privacy: .public)")
                    // A server that listened, then stopped, is started again by the next start(), not here.
                    guard !Task.isCancelled, self?.isStarting == true else {
                        break
                    }
                }
            }
            // Forget a server that is no longer listening so that the next start creates a new one.
            guard !Task.isCancelled, let self else {
                return
            }
            self.task = nil
            self.server = nil
            self.root = nil
            self.gate.setPort(nil)
            self.setListening(.failed)
        }
    }

    /// Waits until the server accepts connections (at most `timeout` seconds). Returns false when it does not: it
    /// could not bind or listen, or it was stopped.
    @discardableResult
    func waitUntilListening(timeout: Duration = .seconds(3)) async -> Bool {
        switch listening {
        case .listening:
            return true
        case .stopped, .failed:
            return false
        case .starting:
            break
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            listeningWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.listeningWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    /// The error to show when the server is not listening, nil while it is (or starts).
    var startError: StartError? {
        switch listening {
        case .failed, .stopped:
            return .unavailable
        case .starting, .listening:
            return nil
        }
    }

    func stop() {
        let server = server
        task?.cancel()
        task = nil
        self.server = nil
        root = nil
        gate.setPort(nil)
        setListening(.stopped)
        if let server {
            let previousStop = pendingStop
            pendingStop = Task {
                await previousStop?.value
                await server.stop()
            }
        }
    }

    private static func makeServer(port: UInt16) throws -> HTTPServer {
        let address = try sockaddr_in.inet(ip4: host, port: port)
        return HTTPServer(address: address, timeout: TimeInterval(LoopbackTimeouts.request.components.seconds))
    }

    /// Makes `server` the current one, and returns the task that publishes its port once it listens.
    private func adopt(_ server: HTTPServer) -> Task<Void, Never> {
        self.server = server
        return Task { @MainActor [weak self] in
            await self?.watchListening(of: server)
        }
    }

    private var isStarting: Bool {
        if case .starting = listening {
            return true
        }
        return false
    }

    /// Reads the port the system gave `server` once it listens.
    private func watchListening(of server: HTTPServer) async {
        do {
            try await server.waitUntilListening(timeout: 10)
        } catch {
            return
        }
        guard self.server === server, case .ip4(_, let port)? = await server.listeningAddress, self.server === server else {
            return
        }
        lastPort = port
        gate.setPort(port)
        logger.info("Listening on \(Self.host, privacy: .public):\(port)")
        setListening(.listening(port: port))
    }

    private func setListening(_ state: Listening) {
        listening = state
        let result: Bool
        switch state {
        case .starting:
            return
        case .listening:
            result = true
        case .stopped, .failed:
            result = false
        }
        let waiters = listeningWaiters
        listeningWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: result)
        }
    }

    /// 128 random bits from the system's generator, in hexadecimal.
    private nonisolated static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in
            let value = generator.next() as UInt64
            let hex = String(value, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }.joined()
    }

    @concurrent private nonisolated static func response(for request: HTTPRequest, root: URL, gate: RequestGate) async -> HTTPResponse {
        guard gate.acceptsHost(request.headers[.host]) else {
            return HTTPResponse(statusCode: .misdirectedRequest)
        }
        // "/<token>/<file>": only flat file names of the current session, no directories and no path traversal.
        let components = request.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard components.count == 2, let token = components.first, gate.acceptsToken(token) else {
            return HTTPResponse(statusCode: .notFound)
        }
        let fileName = String(components[components.startIndex + 1])
        guard !fileName.isEmpty,
              !fileName.contains("\\"),
              !fileName.hasPrefix("."),
              let contentType = contentType(forFileNamed: fileName) else {
            return HTTPResponse(statusCode: .notFound)
        }

        if let provider = gate.provider(), !(await provider(fileName)) {
            return HTTPResponse(statusCode: .notFound)
        }
        let fileURL = root.appendingPathComponent(fileName, isDirectory: false)
        guard let contents = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return HTTPResponse(statusCode: .notFound)
        }

        var headers: [HTTPHeader: String] = [.contentType: contentType]
        if fileName.hasSuffix(".m3u8") {
            // Live playlists change continuously.
            headers[HTTPHeader("Cache-Control")] = "no-cache"
        }
        return HTTPResponse(statusCode: .ok, headers: headers, body: contents)
    }

    private nonisolated static func contentType(forFileNamed fileName: String) -> String? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "m3u8":
            return "application/vnd.apple.mpegurl"
        case "ts":
            return "video/mp2t"
        case "m4s", "mp4":
            return "video/mp4"
        case "aac":
            return "audio/aac"
        case "vtt":
            return "text/vtt"
        default:
            return nil
        }
    }
}

/// What requests are checked against, shared with the request handlers: the session token, the listening port and the
/// file provider of the session being served. Safe to share: every value is behind its `Mutex`.
private final class RequestGate: Sendable {
    private let state = Mutex<(token: String, port: UInt16?, provider: SimpleHTTPServer.FileProvider?)>(("", nil, nil))

    func setProvider(_ provider: SimpleHTTPServer.FileProvider?) {
        state.withLock {
            $0.provider = provider
        }
    }

    func provider() -> SimpleHTTPServer.FileProvider? {
        state.withLock {
            $0.provider
        }
    }

    func setToken(_ token: String) {
        state.withLock {
            $0.token = token
        }
    }

    func token() -> String {
        state.withLock {
            $0.token
        }
    }

    /// The port the server listens on (nil while it does not).
    func setPort(_ port: UInt16?) {
        state.withLock {
            $0.port = port
        }
    }

    /// The `Host` header must be the address of the server (AVPlayer sends the host and port of the URL).
    func acceptsHost(_ host: String?) -> Bool {
        guard let host, let port = state.withLock({ $0.port }) else {
            return false
        }
        return host == "\(SimpleHTTPServer.host):\(port)"
    }

    /// Compares in constant time, so the time of an answer tells nothing about the token.
    func acceptsToken(_ candidate: Substring) -> Bool {
        let expected = Array(token().utf8)
        let given = Array(candidate.utf8)
        guard !expected.isEmpty, expected.count == given.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in expected.indices {
            difference |= expected[index] ^ given[index]
        }
        return difference == 0
    }
}
