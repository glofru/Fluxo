//
//  Playlist.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-08.
//

import Foundation
import SwiftData

/// A user playlist. It owns its channels and groups: deleting a playlist deletes them too.
///
/// Channel and group rows are tagged with the `importID` of the download that produced them. Only rows whose
/// `importID` equals `currentImportID` are shown, so a refresh can write a complete new copy next to the old one
/// and switch over atomically (and a failed or cancelled refresh leaves the old content untouched).
///
/// Ownership: channels, groups and series reference their playlist through the indexed `playlistID` / `importID` keys,
/// never a relationship. The playlist is user data and lives in the library store, its content is a cache in the cache
/// store (`LibraryStore`), and a relationship cannot span two stores. (With a SwiftData inverse to-one, every insert
/// would also re-materialize the playlist's to-many array, which makes importing quadratic: 20k channels 5.1 s with
/// the relationship vs 0.48 s without.) `PlaylistImporter.deletePlaylist` removes the content with batch deletes, and
/// `purgeOrphanedContent()` removes the rows of playlists deleted any other way.
@Model
final class Playlist: Identifiable {
    #Index<Playlist>([\.createdOn])

    @Attribute(.unique)
    private(set) var uuid: UUID
    var name: String
    var url: URL
    private(set) var createdOn: Date

    /// Import whose channels are currently visible; nil until the first import completes.
    var currentImportID: UUID?
    var lastRefreshedOn: Date?
    var channelCount: Int = 0
    var groupCount: Int = 0
    /// XMLTV guide URLs from the playlist header (`url-tvg` / `x-tvg-url`), comma-separated, as found by the
    /// last import; nil when the playlist announces none. The TV guide turns them into `EPGSource`s.
    var guideURLString: String?
    /// When `guideURLString` was last read from the playlist header (nil for playlists imported before the
    /// TV guide existed: the guide reads their header once, see `EPGImporter.discoverHeaderGuides`).
    var guideHeaderCheckedOn: Date?
    /// `EpisodeParser.version` the visible import was grouped into series with; 0 for imports made before series
    /// existed. `SeriesIndexer` indexes imports with an older version again at launch.
    var seriesIndexVersion: Int = 0

    init(uuid: UUID, name: String, url: URL, createdOn: Date) {
        self.uuid = uuid
        self.name = name
        self.url = url
        self.createdOn = createdOn
    }
}

@Model
final class PlaylistChannel: Identifiable, Equatable {
    #Index<PlaylistChannel>([\.importID, \.groupName, \.sortIndex], [\.importID, \.sortIndex], [\.playlistID])

    private(set) var uuid: UUID
    var name: String?
    var logo: String?
    var tvgID: String?
    var duration: Int?
    /// Name of the group (group-title / #EXTGRP) the channel belongs to; empty when the playlist has none.
    @Attribute(originalName: "group")
    var groupName: String
    var url: URL?
    /// Position of the entry in the playlist file.
    var sortIndex: Int = 0
    /// UUID of the owning playlist (see `Playlist` for why this is not a relationship).
    var playlistID: UUID = UUID()
    /// Import that wrote this row; the channel is visible when it equals `Playlist.currentImportID`.
    var importID: UUID = UUID()
    /// `ChannelContentKind` raw value, classified once at import time (live TV, movie or series).
    var kindRawValue: Int = 0

    // Series (`EpisodeParser`): set for on-demand entries named like episodes, nil otherwise.

    /// `EpisodeInfo.seriesKey`: the episodes of a series in an import share it (the series page fetches by it).
    /// No index of its own: the series page reads one import's rows by `importID` in a few tens of ms at 100k
    /// entries, and an index would slow every import down.
    var seriesKey: String?
    /// Season, number, series title and episode title, for display only, packed into one attribute
    /// (`StoredEpisode`): every attribute of a model costs time on each insert, about 0.25 s per 100k entries.
    var episodeData: String?
    /// Whether category rows and grids list the entry: every entry, except the episodes of a series after the
    /// first one of its category (the series "head" stands for the whole series there, as a series card).
    var isListed: Bool = true

    init(
        uuid: UUID,
        name: String? = nil,
        logo: String? = nil,
        tvgID: String? = nil,
        duration: Int? = nil,
        groupName: String = "",
        url: URL? = nil,
        sortIndex: Int = 0,
        importID: UUID = UUID(),
        playlistID: UUID,
        kind: ChannelContentKind = .live
    ) {
        self.uuid = uuid
        self.name = name
        self.logo = logo
        self.tvgID = tvgID
        self.duration = duration
        self.groupName = groupName
        self.url = url
        self.sortIndex = sortIndex
        self.playlistID = playlistID
        self.importID = importID
        self.kindRawValue = kind.rawValue
    }

    var isLiveContent: Bool {
        url?.pathExtension.isEmpty ?? false
    }

