//
//  FeaturedLoader.swift
//  Fluxo
//
//  Reads the store for the featured billboard (iPhone, iPad, Mac) and the Apple TV hero: the categories of the
//  scope, the viewer's taste, and a few entries of each category the picker (`FeaturedPicker`) tries. Off the main
//  actor, on its own context, returning values.
//

import Foundation
import os
import SwiftData

enum FeaturedLoader {

    static let itemCount = 8
    /// History entries Continue Watching shows (`RecentlyWatchedRow.fetchLimit`): not featured again.
    static let continueWatchingCount = 20

    #if DEBUG
    /// Debug harness (`featured-series:<playlist>`): the billboard starts with its series.
    nonisolated static let debugLeadKindKey = "debug.featuredLeadKind"
    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Featured")
    #endif

    /// The pages for the playlists of `importIDs` and the rotation's `seed`.
    @concurrent static func load(importIDs: [UUID], seed: UInt64, hidesAdultContent: Bool, container: ModelContainer) async -> [ChannelItem] {
        guard !importIDs.isEmpty else {
            return []
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let groups = (try? context.fetch(HomeQueries.allGroups(importIDs: importIDs))) ?? []
        let categories = groups.map { group in
            FeaturedPicker.Category(
                importID: group.importID,
                playlistID: group.playlistID,
                name: group.name,
                kind: group.kind,
                // Groups imported before series existed have no listed count: every entry is listed.
                entryCount: group.listedCount > 0 ? group.listedCount : group.channelCount
            )
        }
        // Adult content is left out unless it is all the scope has.
        let onlyAdult = !categories.isEmpty && categories.allSatisfy { MatureContent.isAdult(group: $0.name) }
        let filter = MatureContentFilter(isActive: hidesAdultContent && !onlyAdult)

        let history = ((try? context.fetch(HomeQueries.recents(playlistIDs: nil, limit: 60))) ?? []).map(BookmarkSnapshot.init)
        let favorites = ((try? context.fetch(HomeQueries.favorites(playlistIDs: nil, limit: 60))) ?? []).map(BookmarkSnapshot.init)
        let taste = FeaturedPicker.Taste(TasteProfile(history: history, favorites: favorites), continueWatching: continueWatchingCount)

        var picker = FeaturedPicker(categories: categories, count: itemCount, seed: seed, filter: filter, taste: taste)
        var picks = picker.pick { category, offset, limit in
            let entries = ((try? context.fetch(HomeQueries.featured(importID: category.importID, groupName: category.name, offset: offset, limit: limit))) ?? []).map(ChannelItem.init)
            return withArtwork(entries, container: container)
        }
        if picks.count < itemCount {
            // Categories without enough artwork: a window of the whole scope fills the pages left.
            picks = picker.fill(with: fallbackEntries(importIDs: importIDs, seed: seed, context: context, container: container))
        }
        #if DEBUG
        if UserDefaults.fluxo.string(forKey: debugLeadKindKey) == "series", let index = picks.firstIndex(where: { $0.series != nil }) {
            picks.insert(picks.remove(at: index), at: 0)
        }
        // The pages, for the harness's checks: only with an isolated library (`-FluxoDebugStore`, the seeded names).
        if DebugEnvironment.shared != nil {
            let pages = picks.map { "\($0.series?.seriesTitle ?? $0.displayName) [\($0.groupName), \($0.kind)]" }.joined(separator: " | ")
            logger.notice("Featured (seed \(seed, privacy: .public), adult filter \(filter.isActive, privacy: .public)): \(pages, privacy: .public)")
        }
        #endif
        return picks
    }

    /// A window of the scope's entries with artwork (on-demand ones first, as the billboard was designed for posters).
    private static func fallbackEntries(importIDs: [UUID], seed: UInt64, context: ModelContext, container: ModelContainer) -> [ChannelItem] {
        var descriptor = HomeQueries.featured(importIDs: importIDs, onDemand: true)
        var count = (try? context.fetchCount(descriptor)) ?? 0
        if count < 3 {
            descriptor = HomeQueries.featured(importIDs: importIDs, onDemand: false)
            count = (try? context.fetchCount(descriptor)) ?? 0
        }
        guard count > 0 else {
            return []
        }
        let fetched = itemCount * 6
        descriptor.fetchOffset = Int(seed % UInt64(max(1, count - fetched + 1)))
        descriptor.fetchLimit = fetched
        let entries = ((try? context.fetch(descriptor)) ?? []).map(ChannelItem.init)
        return withArtwork(entries, container: container)
    }

    /// The entries with their artwork: a series whose first episode has none shows the series' poster (from a later
    /// episode); one without any is left out.
    static func withArtwork(_ entries: [ChannelItem], container: ModelContainer) -> [ChannelItem] {
        let withoutArtwork = entries.compactMap { $0.logo == nil ? $0.seriesItem : nil }
        var posters: [String: String] = [:]
        if !withoutArtwork.isEmpty {
            for series in SeriesLookup.summaries(of: withoutArtwork, in: container) {
                posters[series.bookmarkKey] = series.artwork
            }
        }
        return entries.compactMap { item -> ChannelItem? in
            guard item.logo == nil else {
                return item
            }
            return item.seriesBookmarkKey.flatMap { posters[$0] }.map(item.replacingLogo)
        }
    }
}
