//
//  SyncDeletionJournal.swift
//  Fluxo
//
//  What the user deleted on purpose, for iCloud sync: only these deletions reach the other devices (see "Data
//  safety" in docs/icloud-sync.md). Compiled by `Tools/SyncCheck` too.
//

import Foundation

/// The deletions the user made on this device, for sync (`CloudSyncLocalStore.deletionIntents()`): written where a
/// playlist or guide source is deleted (`PlaylistImportCenter.delete`, `EPGStore.deleteSource`), by Clear History and
/// where watched items leave the history (`noteHistoryRemoved`), before the row goes, and kept in the defaults until
/// sync folds them, so a playlist or guide deleted while sync is off or just before the app is quit is still deleted
/// on the other devices. Clear History and the removed history count for a day only (`historyIntentLifetime`):
/// removed longer before sync runs, the vanished history is a mass removal the user is asked about. Anything that
/// disappears without an entry here (an emptied or recreated store) is never deleted from the other devices. A
/// deletion that fails withdraws its entry (`withdraw`), so the row it left is never deleted elsewhere if the store
/// is lost later.
enum SyncDeletionJournal {
    static let deletedKey = "sync.deletedLocalIDs"
    static let clearedHistoryKey = "sync.clearedHistoryOn"
    /// Watched items the user removed from the history (`SyncIdentity.localHistoryKey` → when).
    static let removedHistoryKey = "sync.removedHistory"
    /// Clear History, and a removal from the history, allow the removal of that history for this long (the pass
    /// runs seconds later; this covers sync being off, or the app quit before the pass, for a while).
    static let historyIntentLifetime: TimeInterval = 24 * 3_600
    /// The journal keeps the newest deletions only (sync off, it is never folded). One dropped is the safe way: the
    /// playlist is merely gone for sync, kept in iCloud for a restore, and not deleted elsewhere.
    static let capacity = 200
    /// The newest removed watched items kept (a series removed from Continue Watching is one per episode).
    static let historyCapacity = 2_000

    static func noteDeleted(_ localID: UUID, in defaults: UserDefaults = .fluxo) {
        var ids = defaults.stringArray(forKey: deletedKey) ?? []
        let value = localID.uuidString
        guard !ids.contains(value) else {
            return
        }
        ids.append(value)
        defaults.set(Array(ids.suffix(capacity)), forKey: deletedKey)
    }

    /// The deletion of `localID` failed: its row stays, and is not a deletion to publish.
    static func withdraw(_ localID: UUID, in defaults: UserDefaults = .fluxo) {
        forget(SyncDeletionIntents(localIDs: [localID]), in: defaults)
    }

    static func noteHistoryCleared(in defaults: UserDefaults = .fluxo, now: Date = .now) {
        defaults.set(now, forKey: clearedHistoryKey)
    }

    /// The user removed these watched items from the history (`SyncIdentity.localHistoryKey`: Remove from History
    /// on a Continue Watching card, a swipe in the history, a series marked unwatched, Play from Beginning on an
    /// item only started, the app's trim of the history): their removal is published at once, however many there
    /// are (a series with all its episodes), instead of being held as a mass loss. The newest `historyCapacity`
    /// entries are kept.
    static func noteHistoryRemoved(_ keys: some Sequence<String>, in defaults: UserDefaults = .fluxo, now: Date = .now) {
        let keys = Array(keys)
        guard !keys.isEmpty else {
            return
        }
        var entries = removedHistory(in: defaults)
        for key in keys {
            entries[key] = now
        }
        if entries.count > historyCapacity {
            let kept = entries.sorted { $0.value > $1.value }.prefix(historyCapacity)
            entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        defaults.set(entries, forKey: removedHistoryKey)
    }

    /// The item is in the history again before sync folded its removal (watched again, a position saved, an episode
    /// marked watched, another device's record of it applied): its removal is not one to publish if the store is
    /// lost later.
    static func withdrawHistoryRemoval(_ key: String, in defaults: UserDefaults = .fluxo, now: Date = .now) {
        guard defaults.object(forKey: removedHistoryKey) != nil else {
            return
        }
        forget(SyncDeletionIntents(removedHistory: [key]), in: defaults, now: now)
    }

    static func intents(in defaults: UserDefaults, now: Date = .now) -> SyncDeletionIntents {
        let ids = Set((defaults.stringArray(forKey: deletedKey) ?? []).compactMap(UUID.init(uuidString:)))
        let cleared = (defaults.object(forKey: clearedHistoryKey) as? Date).map { now.timeIntervalSince($0) < historyIntentLifetime } ?? false
        let removed = removedHistory(in: defaults).filter { now.timeIntervalSince($0.value) < historyIntentLifetime }
        return SyncDeletionIntents(localIDs: ids, clearedHistory: cleared, removedHistory: Set(removed.keys))
    }

    /// Forgets what sync folded. The removed history it read goes, and so does what expired meanwhile.
    static func forget(_ intents: SyncDeletionIntents, in defaults: UserDefaults, now: Date = .now) {
        if !intents.localIDs.isEmpty {
            let forgotten = Set(intents.localIDs.map(\.uuidString))
            let remaining = (defaults.stringArray(forKey: deletedKey) ?? []).filter { !forgotten.contains($0) }
            if remaining.isEmpty {
                defaults.removeObject(forKey: deletedKey)
            } else {
                defaults.set(remaining, forKey: deletedKey)
            }
        }
        if intents.clearedHistory {
            defaults.removeObject(forKey: clearedHistoryKey)
        }
        if !intents.removedHistory.isEmpty {
            let remaining = removedHistory(in: defaults).filter { key, removedOn in
                !intents.removedHistory.contains(key) && now.timeIntervalSince(removedOn) < historyIntentLifetime
            }
            if remaining.isEmpty {
                defaults.removeObject(forKey: removedHistoryKey)
            } else {
                defaults.set(remaining, forKey: removedHistoryKey)
            }
        }
    }

    private static func removedHistory(in defaults: UserDefaults) -> [String: Date] {
        (defaults.dictionary(forKey: removedHistoryKey) as? [String: Date]) ?? [:]
    }
}
