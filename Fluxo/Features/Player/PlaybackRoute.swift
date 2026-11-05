//
//  PlaybackRoute.swift
//  Fluxo
//
//  Decides whether a URL is played directly by AVPlayer or through the remux engine.
//

import AVFoundation
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
    private static let transportStreamExtensions: Set<String> = ["ts", "mts", "m2ts", "m2t", "mpegts", "trp"]
    /// Progressive files AVPlayer opens itself. If it cannot (a server without byte ranges, a codec tagging
    /// it does not decode), `AVPlayerViewModel` plays them through the engine instead.
    private static let nativeFileExtensions: Set<String> = [
        "mp4", "m4v", "mov", "3gp", "3g2", "m4a", "mp3", "aac", "ac3", "eac3", "wav", "aif", "aiff", "caf", "flac",
    ]
    /// Containers of movies and episodes that AVPlayer cannot open (Matroska, AVI, ...): the engine demuxes them, and
    /// converts what AVPlayer cannot decode (see FluxoTranscoder.h). Audio-only ones too (Matroska audio, Ogg, WMA).
    private static let engineFileExtensions: Set<String> = [
        "mkv", "mk3d", "mka", "webm", "avi", "divx", "xvid", "flv", "f4v", "mpg", "mpeg", "m2v", "vob", "ogv", "ogg", "oga",
        "ogm", "opus", "wmv", "wma", "asf",
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

// MARK: - Tracks of a movie AVPlayer opened directly

extension PlaybackRoute {

    /// A track of an asset AVPlayer opened: its format (the four-character media subtype of its first format
    /// description, 0 when unknown) and whether AVPlayer says it can play it.
    struct DirectTrack: Equatable {
        var format: UInt32
        var isPlayable: Bool
        /// MPEG-4 Part 2 video in the Simple Profile at up to 640 × 480, which every iPhone and iPad decodes (its
        /// published video formats): played as it is.
        var isDeviceMPEG4 = false
    }

    /// Video formats that iPhone and iPad do not decode reliably even when AVFoundation lists them as playable:
    /// MPEG-4 Part 2 (Xvid / DivX in MP4 or MOV, beyond the simple profile at SD sizes: `isDeviceMPEG4`), H.263 (3GP)
    /// and MPEG-1 / MPEG-2 in QuickTime. The engine converts them to H.264. The Mac decodes them.
    private static let convertedVideoFormats: Set<UInt32> = ["mp4v", "h263", "s263", "mp2v", "mp1v", "xvid", "XVID", "DIVX", "DX50"]
        .reduce(into: []) { formats, code in
            formats.insert(code.utf8.reduce(0) { $0 << 8 | UInt32($1) })
        }

    /// Why a movie or episode AVPlayer opened directly should play through the engine instead (which copies what
    /// AVPlayer decodes and converts the rest), or nil when AVPlayer plays it all.
    /// - video without a track AVPlayer can play (HEVC tagged `hev1`);
    /// - on iPhone and iPad, video in a format it does not decode reliably (`convertedVideoFormats`);
    /// - audio AVPlayer cannot decode, or video without any audio track: AVFoundation leaves out the tracks it does
    ///   not know (DTS, TrueHD in MP4), so a movie seems silent. A movie that really has no sound simply plays
    ///   through the engine.
    static func engineReason(video: [DirectTrack], audio: [DirectTrack]) -> String? {
        if !video.isEmpty && !video.contains(where: \.isPlayable) {
            return "AVPlayer cannot decode the video track"
        }
        #if os(iOS)
        if let track = video.first(where: { convertedVideoFormats.contains($0.format) && !$0.isDeviceMPEG4 }) {
            return "the video format \(track.format) is converted on this device"
        }
        #endif
        if !audio.isEmpty && !audio.contains(where: \.isPlayable) {
            return "AVPlayer cannot decode the audio track"
        }
        if !video.isEmpty && audio.isEmpty {
            return "no audio track AVPlayer knows"
        }
        return nil
    }
}

extension PlaybackRoute {

    /// `engineReason(video:audio:)` for the tracks of `asset` (a movie AVPlayer opened, or a downloaded file).
    nonisolated static func engineReason(for asset: AVAsset) async -> String? {
        async let video = directTracks(of: asset, mediaType: .video)
        async let audio = directTracks(of: asset, mediaType: .audio)
        return engineReason(video: await video, audio: await audio)
    }

    private nonisolated static func directTracks(of asset: AVAsset, mediaType: AVMediaType) async -> [DirectTrack] {
        guard let tracks = try? await asset.loadTracks(withMediaType: mediaType) else {
            return []
        }
        var result: [DirectTrack] = []
        for track in tracks {
            let playable = (try? await track.load(.isPlayable)) ?? false
            let description = (try? await track.load(.formatDescriptions))?.first
            let format = description.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            result.append(DirectTrack(format: format, isPlayable: playable, isDeviceMPEG4: description.map(isDeviceMPEG4) ?? false))
        }
        return result
    }

    /// MPEG-4 Part 2 Simple Profile (the profile_and_level_indication of the visual object sequence header in the
    /// track's `esds`: levels 0 to 5) at up to 640 × 480. Advanced Simple (Xvid, DivX with B-frames, quarter-pixel)
    /// or a header that cannot be read: false.
    private nonisolated static func isDeviceMPEG4(_ description: CMFormatDescription) -> Bool {
        guard CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_MPEG4Video else {
            return false
        }
        let size = CMVideoFormatDescriptionGetDimensions(description)
        let width = Int(min(size.width, size.height))
        let height = Int(max(size.width, size.height))
        guard width > 0, width <= 480, height <= 640 else {
            return false
        }
        guard let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let esds = atoms["esds"] as? Data else {
            return false
        }
        let bytes = [UInt8](esds)
        guard bytes.count >= 5 else {
            return false
        }
        for index in 0..<(bytes.count - 4) where bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 && bytes[index + 3] == 0xB0 {
            // Simple Profile: levels 1 to 5 (0x01–0x05) and level 0 (0x08).
            return [0x01, 0x02, 0x03, 0x04, 0x05, 0x08].contains(bytes[index + 4])
        }
        return false
    }
}
