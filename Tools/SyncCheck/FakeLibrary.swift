//
//  FakeLibrary.swift
//  SyncCheck
//
//  An in-memory library with the behavior of `LibrarySyncStore` (Fluxo/App/Sync/LibrarySyncStore.swift) that matters
//  to sync: playlists are published once imported, favorites and progress belong to a synced playlist, a playlist of
//  another device waits for the user's go-ahead, deleting a playlist deletes its bookmarks, settings are plain values.
//  The user's deletions go through the app's own `SyncDeletionJournal`, in defaults of this device only;
//  `loseEverything()` and the other `lose…` methods empty the library without a word, as a store recreated after it
//  could not be opened does.
//

import Foundation

@MainActor
final class FakeLibrary: CloudSyncLocalStore {

    struct Playlist: Equatable {
        var name: String
        var url: URL
        var createdOn: Date
        /// The first import finished (a playlist being added is not published yet).
        var isImported: Bool
    }

    struct Bookmark: Equatable {
        var playlistID: UUID
        var url: URL
        var name: String
        var isFavorite = false
        var favoritedOn: Date?
        var order: Double = 0
        var lastWatchedAt: Date?
        var watchCount = 0
        var resumePosition: Double = 0
        var knownDuration: Double = 0
    }

    /// What a series knows of what was watched (`SeriesBookmark`): one `.seriesProgress` record.
    struct Series: Equatable {
        var playlistID: UUID
        var seriesKey: String
        var title: String
        var lastWatchedAt: Date?
        var lastEpisodeURL: URL?
        var watchedEpisodeCodes: [String] = []
    }

    struct Guide: Equatable {
        var name: String
        var url: URL
        var isEnabled: Bool
        var addedOn: Date
    }

    let label: String
    var playlists: [UUID: Playlist] = [:]
    var guides: [UUID: Guide] = [:]
    /// By "<playlist uuid>|<url>", like `ChannelBookmark.key`.
    var bookmarks: [String: Bookmark] = [:]
    /// By "<playlist uuid>|<series key>", like `SeriesBookmark.key`.
    var series: [String: Series] = [:]
    var preferences: [String: PreferenceValue] = [:]
    /// First run: playlists of other devices wait until the user adds them.
    var acceptsCloudPlaylists = true
    var declined: Set<String> = []
    var clock: () -> Date
    /// The defaults `SyncDeletionJournal` keeps this device's deletions in (removed when the check ends).
    let defaults: UserDefaults
    static private(set) var suiteNames: [String] = []

    init(label: String, clock: @escaping () -> Date) {
        self.label = label
        self.clock = clock
        let suite = "dev.watermelon.Fluxo.SyncCheck.\(label).\(UUID().uuidString)"
        Self.suiteNames.append(suite)
        defaults = UserDefaults(suiteName: suite)!
    }

    /// Removes the defaults of every fake library.
    static func removeDefaults() {
        for suite in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        suiteNames = []
    }

    /// What the journal holds now.
    var journal: SyncDeletionIntents {
        SyncDeletionJournal.intents(in: defaults, now: clock())
    }

    // MARK: User actions

    @discardableResult
    func addPlaylist(_ name: String, _ address: String) -> UUID {
        let id = UUID()
        playlists[id] = Playlist(name: name, url: URL(string: address)!, createdOn: clock().syncRounded, isImported: true)
        return id
    }

    func playlist(named name: String) -> UUID? {
        playlists.first { $0.value.name == name }?.key
    }

    /// The user deletes a playlist (Delete Playlist), as `PlaylistImportCenter.delete` does.
    func deletePlaylist(_ id: UUID) {
        SyncDeletionJournal.noteDeleted(id, in: defaults)
        removePlaylist(id)
    }

    /// The user deletes a playlist, and the deletion fails (the store refuses the save): the row stays, and
    /// `PlaylistImportCenter.delete` withdraws the journal entry.
    func failToDeletePlaylist(_ id: UUID) {
        SyncDeletionJournal.noteDeleted(id, in: defaults)
        SyncDeletionJournal.withdraw(id, in: defaults)
    }

