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

/// Why a download failed or could not start.
///
/// A failed download keeps its `reason` (in the manifest), not a message: the message is built when it is shown,
/// in the current language, so it follows a language change. Only errors without a known kind keep the text of
/// their own description, as `GuideRefreshFailure` does.
struct DownloadFailure: Error, Sendable {

    enum Reason: Codable, Hashable, Sendable {
        /// The server answered with an error status.
        case http(status: Int)
        /// The server returned a web page or something else that is not a video.
        case notVideo
        /// The remux engine can neither copy nor convert the file; its message (in English, from
        /// FluxoRemuxEngine.c), when it gave one.
        case unsupportedFormat(engineMessage: String?)
        case insufficientSpace
        /// The downloaded HLS stream cannot be played offline.
        case incomplete
        /// AVFoundation could not download the HLS stream.
        case streamUnavailable
        /// No connection, a timeout, a server that cannot be reached, a certificate that is not valid.
        case network(NetworkKind)
        /// Any other error: its description at the time it failed.
        case other(String)
    }

    enum NetworkKind: String, Codable, Sendable {
        case offline
        case timedOut
        case cannotConnect
        case insecureConnection
    }

    let reason: Reason
    /// Retrying the same link cannot help.
    var isPermanent = false
    /// A network problem (a timeout, a dropped connection, no route): retried automatically, and again when the
    /// network returns.
    var isNetworkError = false

    /// The HTTP status, when the server answered with an error.
    var httpStatus: Int? {
        if case .http(let status) = reason {
            return status
        }
        return nil
    }

    /// The link was refused or is gone (expired credentials or token, an entry the provider removed): a newer copy
    /// of the playlist may have another link for the same entry.
    var isExpiredLink: Bool {
        guard let httpStatus else {
            return false
        }
        return [401, 403, 404, 410].contains(httpStatus)
    }

    /// The message in the current language.
    var message: String {
        reason.message
    }

    static func http(_ status: Int) -> DownloadFailure {
        DownloadFailure(reason: .http(status: status))
    }

    static var notVideo: DownloadFailure {
        DownloadFailure(reason: .notVideo, isPermanent: true)
    }

    static func unsupportedFormat(engineMessage: String? = nil) -> DownloadFailure {
        DownloadFailure(reason: .unsupportedFormat(engineMessage: engineMessage?.isEmpty == false ? engineMessage : nil), isPermanent: true)
    }

    static var insufficientSpace: DownloadFailure {
        DownloadFailure(reason: .insufficientSpace)
    }

    static var incomplete: DownloadFailure {
        DownloadFailure(reason: .incomplete)
    }

    static var streamUnavailable: DownloadFailure {
        DownloadFailure(reason: .streamUnavailable)
    }

    /// A network or other system error: by its kind when it has a known one, otherwise by its description.
    static func network(_ error: any Error) -> DownloadFailure {
        // The URL error, also when AVFoundation wraps it.
        var kind: NetworkKind?
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let nsError = current else {
                break
            }
            if nsError.domain == NSURLErrorDomain {
                kind = NetworkKind(URLError.Code(rawValue: nsError.code))
                break
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return DownloadFailure(reason: kind.map(Reason.network) ?? .other(error.localizedDescription), isNetworkError: DownloadTransport.isNetworkError(error))
    }

    /// Any other error, by its description.
    static func other(_ error: any Error) -> DownloadFailure {
        DownloadFailure(reason: .other(error.localizedDescription))
    }
}

extension DownloadFailure.NetworkKind {
    init?(_ code: URLError.Code) {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            self = .offline
        case .timedOut:
            self = .timedOut
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost:
            self = .cannotConnect
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            self = .insecureConnection
        default:
            return nil
        }
    }
}

extension DownloadFailure.Reason {
    /// The message in the current language.
    var message: String {
        switch self {
        case .http(let status):
            switch status {
            case 401, 403:
                return String(localized: "The provider refused the download. The link may have expired: refresh the playlist and try again.", comment: "Download error: the server answered 401 or 403.")
            case 404, 410:
                return String(localized: "The provider no longer has this video. Refresh the playlist and try again.", comment: "Download error: the server answered 404 or 410.")
            case 429:
                return String(localized: "The provider limits downloads right now. Try again later.", comment: "Download error: the server answered 429 (too many requests).")
            default:
                return DownloadError.httpStatus(status).localizedDescription
            }
        case .notVideo:
            return String(localized: "This link doesn't lead to a video that can be downloaded.", comment: "Download error: the server returned a web page or something else that is not a video.")
        case .unsupportedFormat(let engineMessage):
            let message = String(localized: "This video format can't be played on this device, so it isn't downloaded.", comment: "Download error: the file is in a format the app can neither play nor convert (such as an unknown video codec).")
            guard let engineMessage else {
                return message
            }
            // The engine named the codec: its sentence says it all ("This video can't be played: its video format
            // (vp9) isn't supported."). Otherwise its technical detail follows, isolated so that its Latin text
            // and colons keep their order in a right-to-left sentence.
            if let sentence = EngineMessage.formatSentence(engineMessage) {
                return sentence
            }
            let detail = TextParts.isolated(EngineMessage.localized(engineMessage))
            return String(
                localized: "DownloadFailure.withDetail",
                defaultValue: "\(message) (\(detail))",
                comment: "Download error: the reason a video can't be downloaded, then in parentheses the technical detail from the converter (often in English, such as 'Unable to open the stream: Invalid data found when processing input'). Use the parentheses and spacing of your language."
            )
        case .insufficientSpace:
            return String(localized: "There isn't enough free space on this device for this download.", comment: "Download error: the device does not have enough free storage.")
        case .incomplete:
            return String(localized: "The download is incomplete. Try again.", comment: "Download error: the downloaded stream cannot be played offline.")
        case .streamUnavailable:
            // AVFoundation's own description is often only "unknown error": say what it means here.
            return String(localized: "This stream can't be saved for offline viewing right now. Try again later.", comment: "Download error: the system could not download an HLS stream for offline playback (an AVFoundation error).")
        case .network(.offline):
            return String(localized: "No internet connection.", comment: "Download error (a TV guide or an offline download): the device is offline.")
        case .network(.timedOut):
            return String(localized: "The server took too long to respond.", comment: "Download error (a TV guide or an offline download): the request timed out.")
        case .network(.cannotConnect):
            return String(localized: "Could not connect to the server.", comment: "Download error (a TV guide or an offline download): the server could not be found, did not accept the connection, or the connection was lost.")
        case .network(.insecureConnection):
            return String(localized: "A secure connection to the server could not be made.", comment: "Download error (a TV guide or an offline download): the server's certificate is not valid, or the address needs https.")
        case .other(let text):
            return text
        }
    }
}

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
