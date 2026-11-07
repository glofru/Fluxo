//
//  DownloadProbe.swift
//  Fluxo
//
//  Finds out what a link is before it is downloaded: an HLS stream, a file AVPlayer plays as it is, or a file that
//  must be copied into MP4, and how large it is (for the free-space check). IPTV links rarely say: on-demand
//  entries are often extensionless (`/movie/user/pass/123`) or claim a type they are not, so the first 4 KB are read
//  (a ranged request) and the content is recognized by its signature, then by its Content-Type and extension.
//

import Foundation

struct DownloadProbe: Sendable {

    enum Kind: Equatable, Sendable {
        case hls
        /// Plays as it is; the extension the file is stored with ("mp4", "mov", "mp3").
        case file(String)
        /// Copied into MP4 after the download; the extension of the downloaded original ("mkv", "ts").
        case remux(String)
    }

    let kind: Kind
    /// The size of the file, when the server says.
    let expectedBytes: Int64?

    var method: DownloadMethod {
        switch kind {
        case .hls:
            return .hls
        case .file:
            return .file
        case .remux:
            return .remux
        }
    }

    /// The file name the transfer writes in the download's folder.
    var transferFileName: String? {
        switch kind {
        case .hls:
            return nil
        case .file(let fileExtension):
            return "media.\(fileExtension)"
        case .remux(let fileExtension):
            return "source.\(fileExtension)"
        }
    }

    private static let playableExtensions: Set<String> = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav"]
    private static let remuxExtensions: Set<String> = [
        "mkv", "mk3d", "webm", "ts", "mts", "m2ts", "m2t", "mpegts", "flv", "f4v", "mpg", "mpeg", "vob", "avi", "divx", "xvid", "wmv",
        "asf", "ogv", "ogg", "ogm",
    ]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Reads the start of `url`. HLS links named `.m3u8` are not fetched (AVFoundation reads the playlist itself).
    @concurrent static func probe(_ url: URL) async throws -> DownloadProbe {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "m3u8" {
            return DownloadProbe(kind: .hls, expectedBytes: nil)
        }
        if url.isFileURL {
            throw DownloadFailure.notVideo
        }

        var request = URLRequest(url: url)
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw DownloadFailure.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            bytes.task.cancel()
            throw DownloadFailure.http(status)
        }
        var head = Data()
        head.reserveCapacity(4_096)
        do {
            for try await byte in bytes {
                head.append(byte)
                if head.count >= 4_096 {
                    break
                }
            }
        } catch {
            if head.isEmpty {
                throw DownloadFailure.network(error)
            }
        }
        bytes.task.cancel()

        let size = Self.totalSize(of: response, status: status)
        let contentType = (response.mimeType ?? "").lowercased()
        guard let kind = classify(head, contentType: contentType, pathExtension: pathExtension) else {
            throw DownloadFailure.notVideo
        }
        return DownloadProbe(kind: kind, expectedBytes: kind == .hls ? nil : size)
    }

    /// The kind of content from its first bytes, then its type and extension. nil: not a video.
    static func classify(_ head: Data, contentType: String, pathExtension: String) -> Kind? {
        let bytes = [UInt8](head.prefix(512))

        func starts(with prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }

        // A playlist, maybe after a byte order mark or blank lines.
        let text = String(decoding: bytes.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if text.hasPrefix("#EXTM3U") || contentType.contains("mpegurl") {
            return .hls
        }
        // ISO base media (MP4, MOV, M4V, M4A): a box type at offset 4.
        if starts(with: Array("ftyp".utf8), at: 4) {
            if starts(with: Array("qt  ".utf8), at: 8) {
                return .file("mov")
            }
            if starts(with: Array("M4A ".utf8), at: 8) {
                return .file("m4a")
            }
            return .file(["m4v", "mov"].contains(pathExtension) ? pathExtension : "mp4")
        }
        if ["moov", "mdat", "free", "wide", "skip"].contains(where: { starts(with: Array($0.utf8), at: 4) }) {
            return .file(pathExtension == "mov" ? "mov" : "mp4")
        }
        // Matroska / WebM (EBML).
        if starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return .remux(pathExtension == "webm" ? "webm" : "mkv")
        }
        // MPEG transport stream: a sync byte every 188 bytes (192 for M2TS, after a 4-byte time code).
        if bytes.count > 376, bytes[0] == 0x47, bytes[188] == 0x47 {
            return .remux("ts")
        }
        if bytes.count > 388, bytes[4] == 0x47, bytes[196] == 0x47 {
            return .remux("m2ts")
        }
        if starts(with: Array("FLV".utf8)) {
            return .remux("flv")
        }
        // MPEG program stream.
        if starts(with: [0x00, 0x00, 0x01, 0xBA]) {
            return .remux("mpg")
        }
        // AVI (RIFF), Windows Media (the ASF header object's GUID) and Ogg: converted into MP4 (with their audio and
        // video converted to AAC / H.264 when the device does not decode them).
        if starts(with: Array("RIFF".utf8)), starts(with: Array("AVI ".utf8), at: 8) {
            return .remux("avi")
        }
        if starts(with: [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            return .remux("wmv")
        }
        if starts(with: Array("OggS".utf8)) {
            return .remux("ogv")
        }
        if starts(with: Array("ID3".utf8)) {
            return .file("mp3")
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 {
            // ADTS AAC.
            return .file("aac")
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            return .file("mp3")
        }
        // A web page or an error document instead of the video.
        if contentType.hasPrefix("text/") || contentType.contains("json") || contentType.contains("xml") || text.hasPrefix("<") || text.hasPrefix("{") {
            return nil
        }
        if playableExtensions.contains(pathExtension) {
            return .file(pathExtension)
        }
        if remuxExtensions.contains(pathExtension) {
            return .remux(pathExtension)
        }
        if contentType.hasPrefix("video/mp4") || contentType.hasPrefix("video/quicktime") {
            return .file(contentType.hasPrefix("video/quicktime") ? "mov" : "mp4")
        }
        // Unknown but binary: the remux engine probes the content itself.
        return .remux("bin")
    }

    /// The whole size: the total of `Content-Range` for a partial answer, the length of a full one.
    private static func totalSize(of response: URLResponse, status: Int) -> Int64? {
        if status == 206, let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }), total > 0 {
            return total
        }
        if status == 200, response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        return nil
    }
}
