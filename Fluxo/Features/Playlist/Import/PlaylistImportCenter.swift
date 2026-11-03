//
//  PlaylistImportCenter.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import SwiftData

/// Main-actor front end for playlist imports: starts, refreshes, cancels and deletes playlists,
/// and publishes throttled progress for every running import, keyed by playlist UUID.
@MainActor
final class PlaylistImportCenter: ObservableObject {

    struct Failure: Identifiable {
        let id = UUID()
        let playlistName: String
        let message: String
    }

    @Published private(set) var progress: [UUID: PlaylistImportProgress] = [:]
    /// Last error of a background refresh or delete, for the UI to present.
    @Published var failure: Failure?

    private struct RunningImport {
        let token: UUID
        let task: Task<PlaylistImportSummary, Error>
    }

    private let importer: PlaylistImporter
    private var running: [UUID: RunningImport] = [:]

    init(container: ModelContainer) {
        let importer = PlaylistImporter(container: container)
        self.importer = importer
        Task.detached(priority: .utility) {
            try? await importer.purgeOrphanedContent()
        }
    }

    /// Creates a playlist and imports its channels. Cancelling the calling task (or `cancelImport`) stops the
    /// download, removes the partially imported rows and the playlist, and throws `CancellationError`.
    @discardableResult
    func addPlaylist(uuid: UUID = UUID(), name: String, url: URL) async throws -> PlaylistImportSummary {
        try await importer.createPlaylist(uuid: uuid, name: name, url: url)
        let task = startImport(playlistUUID: uuid, url: url)
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            try? await importer.deletePlaylist(uuid: uuid)
            throw error
        }
    }

    /// Re-downloads the playlist and replaces its channels. The current channels stay visible until the new ones
    /// are stored; on failure they are kept and `failure` is set.
    func refresh(_ playlist: Playlist) {
        let uuid = playlist.uuid
        let name = playlist.name
        guard running[uuid] == nil else {
            return
        }
        let task = startImport(playlistUUID: uuid, url: playlist.url)
        Task { [weak self] in
            do {
                _ = try await task.value
            } catch is CancellationError {
                // Cancelled by the user: nothing to report.
            } catch {
                self?.failure = Failure(playlistName: name, message: error.localizedDescription)
            }
        }
    }

    func cancelImport(for playlistUUID: UUID) {
        running[playlistUUID]?.task.cancel()
    }

    /// Cancels any import of the playlist, then deletes it with all its channels in the background.
    func delete(_ playlist: Playlist) {
        let uuid = playlist.uuid
        let name = playlist.name
        let pending = running[uuid]?.task
        pending?.cancel()
        Task { [weak self, importer] in
            _ = await pending?.result
            do {
                try await importer.deletePlaylist(uuid: uuid)
            } catch {
                self?.failure = Failure(playlistName: name, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Private

    private func startImport(playlistUUID: UUID, url: URL) -> Task<PlaylistImportSummary, Error> {
        let token = UUID()
        progress[playlistUUID] = .connecting

        let task = Task { [weak self, importer] in
            try await importer.importContent(ofPlaylist: playlistUUID, from: url) { update in
                Task { @MainActor in
                    self?.updateProgress(update, for: playlistUUID, token: token)
                }
            }
        }
        running[playlistUUID] = RunningImport(token: token, task: task)

        Task { [weak self] in
            _ = await task.result
            self?.finishImport(for: playlistUUID, token: token)
        }
        return task
    }

    private func updateProgress(_ update: PlaylistImportProgress, for playlistUUID: UUID, token: UUID) {
        // Drop updates that arrive after the import finished or was replaced.
        guard running[playlistUUID]?.token == token else {
            return
        }
        progress[playlistUUID] = update
    }

    private func finishImport(for playlistUUID: UUID, token: UUID) {
        guard running[playlistUUID]?.token == token else {
            return
        }
        running[playlistUUID] = nil
        progress[playlistUUID] = nil
    }
}
