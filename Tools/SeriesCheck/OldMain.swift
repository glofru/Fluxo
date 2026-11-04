//
//  OldMain.swift
//  Fluxo
//
//  Compiled with the sources of the version before series grouping (Tools/SeriesCheck/run.sh): imports the
//  synthetic playlist into an on-disk store and saves the history entry of an episode watched to the end, as
//  that version did. `check backfill` then opens the store with the current schema.
//
//  Usage: old <store.sqlite> <playlist.m3u>
//

import Foundation
import SwiftData

@main
struct OldStore {
    static func main() async throws {
        let storeURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let playlist = URL(fileURLWithPath: CommandLine.arguments[2])
        let schema = Schema(ModelRegistry.all)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
        let importer = PlaylistImporter(container: container)
        let playlistID = UUID()
        try await importer.createPlaylist(uuid: playlistID, name: "Old Library", url: playlist)
        let summary = try await importer.importContent(ofPlaylist: playlistID, from: playlist) { _ in }
        let context = ModelContext(container)
        let series = ChannelContentKind.series.rawValue
        var descriptor = FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.kindRawValue == series }, sortBy: [SortDescriptor(\.sortIndex)])
        descriptor.fetchLimit = 1
        guard let episode = try context.fetch(descriptor).first, let url = episode.url else {
            print("old: no episode")
            exit(1)
        }
        let bookmark = ChannelBookmark(key: ChannelBookmark.key(playlistID: playlistID, url: url), playlistID: playlistID, url: url, channelID: episode.uuid, name: episode.name, logo: episode.logo, groupName: episode.groupName, kind: episode.kind)
        bookmark.lastWatchedAt = .now
        bookmark.watchCount = 1
        bookmark.knownDuration = 2_700
        bookmark.resumePosition = 0
        context.insert(bookmark)
        try context.save()
        print("old: imported \(summary.channelCount) entries in \(summary.duration.formatted(.units(allowed: [.milliseconds]))); history: \(episode.name ?? "")")
    }
}
