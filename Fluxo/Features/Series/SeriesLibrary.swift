//
//  SeriesLibrary.swift
//  Fluxo
//
//  Favorite series, the episode watched last and the episodes watched, stored as `SeriesBookmark`s in the main
//  context. Owned by `ChannelLibrary` (`library.series`), which tells it when an episode starts or ends; the
//  resume position of each episode stays a `ChannelBookmark` like any movie's.
//

import Foundation
import Observation
import os
import SwiftData

@MainActor
@Observable
final class SeriesLibrary {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Series")

    private(set) var favoriteKeys: Set<String> = []
    /// Watch state of every series the viewer started, by `SeriesItem.bookmarkKey`. Small: one entry per series
    /// watched, so cards read it without a fetch of their own.
    private(set) var states: [String: SeriesWatchState] = [:]
    /// Bumped on every user toggle of a series favorite (haptics).
    private(set) var favoriteToggleCount = 0
    /// Counts and artwork of the series that cards built from an episode know nothing of (category rows and
    /// grids list the first episode of each series), by `SeriesItem.bookmarkKey`. Filled on demand by
    /// `loadSummary(of:)`, a screen's cards in one fetch.
    private(set) var summaries: [String: SeriesItem] = [:]
    /// Bumped when the summaries are dropped (a refresh or the launch backfill changed the series), so cards ask
    /// again.
    private(set) var summaryRevision = 0