    /// The user deletes a guide.
    func deleteGuide(_ id: UUID) {
        SyncDeletionJournal.noteDeleted(id, in: defaults)
        guides[id] = nil
    }

    /// Clear History.
    func clearHistory() {
        SyncDeletionJournal.noteHistoryCleared(in: defaults, now: clock())
        series = [:]
        for key in bookmarks.keys {
            bookmarks[key]?.lastWatchedAt = nil
            bookmarks[key]?.resumePosition = 0
            if bookmarks[key]?.isFavorite == false {
                bookmarks[key] = nil
            }
        }
    }

    /// The store could not be opened and was recreated empty (the settings, in the defaults, stay).
    func loseEverything() {
        playlists = [:]
        guides = [:]
        bookmarks = [:]
        series = [:]
    }

    /// The favorites vanish (playlists stay), without the user removing them.
    func loseFavorites() {
        for key in bookmarks.keys {
            bookmarks[key]?.isFavorite = false
            bookmarks[key]?.favoritedOn = nil
            if bookmarks[key]?.lastWatchedAt == nil {
                bookmarks[key] = nil
            }
        }
    }

    /// The watch history vanishes (playlists and favorites stay), without Clear History.
    func loseHistory() {
        series = [:]
        for key in bookmarks.keys {
            bookmarks[key]?.lastWatchedAt = nil
            bookmarks[key]?.resumePosition = 0
            if bookmarks[key]?.isFavorite == false {
                bookmarks[key] = nil
            }
        }
    }

    private func removePlaylist(_ id: UUID) {
        playlists[id] = nil
        bookmarks = bookmarks.filter { $0.value.playlistID != id }
        series = series.filter { $0.value.playlistID != id }
    }

    var favoriteCount: Int {
        bookmarks.values.filter(\.isFavorite).count
    }

    var historyCount: Int {
        bookmarks.values.filter { $0.lastWatchedAt != nil }.count
    }

    /// Series with a watch state (`.seriesProgress` records).
    var seriesHistoryCount: Int {
        series.count
    }

    static func channelURL(_ channel: String) -> URL {
        URL(string: "http://provider.example/live/user/pass/")!.appendingPathComponent(channel)
    }

    /// The user removes one entry of the history (a swipe in the history, Remove from History on a movie's
    /// Continue Watching card), as `ChannelLibrary.removeFromHistory(_ item:)` does.
    func removeFromHistory(_ channel: String, in playlistID: UUID) {
        let url = Self.channelURL(channel)
        let key = "\(playlistID)|\(url)"
        guard bookmarks[key] != nil else {
            return
        }
        SyncDeletionJournal.noteHistoryRemoved([SyncIdentity.localHistoryKey(playlistID: playlistID, url: url)], in: defaults, now: clock())
        bookmarks[key]?.lastWatchedAt = nil
        bookmarks[key]?.resumePosition = 0
        if bookmarks[key]?.isFavorite == false {
            bookmarks[key] = nil
        }
    }

    /// The channel name of an episode of a series ("Show E3").
    static func episode(_ number: Int, of show: String) -> String {
        "\(show) E\(number)"
    }

    /// An episode of a series is watched: its own progress, and the series' last episode and watched episodes.
    func watchEpisode(_ number: Int, of show: String, in playlistID: UUID, position: Double = 0, duration: Double = 2_400) {
        let channel = Self.episode(number, of: show)
        watch(channel, in: playlistID, position: position, duration: duration)
        let key = "\(playlistID)|\(show)"
        var value = series[key] ?? Series(playlistID: playlistID, seriesKey: show, title: show)
        value.lastWatchedAt = clock().syncRounded
        value.lastEpisodeURL = Self.channelURL(channel)
        value.watchedEpisodeCodes = Array(Set(value.watchedEpisodeCodes + ["S1E\(number)"])).sorted()
        series[key] = value
    }

