//
//  SeriesModels.swift
//  Fluxo
//
//  Series of a playlist: the episodes of on-demand entries named like "Breaking Bad S01 E01" are grouped by
//  `EpisodeParser` at import time. Each episode keeps its series key, season and number on its
//  `PlaylistChannel`; `PlaylistSeries` sums up a series of an import (title, artwork, counts) for Home, Search
//  and the series page; `SeriesBookmark` keeps what the viewer did with a series (favorite, last episode,
//  watched episodes) across playlist refreshes.
//

import Foundation
import SwiftData

/// One series of one import. Written with the import's channels (`PlaylistImporter`, `SeriesIndexer`), and
/// deleted with them.
@Model
final class PlaylistSeries {
    #Index<PlaylistSeries>([\.importID, \.sortIndex], [\.importID, \.key], [\.playlistID])

    /// `EpisodeInfo.seriesKey`.
    private(set) var key: String
    var title: String
    var year: Int?
    /// The first poster among the episodes (providers usually give every episode the series poster).
    var artwork: String?
    /// Category of the first episode.
    var groupName: String
    private(set) var playlistID: UUID
    private(set) var importID: UUID
    /// Position of the first episode in the playlist.
    var sortIndex: Int
    /// Position of the last episode (providers append new episodes at the end).
    var lastSortIndex: Int
    var episodeCount: Int
    var seasonCount: Int

    init(key: String, title: String, year: Int?, artwork: String?, groupName: String, playlistID: UUID, importID: UUID, sortIndex: Int, lastSortIndex: Int, episodeCount: Int, seasonCount: Int) {
        self.key = key
        self.title = title
        self.year = year
        self.artwork = artwork
        self.groupName = groupName
        self.playlistID = playlistID
        self.importID = importID
        self.sortIndex = sortIndex
        self.lastSortIndex = lastSortIndex
        self.episodeCount = episodeCount
        self.seasonCount = seasonCount
    }
}

/// What the viewer did with a series: favorite, the episode watched last, the episodes watched to the end.
///
/// Keyed by playlist + series key (`SeriesItem.bookmarkKey`), like `ChannelBookmark`, so it survives refreshes,
/// and deleted with its playlist. The resume position of each episode stays on the episode's `ChannelBookmark`.
@Model
final class SeriesBookmark {
    #Index<SeriesBookmark>([\.playlistID], [\.isFavorite, \.favoritedOn], [\.lastWatchedAt])

    @Attribute(.unique)
    private(set) var key: String
    private(set) var playlistID: UUID
    private(set) var seriesKey: String
    /// Snapshot for the Home rows (the series may be gone from a refreshed playlist).
    var title: String
    var artwork: String?
    var groupName: String

    var isFavorite: Bool = false
    var favoritedOn: Date?
    /// Same scale as `ChannelBookmark.favoriteOrder`, so series and channel favorites can be listed together.
    var favoriteOrder: Double = 0

    var lastWatchedAt: Date?
    /// The episode watched last.
    var lastEpisodeURL: URL?
    var lastSeason: Int?
    var lastEpisode: Int?
    /// `EpisodeCode`s of the episodes watched to the end or marked as watched.
    var watchedEpisodeCodes: [String] = []

    init(key: String, playlistID: UUID, seriesKey: String, title: String, artwork: String?, groupName: String) {
        self.key = key
        self.playlistID = playlistID
        self.seriesKey = seriesKey
        self.title = title
        self.artwork = artwork
        self.groupName = groupName
    }

    static func key(playlistID: UUID, seriesKey: String) -> String {
        "\(playlistID.uuidString)|\(seriesKey)"
    }
}

/// The series an episode belongs to, carried by `ChannelItem`.
struct EpisodeRef: Hashable, Sendable {
    let seriesKey: String
    let seriesTitle: String
    let season: Int?
    let episode: Int
    let episodeTitle: String?

    var code: EpisodeCode {
        EpisodeCode(season: season ?? 1, episode: episode)
    }
}

/// Season and episode, as `SeriesBookmark` stores watched episodes ("1:3"). Ordered season first.
struct EpisodeCode: Hashable, Comparable, Sendable {
    let season: Int
    let episode: Int

    init(season: Int, episode: Int) {
        self.season = season
        self.episode = episode
    }

    init?(_ rawValue: String) {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let season = Int(parts[0]), let episode = Int(parts[1]) else {
            return nil
        }
        self.init(season: season, episode: episode)
    }

    var rawValue: String {
        "\(season):\(episode)"
    }

    static func < (lhs: EpisodeCode, rhs: EpisodeCode) -> Bool {
        (lhs.season, lhs.episode) < (rhs.season, rhs.episode)
    }
}

/// A series as the UI hands it around (cards, the series page, search results).
struct SeriesItem: Identifiable, Hashable, Sendable {
    let playlistID: UUID
    let key: String
    let title: String
    let artwork: String?
    let groupName: String
    var year: Int?
    /// nil when unknown (a series card built from one of its episodes).
    var episodeCount: Int?
    var seasonCount: Int?

