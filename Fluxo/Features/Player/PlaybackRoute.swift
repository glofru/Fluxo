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
    /// are reconnected when they drop; on-demand inputs are kept whole.
    case remux(isLive: Bool)

    private static let streamingSchemes: Set<String> = ["udp", "rtp", "rtmp", "rtmps", "rtsp", "srt"]
    /// Containers AVPlayer cannot play on its own.
    private static let transportStreamExtensions: Set<String> = ["ts", "mts", "m2ts", "mpegts"]
    /// Movie and episode files AVPlayer cannot open (Matroska is the usual container of series episodes, with
    /// several audio tracks and subtitles): the engine plays them as on-demand inputs and turns their extra audio
    /// tracks and text subtitles into selectable renditions.
    private static let onDemandEngineExtensions: Set<String> = ["mkv", "mk3d", "webm", "avi", "divx", "xvid"]

    init(url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        let pathExtension = url.pathExtension.lowercased()

        if url.isFileURL {
            let usesEngine = Self.transportStreamExtensions.contains(pathExtension) || Self.onDemandEngineExtensions.contains(pathExtension)
            self = usesEngine ? .remux(isLive: false) : .direct
        } else if Self.streamingSchemes.contains(scheme) {
            self = .remux(isLive: true)
        } else if pathExtension.isEmpty || Self.transportStreamExtensions.contains(pathExtension) {
            // IPTV live channels are raw MPEG-TS over HTTP, usually without (or with a .ts) extension.
            // Any other extensionless HTTP URL (an on-demand file or an HLS endpoint) lands here too:
            // libavformat still plays it, it just gets a time-shift window and reconnection it does
            // not need, and a finite input ends normally once it is read to the end.
            self = .remux(isLive: true)
        } else if Self.onDemandEngineExtensions.contains(pathExtension) {
            self = .remux(isLive: false)
        } else {
            self = .direct
        }
    }

    var isLiveRemux: Bool {
        self == .remux(isLive: true)
    }
}
