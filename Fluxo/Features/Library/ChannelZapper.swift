//
//  ChannelZapper.swift
//  Fluxo
//
//  Channel up / down: finds the previous or next channel of the group the playing channel belongs to.
//

import Foundation
import OSLog
import SwiftData

/// Finds neighbors of a channel inside its group, in playlist order, wrapping around at both ends.
///
/// Every lookup is a single-row fetch on the `(importID, groupName, sortIndex)` index of the visible import,
/// so zapping costs the same on a 100-channel and on a 100k-channel playlist.
@MainActor
final class ChannelZapper {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "ChannelZapper")

    private let context: ModelContext
    private let library: ChannelLibrary

    init(container: ModelContainer, library: ChannelLibrary) {
        context = container.mainContext
        self.library = library
    }

    /// The channel `offset` positions away (+1 next, -1 previous) from `item` in its group, or nil when the
    /// group has no other playable channel (or the playlist is gone).
    func neighbor(of item: ChannelItem, offset: Int) -> ChannelItem? {
        guard offset != 0 else {
            return nil
        }
        do {
            guard let importID = try context.fetch(HomeQueries.playlist(uuid: item.playlistID)).first?.currentImportID,
                  let sortIndex = try sortIndex(of: item, importID: importID) else {
                return nil
            }
            let forward = offset > 0
            let group = item.groupName
            let next = try context.fetch(HomeQueries.adjacentChannel(importID: importID, groupName: group, sortIndex: sortIndex, forward: forward)).first
                ?? context.fetch(HomeQueries.edgeChannel(importID: importID, groupName: group, first: forward)).first
            guard let next, next.sortIndex != sortIndex else {
                return nil
            }
            return ChannelItem(next)
        } catch {
            Self.logger.error("Channel lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Adds a channel reached by zapping to the watch history, like a channel picked from a card.
    func recordWatch(_ item: ChannelItem) {
        library.recordWatch(item)
    }

    private func sortIndex(of item: ChannelItem, importID: UUID) throws -> Int? {
        if let channel = try context.fetch(HomeQueries.channel(importID: importID, groupName: item.groupName, uuid: item.id)).first {
            return channel.sortIndex
        }
        // Favorites and history keep the UUID of the row they were created from; a refresh replaces it.
        guard let url = item.url else {
            return nil
        }
        return try context.fetch(HomeQueries.channel(importID: importID, groupName: item.groupName, url: url)).first?.sortIndex
    }
}