    var kind: ChannelContentKind {
        ChannelContentKind(rawValue: kindRawValue) ?? .live
    }

    /// The series of an episode, as the UI hands it around.
    var episodeRef: EpisodeRef? {
        guard let seriesKey, let episodeData, let stored = StoredEpisode(episodeData) else {
            return nil
        }
        return EpisodeRef(seriesKey: seriesKey, seriesTitle: stored.seriesTitle, season: stored.season, episode: stored.episode, episodeTitle: stored.episodeTitle)
    }

    /// Stores what the parser found (or clears it).
    func apply(_ episode: EpisodeInfo?, isListed: Bool) {
        seriesKey = episode?.seriesKey
        episodeData = episode.map { StoredEpisode($0).rawValue }
        self.isListed = isListed
    }

    /// Whether the row already stores what `apply(episode, isListed:)` would write.
    func matches(_ episode: EpisodeInfo?, isListed: Bool) -> Bool {
        seriesKey == episode?.seriesKey && self.isListed == isListed && episodeData == episode.map { StoredEpisode($0).rawValue }
    }

    static func == (lhs: PlaylistChannel, rhs: PlaylistChannel) -> Bool {
        lhs.uuid == rhs.uuid
    }
}

/// A group of channels inside one import of a playlist. Channels are linked by `groupName` + `importID`
/// (no to-many array), so a group never duplicates its channels and inserts stay linear.
/// The display fields of an episode as `PlaylistChannel.episodeData` stores them: season, number, series title
/// and episode title, separated by U+001F (removed from the titles, M3U names never carry it). The season is
/// empty when the name gives none.
struct StoredEpisode: Hashable, Sendable {
    static let separator: Character = "\u{1F}"

    let season: Int?
    let episode: Int
    let seriesTitle: String
    let episodeTitle: String?

    init(_ info: EpisodeInfo) {
        season = info.season
        episode = info.episode
        seriesTitle = info.seriesTitle
        episodeTitle = info.episodeTitle
    }

    init?(_ rawValue: String) {
        let parts = rawValue.split(separator: Self.separator, maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let episode = Int(parts[1]) else {
            return nil
        }
        season = parts[0].isEmpty ? nil : Int(parts[0])
        self.episode = episode
        seriesTitle = String(parts[2])
        episodeTitle = parts[3].isEmpty ? nil : String(parts[3])
    }

    var rawValue: String {
        let separator = String(Self.separator)
        let clean = { (text: String) in text.contains(Self.separator) ? text.replacingOccurrences(of: separator, with: " ") : text }
        return [season.map(String.init) ?? "", String(episode), clean(seriesTitle), clean(episodeTitle ?? "")].joined(separator: separator)
    }
}

@Model
final class PlaylistChannelGroup: Identifiable {
    #Index<PlaylistChannelGroup>([\.importID, \.sortIndex], [\.importID, \.kindRawValue, \.sortIndex], [\.playlistID])

    private(set) var uuid: UUID
    var name: String
    /// Order of first appearance in the playlist file.
    var sortIndex: Int = 0
    var channelCount: Int = 0
    var playlistID: UUID = UUID()
    var importID: UUID = UUID()
    /// Most common `ChannelContentKind` of the group's channels; decides the Home section it is listed in.
    var kindRawValue: Int = 0
    /// Entries the group lists (`PlaylistChannel.isListed`): its channels and movies, and one card per series;
    /// 0 for groups imported before series existed (then every channel is listed).
    var listedCount: Int = 0
    /// Series among the listed entries.
    var seriesCount: Int = 0

    init(uuid: UUID, name: String, sortIndex: Int, channelCount: Int, importID: UUID, playlistID: UUID, kind: ChannelContentKind = .live) {
        self.uuid = uuid
        self.kindRawValue = kind.rawValue
        self.name = name
        self.sortIndex = sortIndex
        self.channelCount = channelCount
        self.playlistID = playlistID
        self.importID = importID
    }

    /// Title to show for the group; playlists without group-title end up in a single unnamed group.
    var displayName: String {
        name.isEmpty ? String(localized: "Other", comment: "Name of the category that holds the channels without a category.") : name
    }

    var kind: ChannelContentKind {
        ChannelContentKind(rawValue: kindRawValue) ?? .live
    }
}

/// Value snapshot of a channel for the player, so playback state never holds on to a SwiftData model
/// that a refresh or delete may remove in the background.
struct PlayableChannel: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String?
    let logo: String?
    let url: URL?

    init(id: UUID, name: String?, logo: String?, url: URL?) {
        self.id = id
        self.name = name
        self.logo = logo
        self.url = url
    }

    init(_ channel: PlaylistChannel) {
        self.init(id: channel.uuid, name: channel.name, logo: channel.logo, url: channel.url)
    }

    var isLiveContent: Bool {
        url?.pathExtension.isEmpty ?? false
    }
}
