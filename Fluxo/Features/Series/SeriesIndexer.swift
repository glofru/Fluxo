//
//  SeriesIndexer.swift
//  Fluxo
//
//  Groups the episodes of an import that was stored without series (imported before series existed, or with an
//  older `EpisodeParser.version`), so existing libraries get series without a refresh. Runs once per import at
//  launch, through `PlaylistImporter.indexSeriesIfNeeded()`, on background contexts.
//
//  It reads only the on-demand rows of the import, in playlist order and in batches (live channels are never
//  episodes), sets their series fields as the importer would, turns movies named like episodes into series,
//  updates the listed counts and kinds of the groups, and writes the `PlaylistSeries` rows.
//

import Foundation
import os
import SwiftData

enum SeriesIndexer {

    static let batchSize = 5_000

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Series")

    struct Summary: Sendable {
        let episodeCount: Int
        let seriesCount: Int
        let duration: Duration
    }

    /// Indexes one import. The playlist is marked as indexed only if the import is still its visible one (an
    /// import replaced meanwhile is deleted with its rows anyway).
    static func index(importID: UUID, playlistID: UUID, container: ModelContainer) throws -> Summary {
        let clock = ContinuousClock()
        let started = clock.now
        let live = ChannelContentKind.live.rawValue
        var series = SeriesAccumulator()
        var session = EpisodeParser.Session()
        var stats: [String: GroupStats] = [:]
        var episodes = 0
        var offset = 0

        while true {
            let fetched = try autoreleasepool { () -> Int in
                let context = makeContext(container)
                var descriptor = FetchDescriptor<PlaylistChannel>(
                    predicate: #Predicate { $0.importID == importID && $0.kindRawValue != live },
                    sortBy: [SortDescriptor(\.sortIndex)]
                )
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = batchSize
                let rows = try context.fetch(descriptor)
                for row in rows {
                    let (classified, episode) = ChannelContentKind.classifyEntry(url: row.url, groupName: row.groupName, name: row.name, session: &session)
                    // The rows are on-demand: keep them so even if the URL rules would now say otherwise.
                    let kind = classified == .live ? row.kind : classified
                    let isListed = episode.map { series.add($0, sortIndex: row.sortIndex, logo: row.logo, groupName: row.groupName) } ?? true
                    if !row.matches(episode, isListed: isListed) {
                        row.apply(episode, isListed: isListed)
                    }
                    if row.kindRawValue != kind.rawValue {
                        row.kindRawValue = kind.rawValue
                    }
                    stats[row.groupName, default: GroupStats()].add(kind: kind, isListed: isListed, isSeries: episode != nil)
                    if episode != nil {
                        episodes += 1
                    }
                }
                if context.hasChanges {
                    try context.save()
                }
                return rows.count
            }
            offset += fetched
            if fetched < batchSize {
                break
            }
        }

        let context = makeContext(container)
        try context.delete(model: PlaylistSeries.self, where: #Predicate { $0.importID == importID })
        let groups = try context.fetch(FetchDescriptor<PlaylistChannelGroup>(predicate: #Predicate { $0.importID == importID }))
        for group in groups {
            guard let groupStats = stats[group.name] else {
                // Live channels only: every one is listed.
                group.listedCount = group.channelCount
                group.seriesCount = 0
                continue
            }
            let liveCount = max(0, group.channelCount - groupStats.movieCount - groupStats.seriesEpisodeCount)
            group.listedCount = liveCount + groupStats.listedCount
            group.seriesCount = groupStats.seriesCount
            let kind = ChannelContentKind.dominant(live: liveCount, movie: groupStats.movieCount, series: groupStats.seriesEpisodeCount)
            if group.kindRawValue != kind.rawValue {
                group.kindRawValue = kind.rawValue
            }
        }
        series.insertRows(importID: importID, playlistID: playlistID, into: context)
        var playlistDescriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.uuid == playlistID })
        playlistDescriptor.fetchLimit = 1
        if let playlist = try context.fetch(playlistDescriptor).first, playlist.currentImportID == importID {
            playlist.seriesIndexVersion = EpisodeParser.version
        }
        try context.save()

        try indexBookmarks(playlistID: playlistID, container: container)

        let summary = Summary(episodeCount: episodes, seriesCount: series.ordered.count, duration: clock.now - started)
        logger.info("Indexed \(summary.episodeCount) episodes in \(summary.seriesCount) series in \(String(describing: summary.duration), privacy: .public)")
        return summary
    }

    /// Favorites and history entries saved before series existed: their names are read like the import reads
    /// them, so Continue Watching groups them by series, and episodes that were watched to the end (a duration
    /// is known and no position is left) count as watched, with the most recent one as the series' last episode.
    static func indexBookmarks(playlistID: UUID, container: ModelContainer) throws {
        let context = makeContext(container)
        let live = ChannelContentKind.live.rawValue
        let descriptor = FetchDescriptor<ChannelBookmark>(
            predicate: #Predicate { $0.playlistID == playlistID && $0.kindRawValue != live && $0.seriesKey == nil },
            sortBy: [SortDescriptor(\.lastWatchedAt, order: .reverse)]
        )
        var session = EpisodeParser.Session()
        var seriesBookmarks: [String: SeriesBookmark] = [:]
        for bookmark in try context.fetch(descriptor) {
            let (_, info) = ChannelContentKind.classifyEntry(url: bookmark.url, groupName: bookmark.groupName, name: bookmark.name, session: &session)
            guard let info else {
                continue
            }
            let ref = EpisodeRef(seriesKey: info.seriesKey, seriesTitle: info.seriesTitle, season: info.season, episode: info.episode, episodeTitle: info.episodeTitle)
            bookmark.setEpisode(ref)
            bookmark.kindRawValue = ChannelContentKind.series.rawValue
            guard bookmark.lastWatchedAt != nil else {
                continue
            }
            let key = SeriesBookmark.key(playlistID: playlistID, seriesKey: info.seriesKey)
            let seriesBookmark: SeriesBookmark
            if let known = seriesBookmarks[key] {
                seriesBookmark = known
            } else if let stored = try context.fetch(SeriesQueries.bookmark(key: key)).first {
                seriesBookmark = stored
                seriesBookmarks[key] = stored
            } else {
                seriesBookmark = SeriesBookmark(key: key, playlistID: playlistID, seriesKey: info.seriesKey, title: info.seriesTitle, artwork: bookmark.logo, groupName: bookmark.groupName)
                context.insert(seriesBookmark)
                seriesBookmarks[key] = seriesBookmark
            }
            // Newest first: the first one seen is the last episode watched.
            if seriesBookmark.lastEpisodeURL == nil {
                seriesBookmark.lastEpisodeURL = bookmark.url
                seriesBookmark.lastSeason = ref.code.season
                seriesBookmark.lastEpisode = ref.episode
                seriesBookmark.lastWatchedAt = bookmark.lastWatchedAt
            }
            if bookmark.knownDuration > 0 && bookmark.resumePosition == 0 && !seriesBookmark.watchedEpisodeCodes.contains(ref.code.rawValue) {
                seriesBookmark.watchedEpisodeCodes.append(ref.code.rawValue)
            }
        }
        if context.hasChanges {
            try context.save()
        }
    }

    /// The visible imports whose series are missing or out of date.
    static func importsNeedingIndex(in container: ModelContainer) throws -> [(importID: UUID, playlistID: UUID)] {
        let version = EpisodeParser.version
        let descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.seriesIndexVersion < version && $0.currentImportID != nil })
        return try makeContext(container).fetch(descriptor).compactMap { playlist in
            playlist.currentImportID.map { ($0, playlist.uuid) }
        }
    }

    private static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private struct GroupStats {
        var movieCount = 0
        var seriesEpisodeCount = 0
        var listedCount = 0
        var seriesCount = 0

        mutating func add(kind: ChannelContentKind, isListed: Bool, isSeries: Bool) {
            if kind == .series {
                seriesEpisodeCount += 1
            } else {
                movieCount += 1
            }
            if isListed {
                listedCount += 1
                if isSeries {
                    seriesCount += 1
                }
            }
        }
    }
}
