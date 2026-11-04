//
//  ChannelSearchIndex.swift
//  Fluxo
//
//  In-memory name index of the visible imports, for Search (see `SearchMatcher` for the matching rules).
//
//  SQLite can only filter on "contains the whole text", so token, typo-tolerant and ranked search runs in
//  memory: the first search in an import reads its channel and group names once (on a background context, in
//  batches, a few hundred milliseconds for 100k channels), keeps them normalized, and every keystroke after
//  that is a scan of small byte arrays. Only the best rows are then fetched from the store.
//
//  An import never changes once it is visible (a refresh writes a new import, see `Playlist`), so an index is
//  valid for as long as its import exists; the least recently searched indexes are dropped when the cache
//  holds more than `maximumCachedEntries` names.
//

import Foundation
import SwiftData

/// One channel, group or series of an import, as the index keeps it.
struct SearchIndexEntry: Sendable {
    let name: SearchName
    /// `sortIndex` of the row: with the import ID it identifies the row through an indexed fetch.
    let sortIndex: Int
    let kindRawValue: Int
    /// An episode: the `sortIndex` of its `PlaylistSeries` (Search lists the series once, not every episode);
    /// -1 otherwise.
    var seriesSortIndex: Int = -1
}

/// The normalized names of one import.
struct ImportSearchIndex: Sendable {
    let importID: UUID
    let channels: [SearchIndexEntry]
    let groups: [SearchIndexEntry]
    /// Series titles (`PlaylistSeries`).
    var series: [SearchIndexEntry] = []

    var entryCount: Int {
        channels.count + groups.count + series.count
    }
}

/// A ranked hit: which import and row, and its score.
struct SearchHit: Sendable {
    let importID: UUID
    let sortIndex: Int
    let score: Int
    /// Position of the import in the request, then of the row in the import: ties keep the playlist order.
    let order: Int
    let sortKey: Int
    /// See `SearchIndexEntry.seriesSortIndex`.
    var seriesSortIndex: Int = -1
}

