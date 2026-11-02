//
//  SimpleHTTPServer.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import FlyingFox
import Foundation

/// Serves the HLS files produced by the remux engine to AVPlayer.
///
/// The server only listens on the IPv4 loopback interface (127.0.0.1): it is reachable from this
/// device alone and never from the local network. It serves flat file names from a single directory
/// and only the HLS file types it knows.
final class SimpleHTTPServer {
    static let host = "127.0.0.1"
    static let port: UInt16 = 19123

    private var task: Task<Void, Never>?
    private var server: HTTPServer?
    private var root: URL?

    var isRunning: Bool {
        task != nil
    }

    deinit {
        stop()
    }

    /// Returns the loopback URL AVPlayer has to use for a file of the served directory.
    static func url(forFileNamed fileName: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/\(fileName)"
        return components.url
    }

    /// Starts serving `root`. Calling it again for the same directory while running is a no-op.
    func start(root: URL) {
        if task != nil, self.root == root {
            return
        }
        stop()

        let address: sockaddr_in
        do {
            address = try .inet(ip4: Self.host, port: Self.port)
        } catch {
            print("HTTP server: invalid loopback address: \(error)")
            return
        }

        let server = HTTPServer(address: address)
        self.server = server
        self.root = root
        self.task = Task {
            await server.appendRoute("GET /*") { request in
                Self.response(for: request, root: root)
            }
            do {
                try await server.run()
            } catch {
                print("HTTP server stopped: \(error)")
            }
        }
    }

    func stop() {
        let server = server
        task?.cancel()
        task = nil
        self.server = nil
        root = nil
        if let server {
            Task {
                await server.stop()
            }
        }
    }

    private static func response(for request: HTTPRequest, root: URL) -> HTTPResponse {
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

    private static func contentType(forFileNamed fileName: String) -> String? {
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
