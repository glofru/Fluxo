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
    /// Position in the user's order of the favorites (ascending). New favorites get a negative value from the
    /// clock, so they come first until the list is reordered by hand (`ChannelLibrary.reorderFavorites`).
    var favoriteOrder: Double = 0
    var lastWatchedAt: Date?
    var watchCount: Int = 0
    /// Movies and series: where playback stopped (seconds), 0 when not started or watched to the end.
    var resumePosition: Double = 0
    /// Movies and series: the duration reported by the player (seconds), 0 when unknown.
    var knownDuration: Double = 0

    // The series of an episode (`EpisodeRef`), so the history can show and group episodes by series.
    var seriesKey: String?
    var seriesTitle: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var episodeTitle: String?

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

    var episodeRef: EpisodeRef? {
        guard let seriesKey, let seriesTitle, let episodeNumber else {
            return nil
        }
        return EpisodeRef(seriesKey: seriesKey, seriesTitle: seriesTitle, season: seasonNumber, episode: episodeNumber, episodeTitle: episodeTitle)
    }

    func setEpisode(_ episode: EpisodeRef?) {
        seriesKey = episode?.seriesKey
        seriesTitle = episode?.seriesTitle
        seasonNumber = episode?.season
        episodeNumber = episode?.episode
        episodeTitle = episode?.episodeTitle
    }

    /// `favoriteOrder` for a new favorite: before every existing one (reordered favorites use 0, 1, 2, …).
    static func topFavoriteOrder(now: Date = .now) -> Double {
        -now.timeIntervalSinceReferenceDate
    }
}

/// How far an on-demand item was watched.
struct WatchProgress: Hashable, Sendable {
    let position: TimeInterval
    let duration: TimeInterval

    init?(_ bookmark: ChannelBookmark) {
        guard bookmark.resumePosition >= WatchProgress.minimumPosition, bookmark.knownDuration > 0 else {
            return nil
        }
        position = bookmark.resumePosition
        duration = bookmark.knownDuration
    }

    /// Below this, playback restarts from the beginning (a few seconds of a trailer are not worth resuming).
    static let minimumPosition: TimeInterval = 30

    /// 0...1.
    var fraction: Double {
        duration > 0 ? min(1, max(0, position / duration)) : 0
    }

    var remaining: TimeInterval {
        max(0, duration - position)
    }

    /// The last 3 % (at most 5 minutes: the credits) count as watched to the end.
    static func isFinished(position: TimeInterval, duration: TimeInterval) -> Bool {
        position >= duration - min(300, duration * 0.03)
    }
}