    @ObservationIgnored
    private let context: ModelContext
    @ObservationIgnored
    private var indexObserver: (any NSObjectProtocol)?
    @ObservationIgnored
    private var requestedSummaries: Set<String> = []
    @ObservationIgnored
    private var pendingSummaries: [SeriesItem] = []
    @ObservationIgnored
    private var summaryTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
        reload()
        // Libraries saved before series existed: the indexer creates the series bookmarks of their history.
        indexObserver = NotificationCenter.default.addObserver(forName: .seriesIndexDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
                self?.dropSummaries()
            }
        }
    }

    // MARK: - Favorites

    func isFavorite(_ series: SeriesItem) -> Bool {
        favoriteKeys.contains(series.bookmarkKey)
    }

    func toggleFavorite(_ series: SeriesItem) {
        setFavorite(!isFavorite(series), for: series)
        favoriteToggleCount &+= 1
    }

    func setFavorite(_ isFavorite: Bool, for series: SeriesItem) {
        if isFavorite {
            let bookmark = upsert(series)
            if !bookmark.isFavorite {
                bookmark.favoritedOn = .now
                bookmark.favoriteOrder = ChannelBookmark.topFavoriteOrder()
            }
            bookmark.isFavorite = true
            favoriteKeys.insert(series.bookmarkKey)
        } else {
            favoriteKeys.remove(series.bookmarkKey)
            guard let bookmark = existing(key: series.bookmarkKey) else {
                return
            }
            bookmark.isFavorite = false
            bookmark.favoritedOn = nil
            deleteIfUnused(bookmark)
        }
        save()
    }

    /// Saves the user's order of the favorite series (bookmark keys, first to last).
    func reorderFavorites(_ keys: [String]) {
        for (index, key) in keys.enumerated() {
            existing(key: key)?.favoriteOrder = Double(index)
        }
        save()
    }

    // MARK: - Summaries

    /// `series` with its counts (and its poster, when the episode it was built from has none) once they are
    /// loaded; `series` itself until then, or when it already has them.
    func summary(of series: SeriesItem) -> SeriesItem {
        guard series.episodeCount == nil, let summary = summaries[series.bookmarkKey] else {
            return series
        }
        return SeriesItem(
            playlistID: series.playlistID,
            key: series.key,
            title: series.title,
            artwork: series.artwork ?? summary.artwork,
            groupName: series.groupName,
            year: series.year ?? summary.year,
            episodeCount: summary.episodeCount,
            seasonCount: summary.seasonCount
        )
    }

    /// Loads the counts of a series a card shows without them. The requests of the cards that appear together
    /// are read in one fetch, off the main actor.
    func loadSummary(of series: SeriesItem) {
        guard series.episodeCount == nil, requestedSummaries.insert(series.bookmarkKey).inserted else {
            return
        }
        pendingSummaries.append(series)
        guard summaryTask == nil else {
            return
        }
        let container = context.container
        let revision = summaryRevision
        summaryTask = Task { [weak self] in
            // The cards of one screen appear within a frame or two.
            try? await Task.sleep(for: .milliseconds(30))
            while let self, revision == self.summaryRevision, !self.pendingSummaries.isEmpty {
                let batch = self.pendingSummaries
                self.pendingSummaries = []
                let loaded = await Task.detached(priority: .userInitiated) {
                    SeriesLookup.summaries(of: batch, in: container)
                }.value
                // Dropped meanwhile (the series changed): these may be stale.
                guard revision == self.summaryRevision else {
                    return
                }
                for summary in loaded {
                    self.summaries[summary.bookmarkKey] = summary
                }
            }
            if let self, revision == self.summaryRevision {
                self.summaryTask = nil
            }
        }
    }

    private func dropSummaries() {
        summaryTask?.cancel()
        summaryTask = nil
        pendingSummaries = []
        requestedSummaries = []
        summaries = [:]
        summaryRevision &+= 1
    }

    // MARK: - Watching

    func state(for series: SeriesItem) -> SeriesWatchState? {
        states[series.bookmarkKey]
    }

    func state(forKey key: String) -> SeriesWatchState? {
        states[key]
    }

    func isWatched(_ episode: ChannelItem) -> Bool {
        guard let key = episode.seriesBookmarkKey, let code = episode.series?.code else {
            return false
        }
        return states[key]?.watched.contains(code) ?? false
    }

    /// An episode started playing: it becomes the series' last episode.
    func recordWatch(_ episode: ChannelItem) {
        guard let ref = episode.series, let series = episode.seriesItem else {
            return
        }
        let bookmark = upsert(series)
        // Back in the history before sync folded its removal: not a removal to publish.
        SyncDeletionJournal.withdrawHistoryRemoval(Self.historyKey(of: bookmark))
        bookmark.lastWatchedAt = .now
        bookmark.lastEpisodeURL = episode.url
        bookmark.lastSeason = ref.code.season
        bookmark.lastEpisode = ref.episode
        states[series.bookmarkKey] = SeriesWatchState(bookmark)
        save()
    }

    /// Marks an episode as watched (it was played to the end, or the viewer said so) or not.
    func setWatched(_ watched: Bool, for episodes: [ChannelItem]) {
        guard let series = episodes.first?.seriesItem else {
            return
        }
        let bookmark = upsert(series)
        var codes = Set(bookmark.watchedEpisodeCodes.compactMap(EpisodeCode.init))
        for episode in episodes {
            guard let code = episode.series?.code else {
                continue
            }
            if watched {
                codes.insert(code)
            } else {
                codes.remove(code)
            }
        }
        bookmark.watchedEpisodeCodes = codes.sorted().map(\.rawValue)
        states[series.bookmarkKey] = SeriesWatchState(bookmark)
        journalHistoryChange(bookmark)
        deleteIfUnused(bookmark)
        save()
    }

    /// An episode left the history (the history screen): it is no longer watched, and when it was the series'
    /// last episode, `latest` (the episode watched before it that is still in the history) takes its place.
    func removeFromHistory(_ episode: ChannelItem, latest: (item: ChannelItem, watchedAt: Date)?) {
        guard let ref = episode.series, let key = episode.seriesBookmarkKey, let bookmark = existing(key: key) else {
            return
        }
        let code = ref.code
        bookmark.watchedEpisodeCodes.removeAll { EpisodeCode($0) == code }
        let wasLast = bookmark.lastEpisodeURL == episode.url
            || (bookmark.lastEpisodeURL == nil && bookmark.lastEpisode == ref.episode && (bookmark.lastSeason ?? 1) == code.season)
        if wasLast {
            if let latest, let latestRef = latest.item.series {
                bookmark.lastEpisodeURL = latest.item.url
                bookmark.lastSeason = latestRef.code.season
                bookmark.lastEpisode = latestRef.episode
                bookmark.lastWatchedAt = latest.watchedAt
            } else {
                clearLastEpisode(of: bookmark)
            }
        }
        states[key] = SeriesWatchState(bookmark)
        journalHistoryChange(bookmark)
        deleteIfUnused(bookmark)
        save()
    }

    /// The whole series left the history (Continue Watching): its last episode and its watched episodes are
    /// forgotten; a favorite stays one.
    func forgetHistory(of series: SeriesItem) {
        let key = series.bookmarkKey
        states[key] = nil
        guard let bookmark = existing(key: key) else {
            return
        }
        // iCloud sync removes it from the other devices too, at once, with the episodes (`ChannelLibrary`).
        SyncDeletionJournal.noteHistoryRemoved([Self.historyKey(of: bookmark)])
        clearLastEpisode(of: bookmark)
        bookmark.watchedEpisodeCodes = []
        deleteIfUnused(bookmark)
        save()
    }

    /// Forgets what was watched (Clear History); favorites are kept.
    func clearHistory() {
        do {
            for bookmark in try context.fetch(FetchDescriptor<SeriesBookmark>()) {
                clearLastEpisode(of: bookmark)
                bookmark.watchedEpisodeCodes = []
                deleteIfUnused(bookmark)
            }
        } catch {
            Self.logger.error("Could not clear the series history: \(error.localizedDescription, privacy: .public)")
        }
        states = [:]
        save()
    }

    /// Drops the in-memory state of a deleted playlist (its rows are deleted by the importer).
    func forgetPlaylist(_ playlistID: UUID) {
        let prefix = "\(playlistID.uuidString)|"
        favoriteKeys = favoriteKeys.filter { !$0.hasPrefix(prefix) }
        states = states.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Private

    /// Reads the favorites and watch states again (after iCloud sync changed the bookmarks).
    func reload() {
        do {
            var favorites: Set<String> = []
            var states: [String: SeriesWatchState] = [:]
            for bookmark in try context.fetch(FetchDescriptor<SeriesBookmark>()) {
                if bookmark.isFavorite {
                    favorites.insert(bookmark.key)
                }
                if bookmark.lastEpisodeURL != nil || !bookmark.watchedEpisodeCodes.isEmpty {
                    states[bookmark.key] = SeriesWatchState(bookmark)
                }
            }
            favoriteKeys = favorites
            self.states = states
        } catch {
            Self.logger.error("Could not load the series: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func existing(key: String) -> SeriesBookmark? {
        try? context.fetch(SeriesQueries.bookmark(key: key)).first
    }

    /// Finds or creates the bookmark and refreshes its snapshot.
    private func upsert(_ series: SeriesItem) -> SeriesBookmark {
        if let bookmark = existing(key: series.bookmarkKey) {
            bookmark.title = series.title
            if let artwork = series.artwork {
                bookmark.artwork = artwork
            }
            bookmark.groupName = series.groupName
            return bookmark
        }
        let bookmark = SeriesBookmark(
            key: series.bookmarkKey,
            playlistID: series.playlistID,
            seriesKey: series.key,
            title: series.title,
            artwork: series.artwork,
            groupName: series.groupName
        )
        context.insert(bookmark)
        return bookmark
    }

    private func clearLastEpisode(of bookmark: SeriesBookmark) {
        bookmark.lastWatchedAt = nil
        bookmark.lastEpisodeURL = nil
        bookmark.lastSeason = nil
        bookmark.lastEpisode = nil
    }

    /// The series' watch state, for `SyncDeletionJournal`.
    private static func historyKey(of bookmark: SeriesBookmark) -> String {
        SyncIdentity.localHistoryKey(playlistID: bookmark.playlistID, seriesKey: bookmark.seriesKey)
    }

    /// For iCloud sync, after the user's change: a series left without a watch state (its last episode removed from
    /// the history, its episodes marked unwatched) has its synced progress removed from the other devices too, at
    /// once; one with a state (an episode marked watched) is in the history again, so a removal of it that sync has
    /// not folded yet is withdrawn, as `recordWatch` does.
    private func journalHistoryChange(_ bookmark: SeriesBookmark) {
        if bookmark.lastWatchedAt == nil && bookmark.lastEpisodeURL == nil && bookmark.watchedEpisodeCodes.isEmpty {
            SyncDeletionJournal.noteHistoryRemoved([Self.historyKey(of: bookmark)])
        } else {
            SyncDeletionJournal.withdrawHistoryRemoval(Self.historyKey(of: bookmark))
        }
    }

    private func deleteIfUnused(_ bookmark: SeriesBookmark) {
        if !bookmark.isFavorite && bookmark.lastEpisodeURL == nil && bookmark.watchedEpisodeCodes.isEmpty {
            states[bookmark.key] = nil
            context.delete(bookmark)
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Self.logger.error("Could not save the series: \(error.localizedDescription, privacy: .public)")
        }
    }
}
