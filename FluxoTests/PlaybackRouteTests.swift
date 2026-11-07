//
//  PlaybackRouteTests.swift
//  FluxoTests
//
//  Which URLs AVPlayer plays itself and which go through the remux engine (`PlaybackRoute`), live or on demand, and
//  when a movie AVPlayer opened moves to the engine (`PlaybackRoute.engineReason`).
//

import Foundation
import Testing
@testable import Fluxo

@Suite("Playback route")
struct PlaybackRouteTests {

    private func route(_ address: String, kind: ChannelContentKind? = nil) throws -> PlaybackRoute {
        PlaybackRoute(url: try #require(URL(string: address)), kind: kind)
    }

    @Test("HLS playlists and progressive files AVPlayer opens play directly, whatever the playlist says", arguments: [
        "https://cdn.example.com/live/index.m3u8",
        "https://cdn.example.com/LIVE/INDEX.M3U8?token=abc",
        "https://cdn.example.com/movie/1.mp4",
        "https://cdn.example.com/movie/1.MOV",
        "https://cdn.example.com/radio/stream.mp3",
        "https://cdn.example.com/audio/track.flac",
    ])
    func direct(_ address: String) throws {
        #expect(try route(address) == .direct)
        #expect(try route(address, kind: .movie) == .direct)
        #expect(try route(address, kind: .live) == .direct)
    }

    @Test("Streaming protocols are live inputs of the engine", arguments: [
        "udp://@239.0.0.1:1234", "rtp://239.0.0.2:5004", "rtmp://live.example/app/stream", "rtmps://live.example/app/stream",
        "rtsp://camera.example/stream", "srt://live.example:9000",
    ])
    func streamingSchemes(_ address: String) throws {
        #expect(try route(address) == .remux(isLive: true))
        #expect(try route(address, kind: .movie) == .remux(isLive: true))
    }

    @Test("Raw MPEG-TS and extensionless URLs: live unless the playlist says it is a movie or an episode")
    func transportStreams() throws {
        for address in ["http://iptv.example/live/user/pass/1234.ts", "http://iptv.example/live/user/pass/1234", "http://iptv.example/stream.m2ts"] {
            #expect(try route(address) == .remux(isLive: true), "\(address)")
            #expect(try route(address, kind: .live) == .remux(isLive: true), "\(address)")
            #expect(try route(address, kind: .movie) == .remux(isLive: false), "\(address)")
            #expect(try route(address, kind: .series) == .remux(isLive: false), "\(address)")
        }
    }

    @Test("Containers AVPlayer cannot open are movies through the engine, unless the playlist says live", arguments: [
        "mkv", "webm", "avi", "flv", "mpg", "vob", "wmv", "ogg", "opus",
    ])
    func engineContainers(_ pathExtension: String) throws {
        let address = "http://vod.example/movie/user/pass/42.\(pathExtension)"
        #expect(try route(address) == .remux(isLive: false))
        #expect(try route(address, kind: .movie) == .remux(isLive: false))
        #expect(try route(address, kind: .live) == .remux(isLive: true), "a live HTTP-FLV channel, for instance")
    }

    @Test("Behind a script: a movie goes through the engine, a live channel plays directly (often HLS)")
    func scripts() throws {
        let address = "http://iptv.example/play.php?stream=42"
        #expect(try route(address, kind: .movie) == .remux(isLive: false))
        #expect(try route(address, kind: .live) == .direct)
        #expect(try route(address) == .direct)
    }

    @Test("Local files: recordings, HLS downloads and MP4 play directly; other files are on demand through the engine")
    func localFiles() {
        #expect(PlaybackRoute(url: URL(fileURLWithPath: "/tmp/Recording.mp4")) == .direct)
        #expect(PlaybackRoute(url: URL(fileURLWithPath: "/tmp/Download.movpkg")) == .direct)
        #expect(PlaybackRoute(url: URL(fileURLWithPath: "/tmp/Old Recording.ts")) == .remux(isLive: false))
        #expect(PlaybackRoute(url: URL(fileURLWithPath: "/tmp/Movie.mkv"), kind: .live) == .remux(isLive: false))
    }

    @Test("A movie AVPlayer failed to play falls back to the engine, except HLS and local files")
    func onDemandFallback() throws {
        #expect(PlaybackRoute.onDemandFallback(for: try #require(URL(string: "https://vod.example/1.mp4"))) == .remux(isLive: false))
        #expect(PlaybackRoute.onDemandFallback(for: try #require(URL(string: "https://vod.example/1.m3u8"))) == nil)
        #expect(PlaybackRoute.onDemandFallback(for: URL(fileURLWithPath: "/tmp/1.mp4")) == nil)
        #expect(try route("udp://@239.0.0.1:1234").isLiveRemux)
        #expect(try route("http://vod.example/1.mkv").isOnDemandRemux)
    }

    // MARK: - Tracks of a movie AVPlayer opened

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private let h264 = PlaybackRoute.DirectTrack(format: Self.fourCC("avc1"), isPlayable: true)
    private let aac = PlaybackRoute.DirectTrack(format: Self.fourCC("aac "), isPlayable: true)

    @Test("A movie whose tracks AVPlayer all plays stays with AVPlayer")
    func playableTracks() {
        #expect(PlaybackRoute.engineReason(video: [h264], audio: [aac]) == nil)
        #expect(PlaybackRoute.engineReason(video: [], audio: [aac]) == nil, "audio only")
    }

    @Test("Video or audio AVPlayer cannot decode, or video without any audio it knows, moves to the engine")
    func engineReasons() {
        let hevcTaggedHev1 = PlaybackRoute.DirectTrack(format: Self.fourCC("hev1"), isPlayable: false)
        let dts = PlaybackRoute.DirectTrack(format: Self.fourCC("dtsc"), isPlayable: false)
        #expect(PlaybackRoute.engineReason(video: [hevcTaggedHev1], audio: [aac]) != nil)
        #expect(PlaybackRoute.engineReason(video: [h264], audio: [dts]) != nil)
        #expect(PlaybackRoute.engineReason(video: [h264], audio: []) != nil)
    }

    @Test("MPEG-4 Part 2 beyond the Simple Profile is converted on iPhone and iPad, not on the Mac")
    func mpeg4Part2() {
        let xvid = PlaybackRoute.DirectTrack(format: Self.fourCC("mp4v"), isPlayable: true)
        let simpleProfile = PlaybackRoute.DirectTrack(format: Self.fourCC("mp4v"), isPlayable: true, isDeviceMPEG4: true)
        #expect(PlaybackRoute.engineReason(video: [simpleProfile], audio: [aac]) == nil)
        #if os(iOS)
        #expect(PlaybackRoute.engineReason(video: [xvid], audio: [aac]) != nil)
        #else
        #expect(PlaybackRoute.engineReason(video: [xvid], audio: [aac]) == nil)
        #endif
    }
}
