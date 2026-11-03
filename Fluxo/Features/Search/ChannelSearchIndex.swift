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

/// One channel or group of an import, as the index keeps it.
struct SearchIndexEntry: Sendable {
    let name: SearchName
    /// `sortIndex` of the row: with the import ID it identifies the row through an indexed fetch.
    let sortIndex: Int
    let kindRawValue: Int
}

/// The normalized names of one import.
struct ImportSearchIndex: Sendable {
    let importID: UUID
    let channels: [SearchIndexEntry]
    let groups: [SearchIndexEntry]

    var entryCount: Int {
        channels.count + groups.count
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

    /// How many entries are scored between two cancellation checks.
    static let cancellationCheckInterval = 4_096

    /// Ranks entries: a pass without typos, then, if it found fewer than `limit`, a pass that allows them.
    ///
    /// Returns nothing as soon as the calling task is cancelled (checked every `cancellationCheckInterval`
    /// entries): Search cancels the search of every stale keystroke, and the actor runs one search at a time, so a
    /// stale pass must not delay the current one.
    nonisolated static func rank(_ sources: [(UUID, [SearchIndexEntry])], query: SearchQuery, kind: Int?, limit: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        var unmatched: [(source: Int, entry: Int)] = []
        let allowsTypos = query.tokens.contains { SearchMatcher.typoBudget(forLength: $0.count) > 0 }
        for (sourceIndex, (importID, entries)) in sources.enumerated() {
            for (entryIndex, entry) in entries.enumerated() where kind == nil || entry.kindRawValue == kind {
                if entryIndex % cancellationCheckInterval == 0 && Task.isCancelled {
                    return []
                }
                if let score = SearchMatcher.score(entry.name, query: query, allowTypos: false) {
                    hits.append(SearchHit(importID: importID, sortIndex: entry.sortIndex, score: score, order: sourceIndex, sortKey: entry.sortIndex))
                } else if allowsTypos {
                    unmatched.append((sourceIndex, entryIndex))
                }
            }
        }
        if hits.count < limit && allowsTypos {
            for (position, (sourceIndex, entryIndex)) in unmatched.enumerated() {
                if position % cancellationCheckInterval == 0 && Task.isCancelled {
                    return []
                }
                let (importID, entries) = sources[sourceIndex]
                let entry = entries[entryIndex]
                if let score = SearchMatcher.score(entry.name, query: query, allowTypos: true) {
                    hits.append(SearchHit(importID: importID, sortIndex: entry.sortIndex, score: score, order: sourceIndex, sortKey: entry.sortIndex))
                }
            }
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.sortKey < rhs.sortKey
        }
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
        var channels: [SearchIndexEntry] = []
        var offset = 0
        while true {
            let batch: [SearchIndexEntry] = autoreleasepool {
                let context = ModelContext(container)
                var descriptor = FetchDescriptor<PlaylistChannel>(
                    predicate: #Predicate { $0.importID == importID },
                    sortBy: [SortDescriptor(\.sortIndex)]
                )
                descriptor.propertiesToFetch = [\.name, \.sortIndex, \.kindRawValue]
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = readBatchSize
                let rows = (try? context.fetch(descriptor)) ?? []
                return rows.map { SearchIndexEntry(name: SearchName($0.name ?? ""), sortIndex: $0.sortIndex, kindRawValue: $0.kindRawValue) }
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
        return ImportSearchIndex(importID: importID, channels: channels, groups: groups)
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