    /// "Remove from History" on a series' Continue Watching card, as `ChannelLibrary.removeFromHistory(_ series:)`
    /// and `SeriesLibrary.forgetHistory(of:)` do: every episode watched, and what the series knows of them.
    func removeSeriesFromHistory(_ show: String, in playlistID: UUID) {
        let prefix = Self.channelURL(show + " E").absoluteString
        var removed: [String] = []
        for (key, bookmark) in bookmarks where bookmark.playlistID == playlistID && bookmark.url.absoluteString.hasPrefix(prefix) {
            guard bookmark.lastWatchedAt != nil || bookmark.resumePosition > 0 else {
                continue
            }
            removed.append(key)
        }
        SyncDeletionJournal.noteHistoryRemoved(
            removed.compactMap { bookmarks[$0].map { SyncIdentity.localHistoryKey(playlistID: playlistID, url: $0.url) } }
                + [SyncIdentity.localHistoryKey(playlistID: playlistID, seriesKey: show)],
            in: defaults,
            now: clock()
        )
        for key in removed {
            bookmarks[key]?.lastWatchedAt = nil
            bookmarks[key]?.resumePosition = 0
            if bookmarks[key]?.isFavorite == false {
                bookmarks[key] = nil
            }
        }
        series["\(playlistID)|\(show)"] = nil
    }

    func favorite(_ channel: String, in playlistID: UUID) {
        let url = Self.channelURL(channel)
        let key = "\(playlistID)|\(url)"
        var bookmark = bookmarks[key] ?? Bookmark(playlistID: playlistID, url: url, name: channel)
        bookmark.isFavorite = true
        bookmark.favoritedOn = clock().syncRounded
        bookmark.order = -clock().timeIntervalSinceReferenceDate
        bookmarks[key] = bookmark
    }

    func unfavorite(_ channel: String, in playlistID: UUID) {
        let key = "\(playlistID)|\(Self.channelURL(channel))"
        bookmarks[key]?.isFavorite = false
        bookmarks[key]?.favoritedOn = nil
        if let bookmark = bookmarks[key], !bookmark.isFavorite, bookmark.lastWatchedAt == nil {
            bookmarks[key] = nil
        }
    }

    func watch(_ channel: String, in playlistID: UUID, position: Double, duration: Double) {
        let url = Self.channelURL(channel)
        let key = "\(playlistID)|\(url)"
        // As `ChannelLibrary.recordWatch`: back in the history, so not a removal to publish.
        SyncDeletionJournal.withdrawHistoryRemoval(SyncIdentity.localHistoryKey(playlistID: playlistID, url: url), in: defaults, now: clock())
        var bookmark = bookmarks[key] ?? Bookmark(playlistID: playlistID, url: url, name: channel)
        bookmark.lastWatchedAt = clock().syncRounded
        bookmark.watchCount += 1
        bookmark.resumePosition = position
        bookmark.knownDuration = duration
        bookmarks[key] = bookmark
    }

    /// A position saved without a new watch, as `ChannelLibrary.saveWatchProgress` does (the player's saves, a
    /// pause; Play from Beginning saves 0): an item with progress again withdraws its removal from the journal, and
    /// a reset that leaves it without any (only started, never in the history) is journaled as the user's removal.
    func saveProgress(_ channel: String, in playlistID: UUID, position: Double, duration: Double = 6_000) {
        let url = Self.channelURL(channel)
        let key = "\(playlistID)|\(url)"
        let historyKey = SyncIdentity.localHistoryKey(playlistID: playlistID, url: url)
        guard var bookmark = bookmarks[key] ?? (position > 0 ? Bookmark(playlistID: playlistID, url: url, name: channel) : nil) else {
            return
        }
        let hadProgress = bookmark.lastWatchedAt != nil || bookmark.resumePosition > 0
        bookmark.resumePosition = max(0, position)
        bookmark.knownDuration = duration
        if bookmark.lastWatchedAt != nil || bookmark.resumePosition > 0 {
            SyncDeletionJournal.withdrawHistoryRemoval(historyKey, in: defaults, now: clock())
            bookmarks[key] = bookmark
            return
        }
        if hadProgress {
            SyncDeletionJournal.noteHistoryRemoved([historyKey], in: defaults, now: clock())
        }
        bookmarks[key] = bookmark.isFavorite ? bookmark : nil
    }

