//
//  ChannelLibrary.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import Observation
import os
import SwiftData

/// Value snapshot of a channel for the cards, rows and actions of the UI, built from either a
/// `PlaylistChannel` or a `ChannelBookmark`. Views hand these around instead of models so actions
/// (play, favorite) never depend on a row that a refresh may replace.
struct ChannelItem: Identifiable, Hashable, Sendable {
    /// UUID of the channel row (stable for a bookmark).
    let id: UUID
    let playlistID: UUID
    let name: String?
    let logo: String?
    let url: URL?
    let groupName: String
    let kind: ChannelContentKind

    init(id: UUID, playlistID: UUID, name: String?, logo: String?, url: URL?, groupName: String, kind: ChannelContentKind) {
        self.id = id
        self.playlistID = playlistID
        self.name = name
        self.logo = logo
        self.url = url
        self.groupName = groupName
        self.kind = kind
    }

    init(_ channel: PlaylistChannel) {
        self.init(
            id: channel.uuid,
            playlistID: channel.playlistID,
            name: channel.name,
            logo: channel.logo,
            url: channel.url,
            groupName: channel.groupName,
            kind: channel.kind
        )
    }

    init(_ bookmark: ChannelBookmark) {
        self.init(
            id: bookmark.channelID,
            playlistID: bookmark.playlistID,
            name: bookmark.name,
            logo: bookmark.logo,
            url: bookmark.url,
            groupName: bookmark.groupName,
            kind: bookmark.kind
        )
    }

    var displayName: String {
        guard let name, !name.isEmpty else {
            return "No channel name"
        }
        return name
    }

    /// Bookmark key; nil when the channel has no stream URL (it can be neither played nor bookmarked).
    var bookmarkKey: String? {
        url.map { ChannelBookmark.key(playlistID: playlistID, url: $0) }
    }

    var playable: PlayableChannel {
        PlayableChannel(id: id, name: name, logo: logo, url: url)
    }
}

/// Favorites and watch history, stored as `ChannelBookmark`s in the main context.
///
/// The set of favorite keys is kept in memory (it is small) so every card can show its favorite state
/// without a fetch of its own.
@MainActor
@Observable
final class ChannelLibrary {

    /// Watch history entries kept; older ones are trimmed.
    static let historyLimit = 200

    private static let logger = Logger(subsystem: "com.glofru.Fluxo", category: "ChannelLibrary")

    private(set) var favoriteKeys: Set<String> = []

    @ObservationIgnored
    private let context: ModelContext

    init(container: ModelContainer) {
        context = container.mainContext
        reloadFavorites()
    }

    func isFavorite(_ item: ChannelItem) -> Bool {
        guard let key = item.bookmarkKey else {
            return false
        }
        return favoriteKeys.contains(key)
    }

    func toggleFavorite(_ item: ChannelItem) {
        setFavorite(!isFavorite(item), for: item)
    }

    func setFavorite(_ isFavorite: Bool, for item: ChannelItem) {
        guard let key = item.bookmarkKey else {
            return
        }
        if isFavorite {
            let bookmark = upsertBookmark(for: item, key: key)
            bookmark.isFavorite = true
            bookmark.favoritedOn = .now
            favoriteKeys.insert(key)
        } else {
            favoriteKeys.remove(key)
            guard let bookmark = existingBookmark(key: key) else {
                return
            }
            bookmark.isFavorite = false
            bookmark.favoritedOn = nil
            deleteIfUnused(bookmark)
        }
        save()
    }

    /// Adds the channel to the top of "Continue watching".
    func recordWatch(_ item: ChannelItem) {
        guard let key = item.bookmarkKey else {
            return
        }
        let bookmark = upsertBookmark(for: item, key: key)
        bookmark.lastWatchedAt = .now
        bookmark.watchCount += 1
        save()
        trimHistory()
    }

    func removeFromHistory(_ item: ChannelItem) {
        guard let key = item.bookmarkKey, let bookmark = existingBookmark(key: key) else {
            return
        }
        bookmark.lastWatchedAt = nil
        deleteIfUnused(bookmark)
        save()
    }

    func clearHistory() {
        do {
            for bookmark in try context.fetch(HomeQueries.recents(playlistIDs: nil, limit: Self.historyLimit * 2)) {
                bookmark.lastWatchedAt = nil
                deleteIfUnused(bookmark)
            }
        } catch {
            Self.logger.error("Could not clear the history: \(error.localizedDescription, privacy: .public)")
        }
        save()
    }

    /// Drops the in-memory favorite state of a deleted playlist (its rows are deleted by the importer).
    func forgetPlaylist(_ playlistID: UUID) {
        let prefix = "\(playlistID.uuidString)|"
        favoriteKeys = favoriteKeys.filter { !$0.hasPrefix(prefix) }
    }

    // MARK: - Private

    private func reloadFavorites() {
        var descriptor = HomeQueries.favorites(playlistIDs: nil, limit: 10_000)
        descriptor.propertiesToFetch = [\.key]
        do {
            favoriteKeys = Set(try context.fetch(descriptor).map(\.key))
        } catch {
            Self.logger.error("Could not load favorites: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func existingBookmark(key: String) -> ChannelBookmark? {
        try? context.fetch(HomeQueries.bookmark(key: key)).first
    }

    /// Finds or creates the bookmark and refreshes its snapshot (name and logo may change with a refresh).
    private func upsertBookmark(for item: ChannelItem, key: String) -> ChannelBookmark {
        if let bookmark = existingBookmark(key: key) {
            bookmark.channelID = item.id
            bookmark.name = item.name
            bookmark.logo = item.logo
            bookmark.groupName = item.groupName
            bookmark.kindRawValue = item.kind.rawValue
            return bookmark
        }
        let bookmark = ChannelBookmark(
            key: key,
            playlistID: item.playlistID,
            url: item.url ?? URL(fileURLWithPath: "/"),
            channelID: item.id,
            name: item.name,
            logo: item.logo,
            groupName: item.groupName,
            kind: item.kind
        )
        context.insert(bookmark)
        return bookmark
    }

    private func deleteIfUnused(_ bookmark: ChannelBookmark) {
        if !bookmark.isFavorite && bookmark.lastWatchedAt == nil {
            context.delete(bookmark)
        }
    }

    private func trimHistory() {
        guard let stale = try? context.fetch(HomeQueries.staleHistory(keep: Self.historyLimit)) else {
            return
        }
        guard !stale.isEmpty else {
            return
        }
        for bookmark in stale {
            bookmark.lastWatchedAt = nil
            deleteIfUnused(bookmark)
        }
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Self.logger.error("Could not save the library: \(error.localizedDescription, privacy: .public)")
        }
    }
}
