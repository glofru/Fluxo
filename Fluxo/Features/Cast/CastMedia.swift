//
//  CastMedia.swift
//  Fluxo
//
//  Turns a channel into what the Chromecast's Default Media Receiver is asked to load.
//
//  The receiver reads the ORIGINAL stream URL itself. Fluxo never serves anything to it: the remux engine's HLS
//  is on a loopback-only server (127.0.0.1), which another device cannot reach, and it must stay that way. So:
//
//  - HLS, DASH, MP4 / WebM / Matroska files and audio files are sent as they are, with their MIME type.
//  - Raw MPEG-TS channels (no extension or `.ts`, the ones the remux engine plays on this device) are sent as
//    `video/mp2t`. The Default Media Receiver (Shaka Player in a browser) generally cannot play a continuous TS
//    stream, so for Xtream Codes style URLs the HLS variant that most IPTV panels publish for the same channel
//    is tried next (`…/123.ts` → `…/123.m3u8`, `/user/pass/123` → `/live/user/pass/123.m3u8`), then, unless the URL
//    ends in `.ts`, the same URL as HLS (some providers serve HLS from extensionless or `.php` URLs). If all fail,
//    the user gets a clear message and the channel keeps playing on this device.
//  - Recordings (local files), loopback / localhost URLs and udp / rtp / rtmp / rtsp / srt inputs cannot be cast.
//

import Foundation

enum CastMedia {

    /// Why a channel cannot be cast at all (nothing is sent to the receiver).
    enum Unsupported: Error, Equatable {
        case noURL
        case localFile
        case loopback(host: String)
        case scheme(String)

        var message: String {
            switch self {
            case .noURL:
                return String(localized: "This channel has no stream address to cast.")
            case .localFile:
                return String(localized: "Recordings are stored on this device and can't be cast.")
            case .loopback(let host):
                return String(localized: "This stream (\(host)) only plays on this device, so a Chromecast can't reach it.")
            case .scheme(let scheme):
                return String(localized: "Chromecast can't play \(scheme):// streams.")
            }
        }
    }

    /// The streams to try, best first, for `url`. Later entries are fallbacks for raw MPEG-TS channels.
    static func requests(
        for url: URL?,
        title: String?,
        subtitle: String?,
        logo: String?,
        isLive: Bool,
        startTime: TimeInterval?
    ) -> Result<[CastLoadRequest], Unsupported> {
        guard let url else {
            return .failure(.noURL)
        }
        if url.isFileURL {
            return .failure(.localFile)
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            return .failure(.scheme(scheme.isEmpty ? "?" : scheme))
        }
        if let host = url.host(), isLoopback(host) {
            return .failure(.loopback(host: host))
        }

        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        let imageURL = logo.flatMap(URL.init(string:)).flatMap { image -> URL? in
            let scheme = image.scheme?.lowercased()
            guard scheme == "http" || scheme == "https", let host = image.host(), !isLoopback(host) else {
                return nil
            }
            return image
        }
        func request(_ url: URL, contentType: String) -> CastLoadRequest {
            CastLoadRequest(
                url: url,
                contentType: contentType,
                streamType: isLive ? .live : .buffered,
                title: name,
                subtitle: subtitle,
                imageURL: imageURL,
                startTime: isLive ? nil : startTime
            )
        }

        let type = contentType(for: url)
        var requests = [request(url, contentType: type)]
        if type == transportStreamType {
            if let hls = hlsVariant(of: url) {
                requests.append(request(hls, contentType: hlsType))
            }
            // Some providers serve HLS from extensionless or script URLs (`…/play.php?id=1`): try the same URL as
            // HLS too. Only `.ts` URLs are known to be MPEG-TS.
            if url.pathExtension.lowercased() != "ts" {
                requests.append(request(url, contentType: hlsType))
            }
        }
        return .success(requests)
    }

    static let hlsType = "application/x-mpegurl"
    static let transportStreamType = "video/mp2t"

    /// MIME type of a stream URL, from its extension. Extensionless IPTV URLs are usually raw MPEG-TS.
    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u":
            return hlsType
        case "mpd":
            return "application/dash+xml"
        case "mp4", "m4v", "mov":
            return "video/mp4"
        case "webm":
            return "video/webm"
        case "mkv":
            return "video/x-matroska"
        case "mp3":
            return "audio/mpeg"
        case "aac":
            return "audio/aac"
        case "m4a":
            return "audio/mp4"
        case "ogg", "oga", "opus":
            return "audio/ogg"
        case "flac":
            return "audio/flac"
        default:
            return transportStreamType
        }
    }

    /// The HLS address Xtream Codes style panels publish next to a raw MPEG-TS channel, if `url` looks like one.
    static func hlsVariant(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.last else {
            return nil
        }
        let pathExtension = (last as NSString).pathExtension.lowercased()
        let stem = (last as NSString).deletingPathExtension
        var newParts: [String]
        switch pathExtension {
        case "ts":
            // …/live/user/pass/123.ts → …/live/user/pass/123.m3u8
            newParts = parts.dropLast() + [stem + ".m3u8"]
        case "":
            if parts.count == 4, parts[0].lowercased() == "live" {
                // /live/user/pass/123
                newParts = parts.dropLast() + [last + ".m3u8"]
            } else if parts.count == 3, last.allSatisfy(\.isNumber) {
                // /user/pass/123 (the short live form)
                newParts = ["live"] + parts.dropLast() + [last + ".m3u8"]
            } else {
                return nil
            }
        default:
            return nil
        }
        components.path = "/" + newParts.joined(separator: "/")
        return components.url
    }

    /// The message shown when every request for a channel failed on the receiver.
    static func failureMessage(for url: URL?, deviceName: String, failure: CastFailure) -> String {
        if failure.kind == .media, let url, contentType(for: url) == transportStreamType {
            if ["", "ts"].contains(url.pathExtension.lowercased()) {
                return String(localized: "\(deviceName) can't play this channel: it's a raw MPEG-TS stream, which Chromecast doesn't support. It keeps playing on this device.")
            }
            return String(localized: "\(deviceName) can't play this channel's stream format. It keeps playing on this device.")
        }
        if let message = failure.message {
            return String(localized: "\(deviceName) can't play this channel. \(message)")
        }
        return String(localized: "\(deviceName) can't play this channel.")
    }

    /// The receiver reports the media's URL as it was sent, but compare leniently (percent-encoding) so that a
    /// receiver that normalizes it is not taken for other media.
    static func isSameMedia(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else {
            return lhs == rhs
        }
        if lhs == rhs {
            return true
        }
        let left = lhs.absoluteString.removingPercentEncoding ?? lhs.absoluteString
        let right = rhs.absoluteString.removingPercentEncoding ?? rhs.absoluteString
        return left == right
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "::1" || host == "0.0.0.0"
    }
}
