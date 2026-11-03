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
/// Ownership:
/// - Groups are a real relationship with a cascade rule on the playlist side (`groups` <-> `PlaylistChannelGroup.playlist`).
/// - Channels reference their playlist through the indexed `playlistID` / `importID` keys instead of a relationship.
///   With a SwiftData inverse to-one, every insert re-materializes the playlist's to-many array, which makes importing
///   quadratic (measured with batched saves: 20k channels 5.1 s with the relationship vs 0.48 s without).
///   `PlaylistImporter.deletePlaylist` removes channels with one batch delete, and `purgeOrphanedContent()` removes
///   rows of playlists deleted any other way.
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

    /// Optional because SwiftData batch deletes of groups fail on a non-optional inverse to-many.
    /// Never read this for display; query groups by `importID` instead.
    @Relationship(deleteRule: .cascade, inverse: \PlaylistChannelGroup.playlist)
    var groups: [PlaylistChannelGroup]? = []

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

    static func == (lhs: PlaylistChannel, rhs: PlaylistChannel) -> Bool {
        lhs.uuid == rhs.uuid
    }
}

/// A group of channels inside one import of a playlist. Channels are linked by `groupName` + `importID`
/// (no to-many array), so a group never duplicates its channels and inserts stay linear.
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

    var playlist: Playlist?

    /// Attach new groups by assigning `Playlist.groups` once, not by setting `playlist` on each group:
    /// SwiftData rebuilds the inverse array on every per-object assignment.
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
        name.isEmpty ? "Other" : name
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