    /// Marks an episode of a series as watched or not, as `SeriesLibrary.setWatched` does: a series left without a
    /// watch state is journaled as removed; one that has a state again withdraws its removal.
    func setEpisodeWatched(_ number: Int, of show: String, in playlistID: UUID, watched: Bool) {
        let key = "\(playlistID)|\(show)"
        let historyKey = SyncIdentity.localHistoryKey(playlistID: playlistID, seriesKey: show)
        var value = series[key] ?? Series(playlistID: playlistID, seriesKey: show, title: show)
        var codes = Set(value.watchedEpisodeCodes)
        if watched {
            codes.insert("S1E\(number)")
        } else {
            codes.remove("S1E\(number)")
        }
        value.watchedEpisodeCodes = codes.sorted()
        if value.lastWatchedAt == nil && value.lastEpisodeURL == nil && value.watchedEpisodeCodes.isEmpty {
            SyncDeletionJournal.noteHistoryRemoved([historyKey], in: defaults, now: clock())
            series[key] = nil
        } else {
            SyncDeletionJournal.withdrawHistoryRemoval(historyKey, in: defaults, now: clock())
            series[key] = value
        }
    }

    func bookmark(_ channel: String, in playlistID: UUID?) -> Bookmark? {
        guard let playlistID else {
            return nil
        }
        return bookmarks["\(playlistID)|\(Self.channelURL(channel))"]
    }

    // MARK: CloudSyncLocalStore

    func snapshot(identity: inout SyncIdentityResolver) throws -> [SyncRecordID: SyncPayload] {
        var result: [SyncRecordID: SyncPayload] = [:]
        identity.setPresent(playlists: Set(playlists.keys), guideSources: Set(guides.keys))
        for (id, playlist) in playlists.sorted(by: { $0.value.createdOn < $1.value.createdOn }) {
            guard identity.linkedPlaylistName(localID: id) != nil || playlist.isImported else {
                continue
            }
            let name = identity.playlistName(localID: id, url: playlist.url)
            result[SyncRecordID(.playlist, name)] = .playlist(PlaylistPayload(name: playlist.name, url: playlist.url, createdOn: playlist.createdOn))
        }
        for (id, guide) in guides {
            let name = identity.guideSourceName(localID: id, url: guide.url)
            result[SyncRecordID(.guideSource, name)] = .guideSource(GuideSourcePayload(name: guide.name, url: guide.url, isEnabled: guide.isEnabled, addedOn: guide.addedOn))
        }
        for bookmark in bookmarks.values {
            guard let playlist = identity.linkedPlaylistName(localID: bookmark.playlistID) else {
                continue
            }
            let channel = ChannelSnapshot(playlist: playlist, url: bookmark.url, name: bookmark.name, logo: nil, groupName: "", kind: 0, tvgID: nil, episode: nil)
            let name = SyncIdentity.channelName(playlist: playlist, url: bookmark.url)
            if bookmark.isFavorite {
                result[SyncRecordID(.channelFavorite, name)] = .channelFavorite(ChannelFavoritePayload(channel: channel, favoritedOn: bookmark.favoritedOn, order: bookmark.order))
            }
            if bookmark.lastWatchedAt != nil || bookmark.resumePosition > 0 {
                result[SyncRecordID(.channelProgress, name)] = .channelProgress(ChannelProgressPayload(channel: channel, lastWatchedAt: bookmark.lastWatchedAt, watchCount: bookmark.watchCount, resumePosition: bookmark.resumePosition, knownDuration: bookmark.knownDuration))
            }
        }
        for value in series.values {
            guard let playlist = identity.linkedPlaylistName(localID: value.playlistID) else {
                continue
            }
            let snapshot = SeriesSnapshot(playlist: playlist, seriesKey: value.seriesKey, title: value.title, artwork: nil, groupName: "")
            result[SyncRecordID(.seriesProgress, SyncIdentity.seriesName(playlist: playlist, seriesKey: value.seriesKey))] = .seriesProgress(SeriesProgressPayload(
                series: snapshot,
                lastWatchedAt: value.lastWatchedAt,
                lastEpisodeURL: value.lastEpisodeURL,
                lastSeason: nil,
                lastEpisode: nil,
                watchedEpisodeCodes: value.watchedEpisodeCodes
            ))
        }
        for (key, value) in preferences {
            result[SyncRecordID(.preference, key)] = .preference(value)
        }
        return result
    }

