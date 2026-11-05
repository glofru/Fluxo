//
//  DownloadPreferences.swift
//  Fluxo
//
//  Settings of the offline downloads, stored in `UserDefaults.fluxo`. `DownloadSettingsSection` edits them with
//  @AppStorage using the same keys and defaults; `DownloadCenter` reads them when a transfer starts.
//

import Foundation

enum DownloadPreferences {

    static let allowsCellularKey = "downloads.allowsCellular"
    static let qualityKey = "downloads.quality"
    static let deletesWatchedKey = "downloads.deletesWatched"
    static let downloadsNextEpisodeKey = "downloads.downloadsNextEpisode"

    /// Cellular data is opt-in: videos are large.
    static let defaultAllowsCellular = false
    static let defaultQuality = DownloadQuality.high
    static let defaultDeletesWatched = false
    static let defaultDownloadsNextEpisode = false

    /// Transfers that run at the same time; the others wait in the queue.
    static let maximumConcurrentTransfers = 2
    /// Free space a download always leaves on the device, for the system and the other apps.
    static let freeSpaceMargin: Int64 = 500 * 1024 * 1024

    static var allowsCellular: Bool {
        #if os(iOS)
        bool(allowsCellularKey, default: defaultAllowsCellular)
        #else
        // A Mac has no cellular interface of its own; a tethered iPhone counts as Wi-Fi.
        true
        #endif
    }

    static var quality: DownloadQuality {
        UserDefaults.fluxo.string(forKey: qualityKey).flatMap(DownloadQuality.init(rawValue:)) ?? defaultQuality
    }

    /// Downloads played to the end are deleted once something else plays (or at the next launch).
    static var deletesWatched: Bool {
        bool(deletesWatchedKey, default: defaultDeletesWatched)
    }

    /// Playing a downloaded episode to the end downloads the next one of its series.
    static var downloadsNextEpisode: Bool {
        bool(downloadsNextEpisodeKey, default: defaultDownloadsNextEpisode)
    }

    /// A stored Bool (also "YES" / "NO" from a launch argument), or `defaultValue` when there is none.
    private static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.fluxo
        return defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}
