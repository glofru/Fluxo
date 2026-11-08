//
//  LoopbackServerTests.swift
//  FluxoTests
//
//  The player's loopback HLS server (`SimpleHTTPServer`): it listens on 127.0.0.1 on a port the system picks, serves
//  only the files of the current playback session (its token), only to requests that name its address in `Host`
//  (421 otherwise, against DNS rebinding), and waits for an on-demand segment longer than FlyingFox's default 15 s
//  (`LoopbackTimeouts`). Tools/EngineSmokeTest/run_vod.sh plays through it with AVPlayer.
//

import Darwin
import Foundation
import Testing
@testable import Fluxo

@Suite("Loopback server", .serialized)
@MainActor
struct LoopbackServerTests {

    private let root: URL
    private let server = SimpleHTTPServer()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#EXTM3U\n".utf8).write(to: root.appendingPathComponent("index.m3u8"))
        try Data(repeating: 0x47, count: 188).write(to: root.appendingPathComponent("index-000000.ts"))
    }

    /// Starts the server and returns the address of `fileName` in the current session.
    private func start(_ fileName: String = "index.m3u8") async throws -> URL {
        server.start(root: root)
        #expect(await server.waitUntilListening())
        return try #require(server.url(forFileNamed: fileName))
    }

    private func status(of url: URL) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(from: url)
        return try #require(response as? HTTPURLResponse).statusCode
    }

    private func address(of url: URL, token: String? = nil, file: String? = nil) throws -> URL {
        var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let parts = components.path.split(separator: "/").map(String.init)
        components.path = "/" + [token ?? parts[0], file ?? parts[1]].joined(separator: "/")
        return try #require(components.url)
    }

    @Test("Listens on 127.0.0.1 on a port the system picks, and serves the session's files")
    func servesSessionFiles() async throws {
        let url = try await start()
        defer { server.stop() }
        #expect(url.host == "127.0.0.1")
        let port = try #require(url.port)
        #expect(port > 0 && port != 19123)
        // "/<128-bit token in hexadecimal>/<file>"
        let token = url.pathComponents[1]
        #expect(token.count == 32 && token.allSatisfy(\.isHexDigit))
        #expect(try await status(of: url) == 200)
        #expect(try await status(of: try #require(server.url(forFileNamed: "index-000000.ts"))) == 200)
    }

    @Test("Without the session's token, with another session's, or outside the one directory: 404")
    func rejectsOtherAddresses() async throws {
        let url = try await start()
        defer { server.stop() }
        #expect(try await status(of: address(of: url, token: String(repeating: "0", count: 32))) == 404)
        #expect(try await status(of: try #require(URL(string: "http://127.0.0.1:\(url.port ?? 0)/index.m3u8"))) == 404)
        #expect(try await status(of: address(of: url, file: ".hidden.m3u8")) == 404)
        #expect(try await status(of: address(of: url, file: "notes.txt")) == 404)
        #expect(try await status(of: try #require(URL(string: url.absoluteString + "/extra"))) == 404)

        server.beginSession()
        // The address of the earlier session stops working; the new one works.
        #expect(try await status(of: url) == 404)
        #expect(try await status(of: try #require(server.url(forFileNamed: "index.m3u8"))) == 200)
    }

    @Test("A request whose Host is not the server's address (DNS rebinding) gets 421")
    func rejectsOtherHosts() async throws {
        let url = try await start()
        defer { server.stop() }
        let port = UInt16(try #require(url.port))
        let path = url.path
        let good = try await Self.rawStatusLine(port: port, request: "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n")
        #expect(good.contains(" 200"))
        for host in ["attacker.example", "attacker.example:\(port)", "localhost:\(port)", "127.0.0.1"] {
            let line = try await Self.rawStatusLine(port: port, request: "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n")
            #expect(line.contains(" 421"), "Host: \(host) => \(line)")
        }
        let none = try await Self.rawStatusLine(port: port, request: "GET \(path) HTTP/1.1\r\nConnection: close\r\n\r\n")
        #expect(none.contains(" 421"))
    }

    @Test("No address while the server is not listening, and a stopped server reports why")
    func noAddressWhenStopped() async {
        #expect(server.url(forFileNamed: "index.m3u8") == nil)
        #expect(!(await server.waitUntilListening(timeout: .milliseconds(100))))
        #expect(server.startError == .unavailable)
    }

    @Test("A provider that says the file will not come: 404 at once")
    func providerRefuses() async throws {
        server.setFileProvider { _ in false }
        let url = try await start()
        defer { server.stop() }
        #expect(try await status(of: url) == 404)
    }

    @Test("The server allows a request longer than the engine's wait for a segment, from one constant (H1)")
    func timeoutsAreOrdered() {
        #expect(LoopbackTimeouts.request > LoopbackTimeouts.segmentWait + .seconds(5))
        #expect(StreamRemuxer.segmentRequestTimeout == LoopbackTimeouts.segmentWait)
        // FlyingFox's default (15 s) answered 500 for any slower segment.
        #expect(LoopbackTimeouts.segmentWait > .seconds(15))
    }

    @Test("A segment the engine produces in 17 s is served, not answered 500 at FlyingFox's default 15 s (H1)")
    func slowSegmentIsServed() async throws {
        server.setFileProvider { _ in
            try? await Task.sleep(for: .seconds(17))
            return true
        }
        let url = try await start("index-000000.ts")
        defer { server.stop() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.count == 188)
    }

    /// Sends `request` as it is to 127.0.0.1:`port` and returns the first line of the answer.
    nonisolated private static func rawStatusLine(port: UInt16, request: String) async throws -> String {
        try await Task.detached {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else {
                throw POSIXError(.EIO)
            }
            defer { close(socket) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                throw POSIXError(.ECONNREFUSED)
            }
            let bytes = Array(request.utf8)
            guard send(socket, bytes, bytes.count, 0) == bytes.count else {
                throw POSIXError(.EIO)
            }
            var answer = [UInt8](repeating: 0, count: 512)
            let count = recv(socket, &answer, answer.count, 0)
            guard count > 0 else {
                throw POSIXError(.EIO)
            }
            let text = String(decoding: answer[..<count], as: UTF8.self)
            return String(text.split(separator: "\r\n").first ?? "")
        }.value
    }
}
