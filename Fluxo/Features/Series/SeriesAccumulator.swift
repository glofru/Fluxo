//
//  SeriesAccumulator.swift
//  Fluxo
//
//  Collects the series of an import while its entries stream by, in playlist order (`PlaylistImporter` and
//  `SeriesIndexer`): which entry is the first of its series in its category (the "head" that category rows and
//  grids list), and per series its title, artwork, counts and positions, written as `PlaylistSeries` rows once
//  the import is stored.
//

import Foundation
import SwiftData

struct SeriesAccumulator {

    struct Series {
        let key: String
        let title: String
        let year: Int?
        let groupName: String
        let firstSortIndex: Int
        var lastSortIndex: Int
        var artwork: String?
        var episodeCount = 0
        var seasons: Set<Int> = []
    }

    private(set) var ordered: [Series] = []
    private var indexByKey: [String: Int] = [:]
    /// "group|key" of the heads seen so far.
    private var heads: Set<String> = []

    var isEmpty: Bool {
        ordered.isEmpty
    }

    /// Adds an episode; returns whether it is the first of its series in its category (it is then listed).
    mutating func add(_ episode: EpisodeInfo, sortIndex: Int, logo: String?, groupName: String) -> Bool {
        if let index = indexByKey[episode.seriesKey] {
            ordered[index].episodeCount += 1
            ordered[index].seasons.insert(episode.seasonOrDefault)
            ordered[index].lastSortIndex = max(ordered[index].lastSortIndex, sortIndex)
            if ordered[index].artwork == nil, let logo, !logo.isEmpty {
                ordered[index].artwork = logo
            }
        } else {
            indexByKey[episode.seriesKey] = ordered.count
            var series = Series(
                key: episode.seriesKey,
                title: episode.seriesTitle,
                year: episode.year,
                groupName: groupName,
                firstSortIndex: sortIndex,
                lastSortIndex: sortIndex,
                artwork: logo?.isEmpty == false ? logo : nil
            )
            series.episodeCount = 1
            series.seasons.insert(episode.seasonOrDefault)
            ordered.append(series)
        }
        return heads.insert("\(groupName)|\(episode.seriesKey)").inserted
    }

    /// Inserts one `PlaylistSeries` per series (the caller saves).
    func insertRows(importID: UUID, playlistID: UUID, into context: ModelContext) {
        for series in ordered {
            context.insert(PlaylistSeries(
                key: series.key,
                title: series.title,
                year: series.year,
                artwork: series.artwork,
                groupName: series.groupName,
                playlistID: playlistID,
                importID: importID,
                sortIndex: series.firstSortIndex,
                lastSortIndex: series.lastSortIndex,
                episodeCount: series.episodeCount,
                seasonCount: series.seasons.count
            ))
        }
    }
}
