//
//  PlaybackEnergyProfile.swift
//  Fluxo
//
//  How much the player spends on what nobody sees. Decoding and downloading video, and following the playback
//  position for the controls, are the costs of playback the app controls; the profile sizes them to what is on
//  screen and to the energy situation of the device (`PowerMonitor`):
//
//  - the playback position is sampled twice a second only while the player screen can show it; once a second in
//    Picture in Picture (the time jumps of its skip buttons are compared with what was buffered at the latest
//    sample, see `AVPlayerViewModel.itemTimeJumped`), and every two seconds otherwise (the mini player, the
//    background: the watch progress is saved every ten seconds);
//  - adaptive (HLS) streams with several qualities are limited: to the lowest one while only the audio is heard in
//    the background (the screen is locked or another app is in front, without Picture in Picture); to 720p in
//    Picture in Picture; to 1080p in Low Power Mode, 720p when the device is hot (serious thermal state) and 480p
//    when it is critical. Streams with a single quality (the remux engine's, most IPTV channels) are not affected;
//  - the video is not decoded while nothing can show it: while the mini player plays a channel, the player layer
//    lets go of the player (AVPlayer then only plays the audio) and takes it again as soon as the player screen
//    opens. It keeps it in the background with the player screen open, which is what Picture in Picture starts
//    from (the system stops drawing the video of an app in the background itself);
//  - the display stays awake only while the video is on screen (the player screen or Picture in Picture), not
//    while the mini player plays a channel and the user has left the device alone.
//

import CoreMedia
import CoreGraphics
import Foundation

struct PlaybackEnergyProfile: Equatable {

    /// What the profile depends on.
    struct Conditions: Equatable {
        var isLowPowerModeEnabled = false
        var thermalState: ProcessInfo.ThermalState = .nominal
        /// The app is in the background (iOS), or hidden or fully covered (macOS).
        var isInBackground = false
        /// A player screen shows the video (it may be covered by the app's own sheets).
        var isPlayerScreenVisible = false
        /// The player screen is open or opening (`AVPlayerViewModel.isPresented`), also while it closes into Picture
        /// in Picture.
        var isPlayerPresented = false
        var isPictureInPictureActive = false
    }

    /// The highest qualities of an adaptive stream, by resolution and by bit rate.
    struct QualityLimit: Equatable {
        /// `.zero`: no limit.
        var maximumResolution: CGSize = .zero
        /// Bits per second; 0: no limit.
        var peakBitRate: Double = 0

        static let none = QualityLimit()
        /// The lowest quality a stream offers (AVPlayer picks the variant closest to the limit from below, or the
        /// lowest one when every variant is larger).
        static let lowest = QualityLimit(maximumResolution: CGSize(width: 426, height: 240), peakBitRate: 500_000)
        static let hd1080 = QualityLimit(maximumResolution: CGSize(width: 1920, height: 1080), peakBitRate: 0)
        static let hd720 = QualityLimit(maximumResolution: CGSize(width: 1280, height: 720), peakBitRate: 4_000_000)
        static let sd480 = QualityLimit(maximumResolution: CGSize(width: 854, height: 480), peakBitRate: 2_000_000)

        /// The stricter of two limits, dimension by dimension (0 is "no limit").
        func combined(with other: QualityLimit) -> QualityLimit {
            func stricter(_ a: Double, _ b: Double) -> Double {
                a == 0 ? b : (b == 0 ? a : min(a, b))
            }
            let resolution: CGSize
            if maximumResolution == .zero {
                resolution = other.maximumResolution
            } else if other.maximumResolution == .zero {
                resolution = maximumResolution
            } else {
                resolution = maximumResolution.width * maximumResolution.height <= other.maximumResolution.width * other.maximumResolution.height
                    ? maximumResolution : other.maximumResolution
            }
            return QualityLimit(maximumResolution: resolution, peakBitRate: stricter(peakBitRate, other.peakBitRate))
        }
    }

    /// The controls of the player screen can show the position.
    static let visibleTimeObserverInterval = CMTime(value: 1, timescale: 2)
    static let pictureInPictureTimeObserverInterval = CMTime(value: 1, timescale: 1)
    static let hiddenTimeObserverInterval = CMTime(value: 2, timescale: 1)

    let conditions: Conditions
    /// How often the player samples the playback position (`addPeriodicTimeObserver`).
    let timeObserverInterval: CMTime
    let qualityLimit: QualityLimit
    /// `AVPlayer.preventsDisplaySleepDuringVideoPlayback`.
    let preventsDisplaySleep: Bool
    /// The player layer shows the player's video (`PlayerSurface.rendersVideo`); false: only the audio plays.
    let rendersVideo: Bool

    init(_ conditions: Conditions) {
        self.conditions = conditions
        let showsPlayerScreen = conditions.isPlayerScreenVisible && !conditions.isInBackground
        let isVideoSeen = showsPlayerScreen || conditions.isPictureInPictureActive

        if showsPlayerScreen && !conditions.isPictureInPictureActive {
            timeObserverInterval = Self.visibleTimeObserverInterval
        } else if conditions.isPictureInPictureActive {
            timeObserverInterval = Self.pictureInPictureTimeObserverInterval
        } else {
            timeObserverInterval = Self.hiddenTimeObserverInterval
        }

        var limit = QualityLimit.none
        if conditions.isInBackground && !isVideoSeen {
            // Only the audio is heard: the video is decoded for nobody.
            limit = .lowest
        } else if conditions.isPictureInPictureActive && !showsPlayerScreen {
            limit = .hd720
        }
        switch conditions.thermalState {
        case .critical:
            limit = limit.combined(with: .sd480)
        case .serious:
            limit = limit.combined(with: .hd720)
        default:
            break
        }
        if conditions.isLowPowerModeEnabled {
            limit = limit.combined(with: .hd1080)
        }
        qualityLimit = limit
        preventsDisplaySleep = isVideoSeen
        rendersVideo = conditions.isPlayerPresented || conditions.isPlayerScreenVisible || conditions.isPictureInPictureActive
    }

    /// For the log.
    var summary: String {
        let resolution = qualityLimit.maximumResolution == .zero
            ? "any"
            : "\(Int(qualityLimit.maximumResolution.width))x\(Int(qualityLimit.maximumResolution.height))"
        let bitRate = qualityLimit.peakBitRate == 0 ? "any" : "\(Int(qualityLimit.peakBitRate / 1000)) kb/s"
        return "position every \(timeObserverInterval.seconds) s, quality \(resolution) / \(bitRate), display sleep \(preventsDisplaySleep ? "prevented" : "allowed"), video \(rendersVideo ? "rendered" : "not decoded")"
            + " (low power \(conditions.isLowPowerModeEnabled), thermal \(conditions.thermalState.logName), background \(conditions.isInBackground),"
            + " player screen \(conditions.isPlayerScreenVisible) presented \(conditions.isPlayerPresented), PiP \(conditions.isPictureInPictureActive))"
    }
}