actor ChannelSearchIndex {

    static let shared = ChannelSearchIndex()

    /// About 40 MB at most (names are short); far more than the visible imports of a typical library.
    static let maximumCachedEntries = 600_000
    static let readBatchSize = 25_000

    private var indexes: [UUID: ImportSearchIndex] = [:]
    private var lastUse: [UUID: UInt64] = [:]
    private var useCounter: UInt64 = 0
    private var building: [UUID: Task<ImportSearchIndex, Never>] = [:]

    // MARK: Searching

    /// The best `limit` channels and groups of `importIDs` for `text`, optionally of one kind.
    func search(_ text: String, importIDs: [UUID], kind: ChannelContentKind?, channelLimit: Int, groupLimit: Int, container: ModelContainer) async -> (channels: [SearchHit], groups: [SearchHit]) {
        let query = SearchQuery(text)
        guard !query.isEmpty else {
            return ([], [])
        }
        var loaded: [ImportSearchIndex] = []
        for importID in importIDs {
            loaded.append(await index(for: importID, container: container))
            if Task.isCancelled {
                return ([], [])
            }
        }
        trimCache(keeping: Set(importIDs))
        let kindValue = kind?.rawValue
        let channels = Self.rank(loaded.map { ($0.importID, $0.channels) }, query: query, kind: kindValue, limit: channelLimit)
        if Task.isCancelled {
            return ([], [])
        }
        let groups = Self.rank(loaded.map { ($0.importID, $0.groups) }, query: query, kind: kindValue, limit: groupLimit)
        return (channels, groups)
    }

    /// Search with series: like `search`, but the episodes of a series are not channel hits; each series that
    /// matches (by its title, or by one of its episodes, "Ozymandias") is one series hit instead.
    func searchCollapsingSeries(_ text: String, importIDs: [UUID], kind: ChannelContentKind?, channelLimit: Int, groupLimit: Int, seriesLimit: Int, container: ModelContainer) async -> (channels: [SearchHit], groups: [SearchHit], series: [SearchHit]) {
        let query = SearchQuery(text)
        guard !query.isEmpty else {
            return ([], [], [])
        }
        var loaded: [ImportSearchIndex] = []
        for importID in importIDs {
            loaded.append(await index(for: importID, container: container))
            if Task.isCancelled {
                return ([], [], [])
            }
        }
        trimCache(keeping: Set(importIDs))
        let kindValue = kind?.rawValue
        let collapsed = Self.rankCollapsingSeries(loaded, query: query, kind: kindValue, channelLimit: channelLimit, seriesLimit: kind == nil || kind == .series ? seriesLimit : 0)
        if Task.isCancelled {
            return ([], [], [])
        }
        let groups = Self.rank(loaded.map { ($0.importID, $0.groups) }, query: query, kind: kindValue, limit: groupLimit)
        return (collapsed.channels, groups, collapsed.series)
    }

    /// The series whose title (or one of whose episodes) matches `text`, best first.
    func searchSeries(_ text: String, importIDs: [UUID], limit: Int, container: ModelContainer) async -> [SearchHit] {
        await searchCollapsingSeries(text, importIDs: importIDs, kind: .series, channelLimit: 0, groupLimit: 0, seriesLimit: limit, container: container).series
    }

    nonisolated static func rankCollapsingSeries(_ indexes: [ImportSearchIndex], query: SearchQuery, kind: Int?, channelLimit: Int, seriesLimit: Int) -> (channels: [SearchHit], series: [SearchHit]) {
        // Every match (no limit yet): episodes are folded into their series before the best are kept.
        let matches = rank(indexes.map { ($0.importID, $0.channels) }, query: query, kind: kind, limit: Int.max, typoThreshold: channelLimit + seriesLimit)
        var channels: [SearchHit] = []
        var bestOfSeries: [SeriesHitKey: SearchHit] = [:]
        func keep(_ hit: SearchHit, seriesSortIndex: Int) {
            let key = SeriesHitKey(order: hit.order, sortIndex: seriesSortIndex)
            if let best = bestOfSeries[key], best.score >= hit.score {
                return
            }
            bestOfSeries[key] = SearchHit(importID: hit.importID, sortIndex: seriesSortIndex, score: hit.score, order: hit.order, sortKey: seriesSortIndex)
        }
        for hit in matches {
            if hit.seriesSortIndex >= 0 {
                if seriesLimit > 0 {
                    keep(hit, seriesSortIndex: hit.seriesSortIndex)
                }
            } else if channels.count < channelLimit {
                channels.append(hit)
            }
        }
        if seriesLimit > 0 {
            // The series title itself: "breaking bad" is an exact match of the series, not of "Breaking Bad S01E01".
            for hit in rank(indexes.map { ($0.importID, $0.series) }, query: query, kind: nil, limit: Int.max, typoThreshold: seriesLimit) {
                keep(hit, seriesSortIndex: hit.sortIndex)
            }
        }
        var series = Array(bestOfSeries.values)
        series.sort(by: isRankedBefore)
        if series.count > seriesLimit {
            series.removeSubrange(seriesLimit...)
        }
        return (channels, series)
    }

    private struct SeriesHitKey: Hashable {
        let order: Int
        let sortIndex: Int
    }

    nonisolated static func isRankedBefore(_ lhs: SearchHit, _ rhs: SearchHit) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        return lhs.sortKey < rhs.sortKey
    }

    /// How many entries are scored between two cancellation checks.
    static let cancellationCheckInterval = 4_096

    /// Ranks entries: a pass without typos, then, if it found fewer than `limit`, a pass that allows them.
    ///
    /// Returns nothing as soon as the calling task is cancelled (checked every `cancellationCheckInterval`
    /// entries): Search cancels the search of every stale keystroke, and the actor runs one search at a time, so a
    /// stale pass must not delay the current one.
    /// `typoThreshold`: the typo pass runs when the first pass found fewer hits than this (default: `limit`).
    nonisolated static func rank(_ sources: [(UUID, [SearchIndexEntry])], query: SearchQuery, kind: Int?, limit: Int, typoThreshold: Int? = nil) -> [SearchHit] {
        var hits: [SearchHit] = []
        var unmatched: [(source: Int, entry: Int)] = []
        let allowsTypos = query.tokens.contains { SearchMatcher.typoBudget(forLength: $0.count) > 0 }
        for (sourceIndex, (importID, entries)) in sources.enumerated() {
            for (entryIndex, entry) in entries.enumerated() where kind == nil || entry.kindRawValue == kind {
                if entryIndex % cancellationCheckInterval == 0 && Task.isCancelled {
                    return []
                }
                if let score = SearchMatcher.score(entry.name, query: query, allowTypos: false) {
                    hits.append(SearchHit(importID: importID, sortIndex: entry.sortIndex, score: score, order: sourceIndex, sortKey: entry.sortIndex, seriesSortIndex: entry.seriesSortIndex))
                } else if allowsTypos {
                    unmatched.append((sourceIndex, entryIndex))
                }
            }
        }
        if hits.count < (typoThreshold ?? limit) && allowsTypos {
            for (position, (sourceIndex, entryIndex)) in unmatched.enumerated() {
                if position % cancellationCheckInterval == 0 && Task.isCancelled {
                    return []
                }
                let (importID, entries) = sources[sourceIndex]
                let entry = entries[entryIndex]
                if let score = SearchMatcher.score(entry.name, query: query, allowTypos: true) {
                    hits.append(SearchHit(importID: importID, sortIndex: entry.sortIndex, score: score, order: sourceIndex, sortKey: entry.sortIndex, seriesSortIndex: entry.seriesSortIndex))
                }
            }
        }
        hits.sort(by: isRankedBefore)
        if hits.count > limit {
            hits.removeSubrange(limit...)
        }
        return hits
    }

    /// Builds the indexes of `importIDs` ahead of the first keystroke (Search calls it when it appears).
    func prewarm(importIDs: [UUID], container: ModelContainer) async {
        for importID in importIDs where !Task.isCancelled {
            _ = await index(for: importID, container: container)
        }
        trimCache(keeping: Set(importIDs))
    }

    // MARK: Building

    private func index(for importID: UUID, container: ModelContainer) async -> ImportSearchIndex {
        useCounter &+= 1
        lastUse[importID] = useCounter
        if let index = indexes[importID] {
            return index
        }
        if let task = building[importID] {
            return await task.value
        }
        let task = Task.detached(priority: .userInitiated) {
            Self.build(importID: importID, container: container)
        }
        building[importID] = task
        let index = await task.value
        building[importID] = nil
        indexes[importID] = index
        return index
    }

    /// Reads the names of one import, in batches, each on its own short-lived context.
    nonisolated static func build(importID: UUID, container: ModelContainer) -> ImportSearchIndex {
        // The series first: episodes point at theirs.
        let series: [(key: String, entry: SearchIndexEntry)] = autoreleasepool {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<PlaylistSeries>(predicate: #Predicate { $0.importID == importID }, sortBy: [SortDescriptor(\.sortIndex)])
            descriptor.propertiesToFetch = [\.key, \.title, \.sortIndex]
            let rows = (try? context.fetch(descriptor)) ?? []
            return rows.map { ($0.key, SearchIndexEntry(name: SearchName($0.title), sortIndex: $0.sortIndex, kindRawValue: ChannelContentKind.series.rawValue)) }
        }
        let seriesSortIndexByKey = Dictionary(series.map { ($0.key, $0.entry.sortIndex) }, uniquingKeysWith: { first, _ in first })
        var channels: [SearchIndexEntry] = []
        var offset = 0
        while true {
            let batch: [SearchIndexEntry] = autoreleasepool {
                let context = ModelContext(container)
                var descriptor = FetchDescriptor<PlaylistChannel>(
                    predicate: #Predicate { $0.importID == importID },
                    sortBy: [SortDescriptor(\.sortIndex)]
                )
                descriptor.propertiesToFetch = [\.name, \.sortIndex, \.kindRawValue, \.seriesKey]
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = readBatchSize
                let rows = (try? context.fetch(descriptor)) ?? []
                return rows.map { row in
                    SearchIndexEntry(
                        name: SearchName(row.name ?? ""),
                        sortIndex: row.sortIndex,
                        kindRawValue: row.kindRawValue,
                        seriesSortIndex: row.seriesKey.flatMap { seriesSortIndexByKey[$0] } ?? -1
                    )
                }
            }
            channels.append(contentsOf: batch.filter { !$0.name.isEmpty })
            offset += readBatchSize
            if batch.count < readBatchSize {
                break
            }
        }
        let groups: [SearchIndexEntry] = autoreleasepool {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<PlaylistChannelGroup>(
                predicate: #Predicate { $0.importID == importID },
                sortBy: [SortDescriptor(\.sortIndex)]
            )
            let rows = (try? context.fetch(descriptor)) ?? []
            // Unnamed groups are listed as "Other".
            return rows.map { SearchIndexEntry(name: SearchName($0.displayName), sortIndex: $0.sortIndex, kindRawValue: $0.kindRawValue) }
        }
        return ImportSearchIndex(importID: importID, channels: channels, groups: groups, series: series.map(\.entry))
    }

    private func trimCache(keeping current: Set<UUID>) {
        var total = indexes.values.reduce(0) { $0 + $1.entryCount }
        guard total > Self.maximumCachedEntries else {
            return
        }
        let candidates = indexes.keys.filter { !current.contains($0) }.sorted { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) }
        for importID in candidates where total > Self.maximumCachedEntries {
            total -= indexes[importID]?.entryCount ?? 0
            indexes[importID] = nil
            lastUse[importID] = nil
        }
    }

    /// Drops the index of an import whose rows changed (its series were grouped after it was read).
    func removeIndex(for importID: UUID) {
        indexes[importID] = nil
        lastUse[importID] = nil
    }

    /// Drops every index (e.g. for tests).
    func removeAll() {
        indexes.removeAll()
        lastUse.removeAll()
    }

    // MARK: Fetching hits

    /// The channel rows of `hits`, in the order of the hits (rows that no longer exist are skipped).
    nonisolated static func channels(for hits: [SearchHit], in context: ModelContext) -> [PlaylistChannel] {
        let byImport = Dictionary(grouping: hits, by: \.importID)
        var rows: [UUID: [Int: PlaylistChannel]] = [:]
        for (importID, importHits) in byImport {
            let indexes = importHits.map(\.sortIndex)
            let descriptor = FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.importID == importID && indexes.contains($0.sortIndex) })
            let fetched = (try? context.fetch(descriptor)) ?? []
            rows[importID] = Dictionary(fetched.map { ($0.sortIndex, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return hits.compactMap { rows[$0.importID]?[$0.sortIndex] }
    }

    /// The group rows of `hits`, in the order of the hits.
    nonisolated static func groups(for hits: [SearchHit], in context: ModelContext) -> [PlaylistChannelGroup] {
        let byImport = Dictionary(grouping: hits, by: \.importID)
        var rows: [UUID: [Int: PlaylistChannelGroup]] = [:]
        for (importID, importHits) in byImport {
            let indexes = importHits.map(\.sortIndex)
            let descriptor = FetchDescriptor<PlaylistChannelGroup>(predicate: #Predicate { $0.importID == importID && indexes.contains($0.sortIndex) })
            let fetched = (try? context.fetch(descriptor)) ?? []
            rows[importID] = Dictionary(fetched.map { ($0.sortIndex, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return hits.compactMap { rows[$0.importID]?[$0.sortIndex] }
    }
}
