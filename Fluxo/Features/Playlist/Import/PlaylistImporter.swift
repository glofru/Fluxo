//
//  PlaylistImporter.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import os
import SwiftData

/// Progress of a running import, delivered at most a few times per second.
struct PlaylistImportProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case connecting
        case downloading
        case finalizing
    }

    var phase: Phase
    /// Download fraction, when the server sent a Content-Length.
    var fractionCompleted: Double?
    var channelCount: Int

    static let connecting = PlaylistImportProgress(phase: .connecting, fractionCompleted: nil, channelCount: 0)

    var message: String {
        switch phase {
        case .connecting:
            return String(localized: "Contacting the server…", comment: "Playlist import progress.")
        case .downloading:
            return String(localized: "Imported \(channelCount) channels…", comment: "Playlist import progress while downloading; the number grows as channels are read.")
        case .finalizing:
            return String(localized: "Finishing \(channelCount) channels…", comment: "Playlist import progress while the channels are saved.")
        }
    }
}

struct PlaylistImportSummary: Sendable {
    let channelCount: Int
    let groupCount: Int
    let duration: Duration
}

enum PlaylistImportError: LocalizedError {
    case playlistNotFound
    case noChannels

    var errorDescription: String? {
        switch self {
        case .playlistNotFound:
            return String(localized: "The playlist no longer exists.", comment: "Playlist import error: the playlist was deleted during the import.")
        case .noChannels:
            return String(localized: "No channels found. Is this an M3U playlist?", comment: "Playlist import error: the downloaded file has no channels.")
        }
    }
}

