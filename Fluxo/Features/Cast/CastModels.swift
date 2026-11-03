//
//  CastModels.swift
//  Fluxo
//
//  Values shared by the Chromecast controller, its backends and the views. They do not depend on the Google
//  Cast SDK, so the views and the player compile (and preview) on every platform.
//

import Foundation

/// A Cast receiver found on the local network (a Chromecast, a TV with Chromecast built-in, a speaker, a group).
struct CastDevice: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case tv
        case speaker
        case group
        case generic
    }

    /// The SDK's unique ID of the device.
    let id: String
    let name: String
    let model: String?
    let kind: Kind

    var systemImage: String {
        switch kind {
        case .tv:
            return "tv"
        case .speaker:
            return "hifispeaker"
        case .group:
            return "hifispeaker.2"
        case .generic:
            return "tv.and.mediabox"
        }
    }
}

/// What the receiver plays, from its last media status.
struct CastMediaStatus: Equatable, Sendable {
    enum PlayerState: Sendable {
        case idle
        case loading
        case buffering
        case playing
        case paused
    }

    /// Why the receiver is idle.
    enum IdleReason: Sendable {
        case none
        /// The media played to its end.
        case finished
        /// A stop request (from a sender or the TV remote).
        case cancelled
        /// Other media was loaded in its place.
        case interrupted
        /// The receiver could not play the media.
        case error
    }

    var playerState: PlayerState
    var idleReason: IdleReason = .none
    var contentURL: URL?
    var title: String?
    var isLive: Bool
    /// Duration of on-demand media, 0 when unknown or live.
    var duration: TimeInterval = 0
    /// Position at `positionDate`.
    var position: TimeInterval = 0
    var positionDate = Date()
    var playbackRate: Double = 1
    var canSeek = false
    var canPause = true

    /// The position now, extrapolated from the last status while playing.
    func position(at date: Date) -> TimeInterval {
        guard playerState == .playing else {
            return position
        }
        let extrapolated = position + max(0, date.timeIntervalSince(positionDate)) * playbackRate
        return duration > 0 ? min(extrapolated, duration) : extrapolated
    }
}

/// One attempt at loading a stream on the receiver.
struct CastLoadRequest: Equatable, Sendable {
    enum StreamType: Sendable {
        case live
        case buffered
    }

    let url: URL
    /// MIME type the receiver picks its player with.
    let contentType: String
    let streamType: StreamType
    let title: String
    let subtitle: String?
    /// Artwork the receiver shows (only http(s) URLs: the receiver cannot read data URIs or local files).
    let imageURL: URL?
    /// Position to start on-demand media at; nil starts at the beginning, or at the live edge of a live stream.
    let startTime: TimeInterval?
}

/// Why a request or a session failed, as the user should read it.
struct CastFailure: Error, Equatable, Sendable {
    enum Kind: Sendable {
        /// The user cancelled (e.g. declined the Cast terms) or a newer request replaced this one: never retried.
        case cancelled
        /// The receiver could not load or play the media.
        case media
        /// Network, authentication or protocol problems.
        case connection
    }

    let kind: Kind
    /// A short, user-facing explanation (nil for cancellations, which need none).
    let message: String?

    static let cancelled = CastFailure(kind: .cancelled, message: nil)
}
