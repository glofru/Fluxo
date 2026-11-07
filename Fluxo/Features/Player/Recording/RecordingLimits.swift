//
//  RecordingLimits.swift
//  Fluxo
//
//  What keeps a recording from filling the device: it does not start without some free space, it stops (keeping what
//  it recorded) when the device is nearly full, and it stops at the length set in Settings › Recordings (4 hours unless
//  changed, so a recording that was forgotten does not run all night). `AVPlayerViewModel` applies them.
//

import Foundation

enum RecordingLimits {

    /// `UserDefaults.fluxo`: the longest recording, in minutes (0: no limit).
    static let maximumMinutesKey = "recordings.maximumMinutes"
    static let defaultMaximumMinutes = 240
    /// The choices of Settings (0 is No Limit, last).
    static let maximumMinutesChoices = [30, 60, 120, 180, 240, 360, 0]

    /// A recording does not start with less free space than this.
    static let minimumFreeSpaceToStart: Int64 = 1024 * 1024 * 1024
    /// A recording stops when the free space falls below this, so the device keeps room for everything else.
    static let minimumFreeSpaceWhileRecording: Int64 = 512 * 1024 * 1024
    /// How often the free space is checked while recording (recording time).
    static let freeSpaceCheckInterval: TimeInterval = 10

    #if DEBUG
    /// Debug harness (`recording-limit:`): a limit in seconds instead of the setting.
    @MainActor static var debugMaximumDuration: TimeInterval?
    #endif

    /// The length at which a recording stops; nil for no limit.
    @MainActor
    static var maximumDuration: TimeInterval? {
        #if DEBUG
        if let debugMaximumDuration {
            return debugMaximumDuration
        }
        #endif
        let minutes = UserDefaults.fluxo.object(forKey: maximumMinutesKey) as? Int ?? defaultMaximumMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    /// "4 hours", "30 minutes", "No Limit": a choice of the setting.
    static func title(minutes: Int) -> String {
        guard minutes > 0 else {
            return String(localized: "No Limit", comment: "Settings, Recordings: the choice of Stop Recording After that never stops a recording on its own.")
        }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    static var notEnoughSpaceToStartMessage: String {
        String(localized: "There isn't enough free space to record. Free up space on this device, then try again.", comment: "Player message: a recording cannot start because the device is almost full.")
    }

    static var stoppedForSpaceMessage: String {
        String(localized: "Recording stopped because this device is almost full. What was recorded is saved.", comment: "Player message: a recording was stopped because the device ran low on free space; the part already recorded is kept.")
    }

    static func stoppedAtLimitMessage(duration: TimeInterval) -> String {
        let length = Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        return String(localized: "Recording stopped after \(length), the limit set in Settings. What was recorded is saved.", comment: "Player message: a recording reached the maximum length set in Settings (Recordings › Stop Recording After); the placeholder is that length, such as 4 hours.")
    }
}
