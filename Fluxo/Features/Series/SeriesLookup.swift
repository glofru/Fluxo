//
//  SeriesLookup.swift
//  Fluxo
//
//  Read-only series queries for the series page, the player's next-episode prompt, Continue Watching, Search
//  and the App Intents (Siri can adopt them: `series(matching:)`, `episodes(of:)`, `episodeToPlay(for:)`,
//  `nextEpisode(after:)`). Every function uses its own `ModelContext` and returns values, so callers can run
//  it off the main actor.
//

import Foundation
import SwiftData

/// The episodes of a series, in watching order.
struct SeriesEpisodes: Sendable {
    let series: SeriesItem
    let importID: UUID
    /// By season, episode, then playlist position (several copies of an episode, e.g. two languages, follow
    /// each other).
    let episodes: [ChannelItem]

    /// Season numbers in order (0, the specials, last).
    var seasons: [Int] {
        let numbers = Set(episodes.compactMap { $0.series?.code.season })
        return numbers.sorted { lhs, rhs in
            if (lhs == 0) != (rhs == 0) {
                return rhs == 0
            }
            return lhs < rhs
        }
    }

    func episodes(inSeason season: Int) -> [ChannelItem] {
        episodes.filter { $0.series?.code.season == season }
    }

    /// The episode after `item` in watching order (the next copy of the same episode is skipped).
    func episode(after item: ChannelItem) -> ChannelItem? {
        guard let code = item.series?.code, let index = episodes.firstIndex(where: { $0.url == item.url }) ?? episodes.firstIndex(where: { $0.series?.code == code }) else {
            return nil
        }
        return episodes[(index + 1)...].first { ($0.series?.code ?? code) > code }
    }
}

/// What "Continue" plays for a series, and why.
struct SeriesNextUp: Sendable, Hashable {
    enum Reason: Sendable, Hashable {
        /// Never watched: the first episode.
        case start
        /// The episode watched last stopped part-way.
        case resume
        /// The episode watched last was stopped before a position was worth keeping (or it was cleared): it plays
        /// again from its beginning.
        case restart
        /// The episode after the last one watched to the end.
        case next
        /// Every episode was watched: from the beginning again.
        case rewatch
    }

    let episode: ChannelItem
    let reason: Reason
}

enum SeriesLookup {

    static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    /// The visible import of a playlist.
    static func currentImportID(playlistID: UUID, in context: ModelContext) -> UUID? {
        try? context.fetch(HomeQueries.playlist(uuid: playlistID)).first?.currentImportID
    }

    /// A series of a playlist's visible import, with its counts.
    static func series(playlistID: UUID, key: String, in container: ModelContainer) -> SeriesItem? {
        let context = makeContext(container)
        guard let importID = currentImportID(playlistID: playlistID, in: context) else {
            return nil
        }
        return try? context.fetch(SeriesQueries.series(importID: importID, key: key)).first.map(SeriesItem.init)
    }