    var id: String {
        bookmarkKey
    }

    var bookmarkKey: String {
        SeriesBookmark.key(playlistID: playlistID, seriesKey: key)
    }

    init(playlistID: UUID, key: String, title: String, artwork: String?, groupName: String, year: Int? = nil, episodeCount: Int? = nil, seasonCount: Int? = nil) {
        self.playlistID = playlistID
        self.key = key
        self.title = title
        self.artwork = artwork
        self.groupName = groupName
        self.year = year
        self.episodeCount = episodeCount
        self.seasonCount = seasonCount
    }

    init(_ series: PlaylistSeries) {
        self.init(
            playlistID: series.playlistID,
            key: series.key,
            title: series.title,
            artwork: series.artwork,
            groupName: series.groupName,
            year: series.year,
            episodeCount: series.episodeCount,
            seasonCount: series.seasonCount
        )
    }

    init(_ bookmark: SeriesBookmark) {
        self.init(playlistID: bookmark.playlistID, key: bookmark.seriesKey, title: bookmark.title, artwork: bookmark.artwork, groupName: bookmark.groupName)
    }

    /// "3 seasons · 30 episodes", "12 episodes"; nil when the counts are unknown.
    var countsLine: String? {
        guard let episodes = episodesLine else {
            return nil
        }
        guard let seasonCount, seasonCount > 1 else {
            return episodes
        }
        return TextParts.line([String(localized: "\(seasonCount) seasons", comment: "Number of seasons of a series."), episodes])
    }

    /// "30 episodes" (where "3 seasons · 30 episodes" does not fit); nil when the count is unknown.
    var episodesLine: String? {
        episodeCount.map { String(localized: "\($0) episodes", comment: "Number of episodes of a series.") }
    }
}

extension ChannelItem {
    /// The series of an episode, as a card or the series page show it.
    var seriesItem: SeriesItem? {
        guard let series else {
            return nil
        }
        return SeriesItem(playlistID: playlistID, key: series.seriesKey, title: series.seriesTitle, artwork: logo, groupName: groupName)
    }

    /// The item with other artwork (an episode shown with its series' poster).
    func replacingLogo(_ logo: String) -> ChannelItem {
        ChannelItem(id: id, playlistID: playlistID, name: name, logo: logo, url: url, groupName: groupName, kind: kind, tvgID: tvgID, number: number, series: series)
    }

    /// Bookmark key of the episode's series; nil for anything that is not an episode.
    var seriesBookmarkKey: String? {
        series.map { SeriesBookmark.key(playlistID: playlistID, seriesKey: $0.seriesKey) }
    }

    /// "S1 E3", "E12" (no season), as the guide writes episode numbers.
    var episodeLabel: String? {
        series.map(EpisodeFormat.code)
    }
}

/// How episodes are written.
enum EpisodeFormat {

    /// "S1 E3", or "E12" for an episode without a season (the same keys as the guide's episode labels).
    static func code(_ episode: EpisodeRef) -> String {
        code(season: episode.season, episode: episode.episode)
    }

    static func code(season: Int?, episode: Int) -> String {
        if let season {
            return String(localized: "S\(season) E\(episode)", comment: "Short season and episode label of a TV programme, as in 'S1 E5'. Keep it very short.")
        }
        return String(localized: "E\(episode)", comment: "Short episode label of a TV programme, as in 'E5'. Keep it very short.")
    }

    /// The title of an episode: its own ("Ozymandias"), or "Episode 14".
    static func title(_ episode: EpisodeRef) -> String {
        if let title = episode.episodeTitle, !title.isEmpty {
            return title
        }
        return String(localized: "Episode \(episode.episode)", comment: "Title of an episode that has no title of its own; the number is the episode number.")
    }

    /// "Season 2", or "Specials" for season 0.
    static func seasonTitle(_ season: Int) -> String {
        season == 0
            ? String(localized: "Specials", comment: "Season 0 of a series: the specials.")
            : String(localized: "Season \(season)", comment: "A season of a series; the number is the season number.")
    }

    /// For VoiceOver: "Season 1, episode 3".
    static func spokenCode(_ episode: EpisodeRef) -> String {
        if let season = episode.season {
            return String(localized: "Season \(season), episode \(episode.episode)", comment: "VoiceOver: the season and episode number of an episode.")
        }
        return String(localized: "Episode \(episode.episode)")
    }
}

extension Notification.Name {
    /// Posted on the main actor when episodes or bookmarks were linked to their series after the library was
    /// loaded (the launch backfill of `SeriesIndexer`, an import): `SeriesLibrary` reads its bookmarks again.
    static let seriesIndexDidChange = Notification.Name("FluxoSeriesIndexDidChange")
}