    func apply(_ records: [SyncRecord], links: inout SyncLinks) async -> Set<SyncRecordID> {
        var deferred: Set<SyncRecordID> = []
        for record in records {
            let name = record.id.name
            switch record.payload {
            case .playlist(let payload):
                var local = links.playlists[name].flatMap { playlists[$0] != nil ? $0 : nil }
                if local == nil {
                    let linked = Set(links.playlists.values)
                    local = playlists.first { !linked.contains($0.key) && SyncIdentity.normalized($0.value.url) == SyncIdentity.normalized(payload.url) }?.key
                }
                if let local {
                    links.playlists[name] = local
                    playlists[local]?.name = payload.name
                    playlists[local]?.url = payload.url
                } else if acceptsCloudPlaylists && !declined.contains(name) {
                    let id = UUID()
                    playlists[id] = Playlist(name: payload.name, url: payload.url, createdOn: payload.createdOn, isImported: false)
                    links.playlists[name] = id
                } else {
                    deferred.insert(record.id)
                }
            case nil where record.id.kind == .playlist:
                if let local = links.playlists[name] {
                    // As `LibrarySyncStore` does: through the app's own deletion, which journals it.
                    deletePlaylist(local)
                }
                links.playlists[name] = nil
            case .guideSource(let payload):
                if let local = links.guideSources[name], guides[local] != nil {
                    guides[local]?.name = payload.name
                    guides[local]?.isEnabled = payload.isEnabled
                } else if acceptsCloudPlaylists {
                    let id = UUID()
                    guides[id] = Guide(name: payload.name, url: payload.url, isEnabled: payload.isEnabled, addedOn: payload.addedOn)
                    links.guideSources[name] = id
                } else {
                    deferred.insert(record.id)
                }
            case nil where record.id.kind == .guideSource:
                if let local = links.guideSources[name] {
                    deleteGuide(local)
                }
                links.guideSources[name] = nil
            case .channelFavorite(let favorite):
                guard let playlistID = links.playlists[favorite.channel.playlist], playlists[playlistID] != nil else {
                    deferred.insert(record.id)
                    continue
                }
                let key = "\(playlistID)|\(favorite.channel.url)"
                var bookmark = bookmarks[key] ?? Bookmark(playlistID: playlistID, url: favorite.channel.url, name: favorite.channel.name ?? "")
                bookmark.isFavorite = true
                bookmark.favoritedOn = favorite.favoritedOn
                bookmark.order = favorite.order
                bookmarks[key] = bookmark
            case .channelProgress(let progress):
                guard let playlistID = links.playlists[progress.channel.playlist], playlists[playlistID] != nil else {
                    deferred.insert(record.id)
                    continue
                }
                let key = "\(playlistID)|\(progress.channel.url)"
                var bookmark = bookmarks[key] ?? Bookmark(playlistID: playlistID, url: progress.channel.url, name: progress.channel.name ?? "")
                bookmark.lastWatchedAt = progress.lastWatchedAt
                bookmark.watchCount = progress.watchCount
                bookmark.resumePosition = progress.resumePosition
                bookmark.knownDuration = progress.knownDuration
                bookmarks[key] = bookmark
                // As `LibrarySyncStore`: watched again on another device, so back in the history here.
                SyncDeletionJournal.withdrawHistoryRemoval(SyncIdentity.localHistoryKey(playlistID: playlistID, url: progress.channel.url), in: defaults, now: clock())
            case nil where record.id.kind == .channelFavorite || record.id.kind == .channelProgress:
                let playlistNames = Dictionary(links.playlists.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
                guard let (key, _) = bookmarks.first(where: { entry in
                    playlistNames[entry.value.playlistID].map { SyncIdentity.channelName(playlist: $0, url: entry.value.url) } == name
                }) else {
                    continue
                }
                if record.id.kind == .channelFavorite {
                    bookmarks[key]?.isFavorite = false
                    bookmarks[key]?.favoritedOn = nil
                } else {
                    bookmarks[key]?.lastWatchedAt = nil
                    bookmarks[key]?.resumePosition = 0
                }
                if let bookmark = bookmarks[key], !bookmark.isFavorite, bookmark.lastWatchedAt == nil {
                    bookmarks[key] = nil
                }
            case .seriesProgress(let progress):
                guard let playlistID = links.playlists[progress.series.playlist], playlists[playlistID] != nil else {
                    deferred.insert(record.id)
                    continue
                }
                series["\(playlistID)|\(progress.series.seriesKey)"] = Series(
                    playlistID: playlistID,
                    seriesKey: progress.series.seriesKey,
                    title: progress.series.title,
                    lastWatchedAt: progress.lastWatchedAt,
                    lastEpisodeURL: progress.lastEpisodeURL,
                    watchedEpisodeCodes: progress.watchedEpisodeCodes
                )
                SyncDeletionJournal.withdrawHistoryRemoval(SyncIdentity.localHistoryKey(playlistID: playlistID, seriesKey: progress.series.seriesKey), in: defaults, now: clock())
            case nil where record.id.kind == .seriesProgress:
                let playlistNames = Dictionary(links.playlists.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
                series = series.filter { _, value in
                    playlistNames[value.playlistID].map { SyncIdentity.seriesName(playlist: $0, seriesKey: value.seriesKey) } != name
                }
            case .preference(let value):
                preferences[name] = value
            case nil where record.id.kind == .preference:
                preferences[name] = nil
            default:
                deferred.insert(record.id)
            }
        }
        return deferred
    }

    func deletionIntents() -> SyncDeletionIntents {
        journal
    }

    func forgetDeletionIntents(_ intents: SyncDeletionIntents) {
        SyncDeletionJournal.forget(intents, in: defaults, now: clock())
    }

    /// The import of playlists added from another device finishes.
    func finishImports() {
        for id in playlists.keys {
            playlists[id]?.isImported = true
        }
    }

    /// What two devices must agree on: playlists by name and address, favorites and progress by playlist name and
    /// channel, guides, settings.
    var comparable: String {
        let names = Dictionary(playlists.map { ($0.key, $0.value.name) }, uniquingKeysWith: { first, _ in first })
        let lists = playlists.values.map { "\($0.name)=\($0.url.absoluteString)" }.sorted()
        let marks = bookmarks.values.map { mark in
            "\(names[mark.playlistID] ?? "?")/\(mark.name) fav=\(mark.isFavorite ? "yes, order \(mark.order)" : "no") watched=\(mark.lastWatchedAt.map { "\($0.syncMilliseconds)" } ?? "-") pos=\(mark.resumePosition)"
        }.sorted()
        let shows = series.values.map { "\(names[$0.playlistID] ?? "?")/\($0.seriesKey) watched=\($0.watchedEpisodeCodes)" }.sorted()
        let guideList = guides.values.map { "\($0.name) on=\($0.isEnabled)" }.sorted()
        let prefs = preferences.map { "\($0.key)=\($0.value)" }.sorted()
        return (lists + marks + shows + guideList + prefs).joined(separator: "\n")
    }
}
