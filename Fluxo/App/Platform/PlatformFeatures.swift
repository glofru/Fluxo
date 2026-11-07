//
//  PlatformFeatures.swift
//  Fluxo
//
//  What each platform can do, in one place. Shared code asks for a capability ("can this device keep downloads?")
//  instead of testing the operating system, so iPhone, iPad, Mac and Apple TV run the same code paths and a feature
//  that a platform lacks is turned off here, with the reason, rather than in every screen that offers it.
//
//  The APIs a capability stands for are still compiled out where the SDK marks them unavailable (the `#if os(tvOS)`
//  next to them), but only in the file that calls them; everything above that asks this type.
//

import Foundation

enum PlatformFeatures {

    /// Offline downloads of movies and episodes. Not on Apple TV: tvOS keeps only a small amount of an app's data
    /// for sure, and everything else is a cache the system deletes when it needs space (even between two launches),
    /// so a downloaded movie could be gone the evening it is watched. `AVAssetDownloadURLSession` (HLS downloads) and
    /// the storage priorities that protect them do not exist on tvOS either. The Apple TV streams instead.
    static let offlineDownloads: Bool = {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }()

    /// A system clipboard, for Copy Link. Apple TV has none (`UIPasteboard` is unavailable on tvOS).
    static let pasteboard: Bool = {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }()

    /// Notifications with a title and text (programme reminders). On tvOS an app's notifications can only badge its
    /// icon (`UNMutableNotificationContent` has no title or body there): reminders show as an alert in the app while
    /// it runs instead (`ReminderDelivery`).
    static let textNotifications: Bool = {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }()

    /// The on-device Apple Intelligence model (Foundation Models' `SystemLanguageModel`), unavailable on tvOS. Every
    /// feature built on it has a deterministic fallback (see `FluxoIntelligence`), which Apple TV always uses.
    static let onDeviceLanguageModel: Bool = {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }()

    /// Opening files from the Files app (subtitle files) and dropping links and files on the window. Apple TV has no
    /// Files app, document picker or drag and drop.
    static let files: Bool = {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }()

    /// Spotlight indexing of channels (`IndexedEntity`, `CSSearchableIndex`): unavailable on tvOS, whose search does
    /// not list app content. Siri phrases with channel names still update there (`updateAppShortcutParameters()`).
    static let spotlightIndexing: Bool = {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }()
}

/// Where the app keeps the files the user makes (recordings).
enum PlatformStorage {

    /// Documents on iPhone, iPad and Mac (never purged; out of the backups, `RecordingStore`; not shown in the Files
    /// app: recordings play only in Fluxo, `UIFileSharingEnabled` is off). Apple TV has no Documents folder
    /// for apps: Caches there, which the system may empty when it runs out of space (tvOS has no other place for large
    /// files; see `PlatformFeatures.offlineDownloads`).
    static var userFilesDirectory: URL {
        #if os(tvOS)
        let directory: FileManager.SearchPathDirectory = .cachesDirectory
        #else
        let directory: FileManager.SearchPathDirectory = .documentDirectory
        #endif
        return FileManager.default.urls(for: directory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    /// The free space of the volume of `url` (of the temporary folder while `url` does not exist yet), in bytes, or
    /// nil when it is unknown. On iPhone, iPad and Mac the capacity "for important usage", which counts the space the
    /// system would free for what the user asked for; tvOS has only the plain free space.
    static func availableCapacity(at url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : FileManager.default.temporaryDirectory
        #if os(tvOS)
        let capacity = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
        #else
        let capacity = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        #endif
        guard let capacity, capacity > 0 else {
            return nil
        }
        return capacity
    }
}
