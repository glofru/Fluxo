//
//  PlaybackRoute.swift
//  Fluxo
//
//  Decides whether a URL is played directly by AVPlayer or through the remux engine.
//

import Foundation

enum PlaybackRoute: Equatable {
    /// AVPlayer plays the URL itself (HLS playlists, MP4/MOV files, audio files, ...).
    case direct
    /// The remux engine converts the input to local HLS. Live inputs get a time-shift window and
    /// are reconnected when they drop; on-demand inputs get a complete VOD playlist whose segments the
    /// engine produces as the player asks for them (any position can be played at once).
    case remux(isLive: Bool)

    private static let streamingSchemes: Set<String> = ["udp", "rtp", "rtmp", "rtmps", "rtsp", "srt"]
    /// Raw MPEG-TS: AVPlayer cannot play it outside HLS. IPTV live channels use it, usually without (or with
    /// a .ts) extension.
    private static let transportStreamExtensions: Set<String> = ["ts", "mts", "m2ts", "mpegts"]
    /// Progressive files AVPlayer opens itself. If it cannot (a server without byte ranges, a codec tagging
    /// it does not decode), `AVPlayerViewModel` plays them through the engine instead.
    private static let nativeFileExtensions: Set<String> = [
        "mp4", "m4v", "mov", "3gp", "3g2", "m4a", "mp3", "aac", "ac3", "eac3", "wav", "aif", "aiff", "caf", "flac",
    ]
    /// Containers of movies and episodes that AVPlayer cannot open (Matroska, AVI, ...): the engine demuxes them.
    private static let engineFileExtensions: Set<String> = [
        "mkv", "mk3d", "webm", "avi", "divx", "xvid", "flv", "mpg", "mpeg", "m2v", "vob", "ogv", "wmv",
    ]
    private static let playlistExtensions: Set<String> = ["m3u8"]

    /// - Parameter kind: what the playlist says the entry is, when it comes from a playlist (`nil` for
    ///   recordings and other URLs). It decides between the live and the on-demand engine for inputs whose
    ///   URL does not tell: an Xtream Codes movie can be `…/movie/user/pass/123.ts` or have no extension.
    init(url: URL, kind: ChannelContentKind? = nil) {
        let scheme = url.scheme?.lowercased() ?? ""
        let pathExtension = url.pathExtension.lowercased()

        if url.isFileURL {
            // Recordings are MP4; other local files (an older .ts recording, a downloaded .mkv) are on demand.
            if Self.nativeFileExtensions.contains(pathExtension) || Self.playlistExtensions.contains(pathExtension) || pathExtension == "movpkg" {
                self = .direct
            } else {
                self = .remux(isLive: false)
            }
            return
        }
        if Self.streamingSchemes.contains(scheme) {
            self = .remux(isLive: true)
            return
        }
        if Self.playlistExtensions.contains(pathExtension) || Self.nativeFileExtensions.contains(pathExtension) {
            self = .direct
            return
        }
        let isOnDemand = kind.map { $0 != .live }
        if pathExtension.isEmpty || Self.transportStreamExtensions.contains(pathExtension) {
            // Without a kind (a URL played on its own) an extensionless or .ts URL is taken for a live channel:
            // a finite input then simply ends once it is read.
            self = .remux(isLive: !(isOnDemand ?? false))
        } else if Self.engineFileExtensions.contains(pathExtension) {
            // A live FLV channel is possible (HTTP-FLV); a Matroska or AVI file is a movie.
            self = .remux(isLive: !(isOnDemand ?? true))
        } else if isOnDemand == true {
            // A movie behind a script (`…/play.php?stream=…`) or another extension: libavformat probes it.
            self = .remux(isLive: false)
        } else {
            // Live channels behind scripts are often HLS, which AVPlayer plays best (adaptive bit rate).
            self = .direct
        }
    }

    /// The engine route for a movie or episode AVPlayer failed to play directly (see
    /// `AVPlayerViewModel.fallBackToEngine()`), or nil when the engine would not do better (HLS, local files).
    static func onDemandFallback(for url: URL) -> PlaybackRoute? {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https", !playlistExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        return .remux(isLive: false)
    }

    var isLiveRemux: Bool {
        self == .remux(isLive: true)
    }

    var isOnDemandRemux: Bool {
        self == .remux(isLive: false)
    }
}