/// Downloads, parses and stores playlists entirely off the main actor.
///
/// The body is streamed from the network into `M3UParser`, and entries are inserted in batches into short-lived
/// background `ModelContext`s (autosave off, one save per batch, so the context's registered objects are released
/// after every batch). The UI only receives throttled progress values.
actor PlaylistImporter {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "PlaylistImporter")

    private let container: ModelContainer
    private let batchSize: Int
    private let progressInterval: Duration

    /// Imports that are writing rows right now; their rows must survive `purgeOrphanedContent()`.
    private var runningImports: Set<UUID> = []

    init(container: ModelContainer, batchSize: Int = 2_000, progressInterval: Duration = .milliseconds(150)) {
        self.container = container
        self.batchSize = batchSize
        self.progressInterval = progressInterval
    }

    // MARK: - Playlists

    func createPlaylist(uuid: UUID, name: String, url: URL) throws {
        let context = makeContext()
        context.insert(Playlist(uuid: uuid, name: name, url: url, createdOn: .now))
        try context.save()
    }

    /// Deletes a playlist with all of its channels, groups, favorites and watch history. Channels are bulk-deleted
    /// first so the cascade rule does not have to fault tens of thousands of rows into memory.
    func deletePlaylist(uuid: UUID) throws {
        let context = makeContext()
        try context.delete(model: PlaylistChannel.self, where: #Predicate { $0.playlistID == uuid })
        try context.delete(model: PlaylistChannelGroup.self, where: #Predicate { $0.playlistID == uuid })
        try context.delete(model: ChannelBookmark.self, where: #Predicate { $0.playlistID == uuid })
        if let playlist = try fetchPlaylist(uuid: uuid, in: context) {
            context.delete(playlist)
        }
        try context.save()
    }

    /// Removes channel and group rows that no playlist shows: leftovers of an import that was interrupted
    /// (crash, force quit) or of an older store layout. Also drops bookmarks of playlists that no longer exist.
    func purgeOrphanedContent() throws {
        let context = makeContext()
        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        let keep = Array(Set(playlists.compactMap(\.currentImportID)).union(runningImports))
        let playlistIDs = playlists.map(\.uuid)
        try context.delete(model: PlaylistChannel.self, where: #Predicate { !keep.contains($0.importID) })
        try context.delete(model: PlaylistChannelGroup.self, where: #Predicate { !keep.contains($0.importID) })
        try context.delete(model: ChannelBookmark.self, where: #Predicate { !playlistIDs.contains($0.playlistID) })
        try context.save()
    }

    // MARK: - Import

    /// Downloads `url` and replaces the content of the playlist with it.
    ///
    /// The new rows are written under a fresh import ID and only become visible when everything has been stored;
    /// then the previous import is deleted. If the download fails or the calling task is cancelled, the new rows are
    /// removed and the playlist keeps its previous content.
    func importContent(
        ofPlaylist playlistUUID: UUID,
        from url: URL,
        progress: @escaping @Sendable (PlaylistImportProgress) -> Void
    ) async throws -> PlaylistImportSummary {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let importID = UUID()
        runningImports.insert(importID)
        defer {
            runningImports.remove(importID)
        }

        progress(.connecting)

        guard try fetchPlaylist(uuid: playlistUUID, in: makeContext()) != nil else {
            throw PlaylistImportError.playlistNotFound
        }

        var parser = M3UParser()
        var batch: [M3UEntry] = []
        batch.reserveCapacity(batchSize)
        var groups = GroupAccumulator()
        var stored = 0
        var lastProgressAt = clock.now

        do {
            for try await chunk in DownloadManager.stream(from: url) {
                parser.consume(chunk.data) { batch.append($0) }
                if batch.count >= batchSize {
                    try Task.checkCancellation()
                    try store(batch, startingAt: stored, importID: importID, playlistUUID: playlistUUID, groups: &groups)
                    stored += batch.count
                    batch.removeAll(keepingCapacity: true)
                }

                let now = clock.now
                if now - lastProgressAt >= progressInterval {
                    lastProgressAt = now
                    progress(PlaylistImportProgress(phase: .downloading, fractionCompleted: chunk.fractionCompleted, channelCount: stored + batch.count))
                }
            }
            // AsyncThrowingStream ends quietly when the consuming task is cancelled.
            try Task.checkCancellation()

            parser.finish { batch.append($0) }
            progress(PlaylistImportProgress(phase: .finalizing, fractionCompleted: 1, channelCount: stored + batch.count))
            if !batch.isEmpty {
                try store(batch, startingAt: stored, importID: importID, playlistUUID: playlistUUID, groups: &groups)
                stored += batch.count
                batch.removeAll()
            }

            guard stored > 0 else {
                throw PlaylistImportError.noChannels
            }
            try Task.checkCancellation()

            let groupCount = try commit(importID: importID, playlistUUID: playlistUUID, channelCount: stored, groups: groups, guideURLs: parser.guideURLs)
            let summary = PlaylistImportSummary(channelCount: stored, groupCount: groupCount, duration: clock.now - startedAt)
            Self.logger.info("Imported \(summary.channelCount) channels in \(summary.groupCount) groups in \(String(describing: summary.duration), privacy: .public)")
            return summary
        } catch {
            discard(importID: importID)
            throw error
        }
    }

    // MARK: - Private

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func fetchPlaylist(uuid: UUID, in context: ModelContext) throws -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Inserts one batch in its own context and saves it, so memory stays bounded by the batch size.
    private func store(_ entries: [M3UEntry], startingAt firstIndex: Int, importID: UUID, playlistUUID: UUID, groups: inout GroupAccumulator) throws {
        let context = makeContext()
        // Stop early if the playlist was deleted while downloading.
        var exists = FetchDescriptor<Playlist>(predicate: #Predicate { $0.uuid == playlistUUID })
        exists.fetchLimit = 1
        guard try context.fetchCount(exists) > 0 else {
            throw PlaylistImportError.playlistNotFound
        }

        for (offset, entry) in entries.enumerated() {
            let groupName = entry.group ?? ""
            let url = URL(string: entry.url)
            let name = entry.displayName
            let kind = ChannelContentKind.classify(url: url, groupName: groupName, name: name)
            groups.add(groupName, kind: kind)
            context.insert(PlaylistChannel(
                uuid: UUID(),
                name: name,
                logo: entry.logo,
                tvgID: entry.tvgID,
                duration: entry.duration,
                groupName: groupName,
                url: url,
                sortIndex: firstIndex + offset,
                importID: importID,
                playlistID: playlistUUID,
                kind: kind
            ))
        }
        try context.save()
    }

    /// Writes the groups, makes the new import visible, then drops the previous one.
    private func commit(importID: UUID, playlistUUID: UUID, channelCount: Int, groups: GroupAccumulator, guideURLs: [String]) throws -> Int {
        let context = makeContext()
        guard let playlist = try fetchPlaylist(uuid: playlistUUID, in: context) else {
            throw PlaylistImportError.playlistNotFound
        }

        var newGroups: [PlaylistChannelGroup] = []
        newGroups.reserveCapacity(groups.ordered.count)
        for (index, group) in groups.ordered.enumerated() {
            let model = PlaylistChannelGroup(
                uuid: UUID(),
                name: group.name,
                sortIndex: index,
                channelCount: group.count,
                importID: importID,
                playlistID: playlistUUID,
                kind: group.kind
            )
            context.insert(model)
            newGroups.append(model)
        }
        // One assignment links all groups (and their inverses) in linear time.
        playlist.groups = (playlist.groups ?? []) + newGroups
        let previousImportID = playlist.currentImportID
        playlist.currentImportID = importID
        playlist.channelCount = channelCount
        playlist.groupCount = groups.ordered.count
        playlist.lastRefreshedOn = .now
        playlist.guideURLString = guideURLs.isEmpty ? nil : guideURLs.joined(separator: ",")
        playlist.guideHeaderCheckedOn = .now
        // Save the switch first so the UI moves to the new rows before the old ones disappear.
        try context.save()

        if let previousImportID {
            do {
                try context.delete(model: PlaylistChannel.self, where: #Predicate { $0.importID == previousImportID })
                try context.delete(model: PlaylistChannelGroup.self, where: #Predicate { $0.importID == previousImportID })
                try context.save()
            } catch {
                // The new content is already live; leftovers are cleaned up by the next purge.
                Self.logger.error("Failed to delete previous import: \(error.localizedDescription)")
            }
        }
        return groups.ordered.count
    }

    private func discard(importID: UUID) {
        do {
            let context = makeContext()
            try context.delete(model: PlaylistChannel.self, where: #Predicate { $0.importID == importID })
            try context.delete(model: PlaylistChannelGroup.self, where: #Predicate { $0.importID == importID })
            try context.save()
        } catch {
            Self.logger.error("Failed to discard import: \(error.localizedDescription)")
        }
    }
}

/// Group names in order of first appearance with their channel counts per content kind.
private struct GroupAccumulator {
    struct Group {
        let name: String
        var liveCount = 0
        var movieCount = 0
        var seriesCount = 0

        var count: Int {
            liveCount + movieCount + seriesCount
        }

        var kind: ChannelContentKind {
            ChannelContentKind.dominant(live: liveCount, movie: movieCount, series: seriesCount)
        }

        mutating func add(_ kind: ChannelContentKind) {
            switch kind {
            case .live:
                liveCount += 1
            case .movie:
                movieCount += 1
            case .series:
                seriesCount += 1
            }
        }
    }

    private(set) var ordered: [Group] = []
    private var indexByName: [String: Int] = [:]

    mutating func add(_ name: String, kind: ChannelContentKind) {
        if let index = indexByName[name] {
            ordered[index].add(kind)
        } else {
            indexByName[name] = ordered.count
            var group = Group(name: name)
            group.add(kind)
            ordered.append(group)
        }
    }
}
