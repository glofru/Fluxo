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

    static let defaultTimeShiftMinutes = 30
    static let defaultSkipBackwardSeconds = 10
    static let defaultSkipForwardSeconds = 30
    static let defaultAutoPictureInPicture = true
    static let defaultPictureInPictureOnClose = true

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

    private static func value(forKey key: String, default defaultValue: Int, allowed: [Int]) -> Int {
        guard let stored = UserDefaults.fluxo.object(forKey: key) as? Int, allowed.contains(stored) else {
            return defaultValue
        }
        return stored
    }
}
