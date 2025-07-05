//
//  PlaylistViewModel.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-08.
//

import SwiftData
import SwiftUI

@MainActor
class PlaylistViewModel: ObservableObject {

    private let validator = PlaylistValidator()
    private let downloadManager = DownloadManager()

    @Published var progress: AddPlaylistProgress?

    func addPlaylist(_ createPlaylist: CreatePlaylist, context: ModelContext) async -> Result<Playlist, AddPlaylistError> {
        let playlist = Playlist(uuid: UUID(), name: createPlaylist.name, url: createPlaylist.url, createdOn: .now)
        context.insert(playlist)

        self.progress = .init(message: "Contacting the server...", percentage: 0.01)

        var playlistChannels: [PlaylistChannel] = []
        var playlistChannelGroups: [PlaylistChannelGroup] = []

        do {
            try context.save()

            for await downloadProgress in downloadManager.download(from: playlist.url) {
                self.progress = .init(message: "Downloading...", percentage: downloadProgress.percentage * 0.45)
                guard downloadProgress.error == nil else {
                    throw AddPlaylistError(downloadProgress.error?.localizedDescription ?? "Unknown error")
                }
                guard downloadProgress.isCompleted else {
                    continue
                }

                self.progress = .init(message: "Analyzing downloaded content...", percentage: downloadProgress.percentage * 0.45)
                await Task.yield()

                guard let data = downloadProgress.data else {
                    throw AddPlaylistError("Playlist data is missing")
                }

                for try await validationProgress in validator.validate(playlist: playlist, content: data, playlistChannels: &playlistChannels, playlistChannelGroups: &playlistChannelGroups) {
                    self.progress = .init(message: "Parsing channel \(validationProgress.count)...", percentage: 0.45 + validationProgress.percentage * 0.45)
                    await Task.yield()
                }
            }

            self.progress = .init(message: "Saving channels...", percentage: 0.9)

            for index in 0..<playlistChannels.count {
                context.insert(playlistChannels[index])
                if index.isMultiple(of: 1_000) {
                    self.progress = .init(message: "Saving channels \(index)/\(playlistChannels.count)...", percentage: 0.9 + Double(index) * 0.08 / Double(playlistChannels.count))
                    try context.save()
                    await Task.yield()
                }
            }

            self.progress = .init(message: "Saving channel groups...", percentage: 0.9)

            for index in 0..<playlistChannelGroups.count {
                context.insert(playlistChannelGroups[index])
                if index.isMultiple(of: 10) {
                    self.progress = .init(message: "Saving channel groups \(index)/\(playlistChannelGroups.count)...", percentage: 0.98 + Double(index) * 0.02 / Double(playlistChannelGroups.count))
                    try context.save()
                    await Task.yield()
                }
            }
        } catch let error {
            context.delete(playlist)
            try? context.save()

            self.progress = nil
            await Task.yield()

            return .failure(AddPlaylistError(error.localizedDescription))
        }

        return .success(playlist)
    }

    struct CreatePlaylist {
        let name: String
        let url: URL
    }

    struct AddPlaylistProgress {
        let message: String
        let percentage: Double
    }

    struct AddPlaylistError: LocalizedError {
        let description: String

        init(_ description: String) {
            self.description = description
        }

        var errorDescription: String? {
            description
        }
    }
}
