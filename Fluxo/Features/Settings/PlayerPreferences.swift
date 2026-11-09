//
//  PlayerPreferences.swift
//  Fluxo
//
//  User settings of the player, stored in `UserDefaults.fluxo`. SettingsView edits them with @AppStorage
//  using the same keys and defaults; the player reads them when a channel starts.
//

import Foundation

enum PlayerPreferences {

    static let timeShiftMinutesKey = "player.timeShiftMinutes"
    static let skipBackwardSecondsKey = "player.skipBackwardSeconds"
    static let skipForwardSecondsKey = "player.skipForwardSeconds"
    static let autoPictureInPictureKey = "player.autoPictureInPicture"
    static let pictureInPictureOnCloseKey = "player.pictureInPictureOnClose"
    static let legacyNetworkingKey = "player.legacyNetworking"

    static let defaultTimeShiftMinutes = 30
    static let defaultSkipBackwardSeconds = 10
    static let defaultSkipForwardSeconds = 30
    static let defaultAutoPictureInPicture = true
    static let defaultPictureInPictureOnClose = true
    static let defaultLegacyNetworking = false

    /// Lengths offered for the live time-shift (DVR) window, in minutes. There is no "off": a window of 0
    /// means "keep everything" for the engine.
    static let timeShiftChoices = [5, 15, 30, 60, 120]
    /// Skip intervals offered, in seconds. Each has a matching `gobackward.N` / `goforward.N` SF Symbol.
    static let skipChoices = [5, 10, 15, 30, 60]

    /// Disk budget of 30 minutes of time-shift; longer windows scale it. The player still caps it to a tenth
    /// of the free space.
    private static let bytesPerHalfHour: Int64 = 512 * 1024 * 1024

    static var timeShiftMinutes: Int {
        value(forKey: timeShiftMinutesKey, default: defaultTimeShiftMinutes, allowed: timeShiftChoices)
    }

    static var timeShiftDuration: TimeInterval {
        TimeInterval(timeShiftMinutes * 60)
    }

    static var timeShiftBytes: Int64 {
        max(128 * 1024 * 1024, bytesPerHalfHour * Int64(timeShiftMinutes) / 30)
    }

    static var skipBackwardInterval: TimeInterval {
        TimeInterval(value(forKey: skipBackwardSecondsKey, default: defaultSkipBackwardSeconds, allowed: skipChoices))
    }

    static var skipForwardInterval: TimeInterval {
        TimeInterval(value(forKey: skipForwardSecondsKey, default: defaultSkipForwardSeconds, allowed: skipChoices))
    }

    static var autoPictureInPicture: Bool {
        UserDefaults.fluxo.object(forKey: autoPictureInPictureKey) as? Bool ?? defaultAutoPictureInPicture
    }

    /// iOS: closing the player screen (its chevron or a swipe down) keeps the video playing in Picture in Picture.
    static var pictureInPictureOnClose: Bool {
        UserDefaults.fluxo.object(forKey: pictureInPictureOnCloseKey) as? Bool ?? defaultPictureInPictureOnClose
    }

    /// The streams the remux engine opens are read with FFmpeg's own network code, as in earlier versions, instead of
    /// the system's (`StreamRemuxer.Configuration.HTTPInput`): for a server that only works with it. Off by default.
    static var legacyNetworking: Bool {
        UserDefaults.fluxo.object(forKey: legacyNetworkingKey) as? Bool ?? defaultLegacyNetworking
    }

    /// The title of the setting, in Settings on every platform.
    static var legacyNetworkingTitle: String {
        String(localized: "Legacy Networking", comment: "Settings, Playback: a switch that makes streams connect with the network code of earlier versions of the app, for servers that stopped working after an update.")
    }

    /// What the setting does, under the Playback section.
    static var legacyNetworkingFooter: String {
        String(localized: "Turn on Legacy Networking only if a server stopped working after an update: the streams Fluxo converts itself, such as MPEG-TS channels and MKV movies, then connect as in earlier versions, without TLS 1.3, HTTP/2 or the system's proxy settings. Applies the next time a stream starts.", comment: "Settings, Playback footer: what the Legacy Networking switch does. TLS 1.3 and HTTP/2 are network protocol names; keep them.")
    }

    private static func value(forKey key: String, default defaultValue: Int, allowed: [Int]) -> Int {
        guard let stored = UserDefaults.fluxo.object(forKey: key) as? Int, allowed.contains(stored) else {
            return defaultValue
        }
        return stored
    }
}
