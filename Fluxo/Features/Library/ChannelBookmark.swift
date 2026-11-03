//
//  ChannelBookmark.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import SwiftData

/// A favorite and/or recently watched channel.
///
/// Channel rows are rewritten with new UUIDs by every playlist refresh, so favorites and the watch history
/// cannot live on `PlaylistChannel`. A bookmark is keyed by playlist + stream URL instead, which survives
/// refreshes, and it keeps a small snapshot (name, logo, group) so the Home rows can show and play it without
/// looking the channel up. Bookmarks are deleted with their playlist (`PlaylistImporter.deletePlaylist` and
/// `purgeOrphanedContent`).
@Model
final class ChannelBookmark {
    #Index<ChannelBookmark>([\.playlistID], [\.isFavorite, \.favoritedOn], [\.lastWatchedAt])

    /// `ChannelBookmark.key(playlistID:url:)`.
    @Attribute(.unique)
    private(set) var key: String
    private(set) var playlistID: UUID
    private(set) var url: URL
    /// UUID of the channel row last seen with this URL; used as a stable identity for the player.
    var channelID: UUID
    var name: String?
    var logo: String?
    var groupName: String
    var kindRawValue: Int = 0
    /// `tvg-id` of the channel, so the TV guide can match favorites and history entries too.
    var tvgID: String?

    var isFavorite: Bool = false
    var favoritedOn: Date?
    var lastWatchedAt: Date?
    var watchCount: Int = 0

    init(key: String, playlistID: UUID, url: URL, channelID: UUID, name: String?, logo: String?, groupName: String, kind: ChannelContentKind) {
        self.key = key
        self.playlistID = playlistID
        self.url = url
        self.channelID = channelID
        self.name = name
        self.logo = logo
        self.groupName = groupName
        self.kindRawValue = kind.rawValue
    }

    static func key(playlistID: UUID, url: URL) -> String {
        "\(playlistID.uuidString)|\(url.absoluteString)"
    }

    var kind: ChannelContentKind {
        ChannelContentKind(rawValue: kindRawValue) ?? .live
    }
}
