//
//  SyncDeletionJournal.swift
//  Fluxo
//
//  What the user deleted on purpose, for iCloud sync: only these deletions reach the other devices (see "Data
//  safety" under "iCloud sync" in the README). Compiled by `Tools/SyncCheck` too.
//

import Foundation

/// The deletions the user made on this device, for sync (`CloudSyncLocalStore.deletionIntents()`): written where a
/// playlist or guide source is deleted (`PlaylistImportCenter.delete`, `EPGStore.deleteSource`) and by Clear History,
/// before the row goes, and kept in the defaults until sync folds them, so a playlist or guide deleted while sync is
/// off or just before the app is quit is still deleted on the other devices. Clear History counts for a day only
/// (`clearedHistoryLifetime`): cleared longer before sync runs, the vanished history is a mass removal the user is
/// asked about. Anything that disappears without an entry here (an emptied or recreated store) is never deleted from
/// the other devices. A deletion that fails withdraws its entry (`withdraw`), so the row it left is never deleted
/// elsewhere if the store is lost later.
enum SyncDeletionJournal {
    static let deletedKey = "sync.deletedLocalIDs"
    static let clearedHistoryKey = "sync.clearedHistoryOn"
    /// Clear History allows the removal of the whole history for this long (the pass runs seconds later).
    static let clearedHistoryLifetime: TimeInterval = 24 * 3_600
    /// The journal keeps the newest deletions only (sync off, it is never folded). One dropped is the safe way: the
    /// playlist is merely gone for sync, kept in iCloud for a restore, and not deleted elsewhere.
    static let capacity = 200

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
        forget(SyncDeletionIntents(localIDs: [localID], clearedHistory: false), in: defaults)
    }

    static func noteHistoryCleared(in defaults: UserDefaults = .fluxo, now: Date = .now) {
        defaults.set(now, forKey: clearedHistoryKey)
    }

    static func intents(in defaults: UserDefaults, now: Date = .now) -> SyncDeletionIntents {
        let ids = Set((defaults.stringArray(forKey: deletedKey) ?? []).compactMap(UUID.init(uuidString:)))
        let cleared = (defaults.object(forKey: clearedHistoryKey) as? Date).map { now.timeIntervalSince($0) < clearedHistoryLifetime } ?? false
        return SyncDeletionIntents(localIDs: ids, clearedHistory: cleared)
    }

    static func forget(_ intents: SyncDeletionIntents, in defaults: UserDefaults) {
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
    }
}