    /// The series rows (counts, artwork) of series known only by key, as cards built from an episode know them;
    /// series that are gone are left out. One fetch per playlist.
    static func summaries(of series: [SeriesItem], in container: ModelContainer) -> [SeriesItem] {
        let context = makeContext(container)
        var result: [SeriesItem] = []
        for (playlistID, items) in Dictionary(grouping: series, by: \.playlistID) {
            guard let importID = currentImportID(playlistID: playlistID, in: context) else {
                continue
            }
            let keys = Array(Set(items.map(\.key)))
            let descriptor = FetchDescriptor<PlaylistSeries>(predicate: #Predicate { $0.importID == importID && keys.contains($0.key) })
            result += ((try? context.fetch(descriptor)) ?? []).map(SeriesItem.init)
        }
        return result
    }

    /// Every episode of a series in the playlist's visible import; nil when the playlist or series is gone.
    static func episodes(playlistID: UUID, key: String, in container: ModelContainer) -> SeriesEpisodes? {
        let context = makeContext(container)
        guard let importID = currentImportID(playlistID: playlistID, in: context) else {
            return nil
        }
        let rows = (try? context.fetch(SeriesQueries.episodes(importID: importID, key: key))) ?? []
        guard let first = rows.first else {
            return nil
        }
        var seenURLs: Set<URL> = []
        // The same stream listed in two categories counts once.
        let items = rows.map(ChannelItem.init).filter { item in
            guard let url = item.url else {
                return true
            }
            return seenURLs.insert(url).inserted
        }
        let sorted = items.enumerated().sorted { lhs, rhs in
            let left = lhs.element.series?.code ?? EpisodeCode(season: 0, episode: 0)
            let right = rhs.element.series?.code ?? EpisodeCode(season: 0, episode: 0)
            if left != right {
                // Specials (season 0) after the regular seasons.
                if (left.season == 0) != (right.season == 0) {
                    return right.season == 0
                }
                return left < right
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let summary = (try? context.fetch(SeriesQueries.series(importID: importID, key: key)).first).map(SeriesItem.init)
        let series = summary ?? SeriesItem(
            playlistID: playlistID,
            key: key,
            title: first.episodeRef?.seriesTitle ?? first.name ?? "",
            artwork: rows.lazy.compactMap(\.logo).first,
            groupName: first.groupName,
            episodeCount: sorted.count,
            seasonCount: Set(sorted.compactMap { $0.series?.code.season }).count
        )
        return SeriesEpisodes(series: series, importID: importID, episodes: sorted)
    }

    static func episodes(of series: SeriesItem, in container: ModelContainer) -> SeriesEpisodes? {
        episodes(playlistID: series.playlistID, key: series.key, in: container)
    }

    /// The episode after `item` in its series; nil for the last one, or for anything that is not an episode.
    static func nextEpisode(after item: ChannelItem, in container: ModelContainer) -> ChannelItem? {
        guard let series = item.series, let all = episodes(playlistID: item.playlistID, key: series.seriesKey, in: container) else {
            return nil
        }
        return all.episode(after: item)
    }

    /// What "Continue" plays: the last episode if it stopped part-way, else the next unwatched one, else the first.
    /// `progressKeys` are the bookmark keys of the episodes with a resume position (`ChannelLibrary`).
    static func nextUp(in episodes: SeriesEpisodes, state: SeriesWatchState?, progressKeys: Set<String>) -> SeriesNextUp? {
        let all = episodes.episodes
        guard let first = all.first else {
            return nil
        }
        let watched = state?.watched ?? []
        if let lastURL = state?.lastEpisodeURL, let index = all.firstIndex(where: { $0.url == lastURL }) ?? state?.lastEpisode.flatMap({ code in all.firstIndex { $0.series?.code == code } }) {
            let last = all[index]
            if let key = last.bookmarkKey, progressKeys.contains(key) {
                return SeriesNextUp(episode: last, reason: .resume)
            }
            let lastCode = last.series?.code
            if let lastCode, !watched.contains(lastCode) {
                // Started but stopped before a position was worth keeping: that episode again, from the start.
                return SeriesNextUp(episode: last, reason: .restart)
            }
            if let next = all[(index + 1)...].first(where: { item in
                guard let code = item.series?.code else {
                    return false
                }
                return code != lastCode && !watched.contains(code)
            }) {
                return SeriesNextUp(episode: next, reason: .next)
            }
        }
        // Never watched here, or the episodes after the last one are watched: the first unwatched one.
        if let unwatched = all.first(where: { !watched.contains($0.series?.code ?? EpisodeCode(season: -1, episode: -1)) }) {
            let isStarted = unwatched.bookmarkKey.map(progressKeys.contains) ?? false
            if isStarted {
                return SeriesNextUp(episode: unwatched, reason: .resume)
            }
            return SeriesNextUp(episode: unwatched, reason: watched.isEmpty && state?.lastEpisodeURL == nil ? .start : .next)
        }
        return SeriesNextUp(episode: first, reason: .rewatch)
    }

    /// Reads the watch state of a series from the store (the main actor reads `SeriesLibrary` instead).
    static func watchState(playlistID: UUID, key: String, in container: ModelContainer) -> SeriesWatchState? {
        let bookmarkKey = SeriesBookmark.key(playlistID: playlistID, seriesKey: key)
        return (try? makeContext(container).fetch(SeriesQueries.bookmark(key: bookmarkKey)).first).map(SeriesWatchState.init)
    }

    /// The episode to play for a series (App Intents: "play Breaking Bad"): where the viewer left off.
    static func episodeToPlay(for series: SeriesItem, in container: ModelContainer) -> SeriesNextUp? {
        guard let episodes = episodes(of: series, in: container) else {
            return nil
        }
        let context = makeContext(container)
        let resumable = FetchDescriptor<ChannelBookmark>(predicate: #Predicate { $0.resumePosition > 0 })
        let progressKeys = Set(((try? context.fetch(resumable)) ?? []).map(\.key))
        return nextUp(in: episodes, state: watchState(playlistID: series.playlistID, key: series.key, in: container), progressKeys: progressKeys)
    }

    /// Series whose title matches `term` (the token search of the Search screen), best first.
    @concurrent static func series(matching term: String, importIDs: [UUID], limit: Int, in container: ModelContainer) async -> [SeriesItem] {
        let hits = await ChannelSearchIndex.shared.searchSeries(term, importIDs: importIDs, limit: limit, container: container)
        guard !hits.isEmpty else {
            return []
        }
        return SeriesQueries.series(for: hits, in: makeContext(container)).map(SeriesItem.init)
    }
}

/// Fetches of series rows and episodes, in one place like `HomeQueries` (checked by Tools/SeriesCheck).
enum SeriesQueries {

    /// Every episode of a series in an import (watching order is applied in memory: a few hundred rows).
    static func episodes(importID: UUID, key: String) -> FetchDescriptor<PlaylistChannel> {
        let key: String? = key
        return FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.seriesKey == key },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
    }

    static func series(importID: UUID, key: String) -> FetchDescriptor<PlaylistSeries> {
        var descriptor = FetchDescriptor<PlaylistSeries>(predicate: #Predicate { $0.importID == importID && $0.key == key })
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Series of the imports, in playlist order (`offset` / `limit` pick a window).
    static func series(importIDs: [UUID], withArtwork: Bool, offset: Int = 0, limit: Int) -> FetchDescriptor<PlaylistSeries> {
        let predicate: Predicate<PlaylistSeries>
        if withArtwork {
            predicate = #Predicate { importIDs.contains($0.importID) && $0.artwork != nil }
        } else {
            predicate = #Predicate { importIDs.contains($0.importID) }
        }
        var descriptor = FetchDescriptor<PlaylistSeries>(predicate: predicate, sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    static func bookmark(key: String) -> FetchDescriptor<SeriesBookmark> {
        var descriptor = FetchDescriptor<SeriesBookmark>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Favorite series, in the user's order. `playlistIDs == nil` means every playlist.
    static func favorites(playlistIDs: [UUID]?, limit: Int) -> FetchDescriptor<SeriesBookmark> {
        let predicate: Predicate<SeriesBookmark>
        if let playlistIDs {
            predicate = #Predicate { $0.isFavorite == true && playlistIDs.contains($0.playlistID) }
        } else {
            predicate = #Predicate { $0.isFavorite == true }
        }
        var descriptor = FetchDescriptor<SeriesBookmark>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.favoritedOn, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// The series rows of search hits (`sortIndex` of the series), in the order of the hits.
    static func series(for hits: [SearchHit], in context: ModelContext) -> [PlaylistSeries] {
        let byImport = Dictionary(grouping: hits, by: \.importID)
        var rows: [UUID: [Int: PlaylistSeries]] = [:]
        for (importID, importHits) in byImport {
            let indexes = importHits.map(\.sortIndex)
            let descriptor = FetchDescriptor<PlaylistSeries>(predicate: #Predicate { $0.importID == importID && indexes.contains($0.sortIndex) })
            let fetched = (try? context.fetch(descriptor)) ?? []
            rows[importID] = Dictionary(fetched.map { ($0.sortIndex, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return hits.compactMap { rows[$0.importID]?[$0.sortIndex] }
    }
}

/// What the viewer did with a series, as a value.
struct SeriesWatchState: Hashable, Sendable {
    var watched: Set<EpisodeCode> = []
    var lastEpisodeURL: URL?
    var lastEpisode: EpisodeCode?
    var lastWatchedAt: Date?

    init(watched: Set<EpisodeCode> = [], lastEpisodeURL: URL? = nil, lastEpisode: EpisodeCode? = nil, lastWatchedAt: Date? = nil) {
        self.watched = watched
        self.lastEpisodeURL = lastEpisodeURL
        self.lastEpisode = lastEpisode
        self.lastWatchedAt = lastWatchedAt
    }

    init(_ bookmark: SeriesBookmark) {
        watched = Set(bookmark.watchedEpisodeCodes.compactMap(EpisodeCode.init))
        lastEpisodeURL = bookmark.lastEpisodeURL
        lastEpisode = bookmark.lastEpisode.map { EpisodeCode(season: bookmark.lastSeason ?? 1, episode: $0) }
        lastWatchedAt = bookmark.lastWatchedAt
    }
}
