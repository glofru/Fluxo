//
//  SchemaMigrationTests.swift
//  FluxoTests
//
//  The library store (`LibraryStore`, `FluxoSchema`): a store of the first builds (schema 1.0.0, one file) opens with
//  every row kept and moves to 2.0.0 (the library and the cache); a store this build must not touch (newer, damaged)
//  is reported and left as it is. Tools/LibraryCheck checks the same from the sources of an older commit, with a large
//  library.
//

import Foundation
import SwiftData
import Testing
@testable import Fluxo

/// A schema version no build has yet, with the current models: stands for a store written by a newer build.
private enum FutureSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(99, 0, 0)

    static var models: [any PersistentModel.Type] {
        ModelRegistry.user
    }
}

@Suite("Library store and schema migration", .serialized)
struct SchemaMigrationTests {

    /// A new empty folder for one library, removed at the end of the test.
    private final class Folder {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fluxo-tests-library-\(UUID().uuidString)", isDirectory: true)

        init() throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        var location: LibraryStoreLocation {
            .isolated(in: url)
        }
    }

    @Test("A new library opens empty at the current version")
    func newLibrary() throws {
        let folder = try Folder()
        let container = try LibraryStore.open(folder.location).get()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Playlist>()) == 0)
        #expect(!LibraryStore.needsUpgrade(folder.location))
        #expect(try LibraryStore.inspect(folder.location.userStoreURL).get() == FluxoMigrationPlan.currentVersion)
    }

    @Test("The migration plan lists every version in order and ends at the current one")
    func plan() {
        let versions = FluxoMigrationPlan.schemas.map { $0.versionIdentifier }
        #expect(versions == versions.sorted())
        #expect(versions.last == FluxoMigrationPlan.currentVersion)
        #expect(FluxoMigrationPlan.stages.count == versions.count - 1)
        #expect(Set(ModelRegistry.user.map { "\($0)" }).isDisjoint(with: ModelRegistry.cache.map { "\($0)" }), "a model lives in one store")
    }

    @Test("A store of the first builds (1.0.0) opens with every row kept, split into the library and the cache, at 2.0.0")
    func migratesTheFirstBuildsStore() throws {
        let folder = try Folder()
        let location = folder.location
        let playlistID = UUID()
        let importID = UUID()
        let channelID = UUID()
        let created = Date(timeIntervalSince1970: 1_780_000_000)
        let watched = Date(timeIntervalSince1970: 1_790_000_000)
        let streamURL = try #require(URL(string: "http://iptv.example/movie/1.mkv"))

        // The library as the first builds wrote it: one file, schema 1.0.0.
        do {
            let schema = Schema(versionedSchema: FluxoSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: location.userStoreURL, cloudKitDatabase: .none))
            let context = ModelContext(container)
            let playlist = FluxoSchemaV1.Playlist(uuid: playlistID, name: "Legacy", url: try #require(URL(string: "http://iptv.example/list.m3u")), createdOn: created)
            playlist.currentImportID = importID
            playlist.channelCount = 1
            context.insert(playlist)
            let group = FluxoSchemaV1.PlaylistChannelGroup(uuid: UUID(), name: "Movies", playlistID: playlistID, importID: importID)
            group.channelCount = 1
            group.playlist = playlist
            context.insert(group)
            let channel = FluxoSchemaV1.PlaylistChannel(uuid: channelID, groupName: "Movies", playlistID: playlistID, importID: importID)
            channel.name = "The Silent Harbor (2001)"
            channel.url = streamURL
            channel.kindRawValue = ChannelContentKind.movie.rawValue
            context.insert(channel)
            let bookmark = FluxoSchemaV1.ChannelBookmark(key: "legacy-bookmark", playlistID: playlistID, url: streamURL, channelID: channelID, name: "The Silent Harbor (2001)", logo: nil, groupName: "Movies")
            bookmark.isFavorite = true
            bookmark.favoritedOn = created
            bookmark.lastWatchedAt = watched
            bookmark.resumePosition = 1_234.5
            bookmark.knownDuration = 6_000
            bookmark.watchCount = 3
            context.insert(bookmark)
            try context.save()
        }
        #expect(try LibraryStore.inspect(location.userStoreURL).get() == FluxoSchemaV1.versionIdentifier)
        #expect(LibraryStore.needsUpgrade(location))

        let container = try LibraryStore.open(location).get()
        let context = ModelContext(container)
        let playlist = try #require(try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.uuid == playlistID })).first)
        #expect(playlist.name == "Legacy")
        #expect(playlist.createdOn == created)
        #expect(playlist.currentImportID == importID)
        let bookmark = try #require(try context.fetch(FetchDescriptor<ChannelBookmark>()).first)
        #expect(bookmark.key == "legacy-bookmark")
        #expect(bookmark.isFavorite)
        #expect(bookmark.lastWatchedAt == watched)
        #expect(bookmark.resumePosition == 1_234.5)
        #expect(bookmark.watchCount == 3)
        let channels = try context.fetch(FetchDescriptor<PlaylistChannel>())
        #expect(channels.map(\.uuid) == [channelID])
        #expect(channels.first?.kind == .movie)
        #expect(try context.fetchCount(FetchDescriptor<PlaylistChannelGroup>()) == 1)

        #expect(try LibraryStore.inspect(location.userStoreURL).get() == FluxoSchemaV2.versionIdentifier)
        #expect(FileManager.default.fileExists(atPath: location.cacheStoreURL.path), "the cache has its own store")
    }

    @Test("A store written by a newer build is reported, never opened or changed")
    func newerVersion() throws {
        let folder = try Folder()
        let location = folder.location
        let schema = Schema(versionedSchema: FutureSchema.self)
        let configuration = ModelConfiguration(schema: schema, url: location.userStoreURL, cloudKitDatabase: .none)
        do {
            let context = ModelContext(try ModelContainer(for: schema, configurations: configuration))
            context.insert(Playlist(uuid: UUID(), name: "From the Future", url: URL(fileURLWithPath: "/tmp/future.m3u"), createdOn: .now))
            try context.save()
        }
        #expect(try LibraryStore.inspect(location.userStoreURL).get() == FutureSchema.versionIdentifier)

        #expect(LibraryStore.open(location).failure == .newerVersion)
        // Left as it is: still at its version, with its rows (the bytes of the file are no measure: SQLite may still
        // be moving the write-ahead log of the store's own container into it).
        #expect(try LibraryStore.inspect(location.userStoreURL).get() == FutureSchema.versionIdentifier)
        let playlists = try ModelContext(try ModelContainer(for: schema, configurations: configuration)).fetch(FetchDescriptor<Playlist>())
        #expect(playlists.map(\.name) == ["From the Future"])
        #expect(!FileManager.default.fileExists(atPath: location.cacheStoreURL.path), "no cache was made for it")
    }

    @Test("A file that is not a database is reported as damaged and left as it is")
    func damagedStore() throws {
        let folder = try Folder()
        let location = folder.location
        let garbage = Data("this is not an SQLite database, only a damaged file".utf8)
        try garbage.write(to: location.userStoreURL)

        #expect(LibraryStore.inspect(location.userStoreURL).failure == .damaged)
        #expect(LibraryStore.open(location).failure == .damaged)
        #expect(try Data(contentsOf: location.userStoreURL) == garbage)
    }

    @Test("A cache that cannot be opened is recreated; the library is kept")
    func damagedCache() throws {
        let folder = try Folder()
        let location = folder.location
        let playlistID = UUID()
        do {
            let container = try LibraryStore.open(location).get()
            let context = ModelContext(container)
            context.insert(Playlist(uuid: playlistID, name: "Kept", url: URL(fileURLWithPath: "/tmp/kept.m3u"), createdOn: .now))
            try context.save()
        }
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: location.cacheStoreURL.path + suffix)
        }
        try Data("damaged cache".utf8).write(to: location.cacheStoreURL)

        let container = try LibraryStore.open(location).get()
        let playlists = try ModelContext(container).fetch(FetchDescriptor<Playlist>())
        #expect(playlists.map(\.uuid) == [playlistID])
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self {
            return failure
        }
        return nil
    }
}
