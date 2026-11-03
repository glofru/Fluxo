//
//  SimpleHTTPServer.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import FlyingFox
import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "HTTPServer")

/// Serves the HLS files produced by the remux engine to AVPlayer.
///
/// The server only listens on the IPv4 loopback interface (127.0.0.1): it is reachable from this
/// device alone and never from the local network. It serves flat file names from a single directory
/// and only the HLS file types it knows.
@MainActor
final class SimpleHTTPServer {
    nonisolated static let host = "127.0.0.1"
    nonisolated static let port: UInt16 = 19123

    private var task: Task<Void, Never>?
    private var server: HTTPServer?
    private var root: URL?
    /// Shutdown of the previous server; the next server waits for it so that the port is free.
    private var pendingStop: Task<Void, Never>?

    var isRunning: Bool {
        task != nil
    }

    deinit {
        task?.cancel()
        if let server {
            Task {
                await server.stop()
            }
        }
    }

    /// Returns the loopback URL AVPlayer has to use for a file of the served directory.
    nonisolated static func url(forFileNamed fileName: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/\(fileName)"
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

        let address: sockaddr_in
        do {
            address = try .inet(ip4: Self.host, port: Self.port)
        } catch {
            logger.error("Invalid loopback address: \(error.localizedDescription, privacy: .public)")
            return
        }

        let server = HTTPServer(address: address)
        self.server = server
        self.root = root
        let previousStop = pendingStop
        self.task = Task { @MainActor [weak self] in
            await server.appendRoute("GET /*") { request in
                Self.response(for: request, root: root)
            }
            // stop() releases the socket asynchronously: binding before it is closed would fail.
            await previousStop?.value
            guard !Task.isCancelled else {
                return
            }
            do {
                try await server.run()
            } catch {
                logger.info("Server stopped: \(error.localizedDescription, privacy: .public)")
            }
            // Forget a server that is no longer listening so that the next start creates a new one.
            guard let self, self.server === server else {
                return
            }
            self.task = nil
            self.server = nil
            self.root = nil
        }
    }

    /// Waits until the server accepts connections (at most `timeout` seconds).
    func waitUntilListening(timeout: TimeInterval = 3) async {
        guard let server else {
            return
        }
        try? await server.waitUntilListening(timeout: timeout)
    }

    func stop() {
        let server = server
        task?.cancel()
        task = nil
        self.server = nil
        root = nil
        if let server {
            let previousStop = pendingStop
            pendingStop = Task {
                await previousStop?.value
                await server.stop()
            }
        }
    }

    private nonisolated static func response(for request: HTTPRequest, root: URL) -> HTTPResponse {
        // Only flat file names are served: no directories and no path traversal.
        let fileName = String(request.path.drop(while: { $0 == "/" }))
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.hasPrefix("."),
              let contentType = contentType(forFileNamed: fileName) else {
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
