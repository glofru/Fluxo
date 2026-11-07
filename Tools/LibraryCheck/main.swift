//
//  main.swift
//  Fluxo
//
//  Checks the library store (`LibraryStore`, `FluxoSchema`) on a library written by the previous version
//  (`OldMain.swift`), and the downloads list (`DownloadManifest`). See run.sh.
//
//  Usage:
//     check migrate <legacy folder> <work folder>   the whole scenario list below, each on a copy of the legacy library
//     check downloads                               the downloads list fixtures
//

import CoreData
import Foundation
import SQLite3
import SwiftData

@main
enum LibraryCheck {

    /// Only the main task counts failures (the checks run one after another).
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("  ok   \(message)")
        } else {
            failures += 1
            print("  FAIL \(message)")
        }
    }

    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "migrate" where arguments.count == 3:
            try await migrate(legacy: URL(fileURLWithPath: arguments[1]), work: URL(fileURLWithPath: arguments[2]))
        case "relaunch" where arguments.count == 2:
            try relaunch(work: URL(fileURLWithPath: arguments[1]))
        case "downloads":
            try downloads()
        default:
            print("usage: check migrate <legacy folder> <work folder> | check downloads")
            exit(2)
        }
        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("All checks passed")
    }

    // MARK: - Library store

    @MainActor
    static func migrate(legacy: URL, work: URL) async throws {
        let fileManager = FileManager.default
        let expectedRows = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: legacy.appendingPathComponent("user-rows.json")))
        let expectedCache = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: legacy.appendingPathComponent("cache-counts.json")))
        let userRowCount = expectedRows.values.reduce(0) { $0 + $1.count }
        print("  legacy library: \(userRowCount) user rows, cache \(expectedCache)")

        /// A fresh copy of the legacy library (the store files only).
        func copy(_ name: String) throws -> LibraryStoreLocation {
            let folder = work.appendingPathComponent(name, isDirectory: true)
            try? fileManager.removeItem(at: folder)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = legacy.appendingPathComponent("default.store" + suffix)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.copyItem(at: source, to: folder.appendingPathComponent("default.store" + suffix))
                }
            }
            return LibraryStoreLocation.isolated(in: folder, userStoreName: "default.store")
        }

        print("== split and migration of a library of the previous version")
        let location = try copy("split")
        let sizeBefore = fileSize(location.userStoreURL) + fileSize(URL(fileURLWithPath: location.userStoreURL.path + "-wal"))
        let started = Date()
        guard case .success(let container) = LibraryStore.open(location) else {
            expect(false, "the library of the previous version opens")
            return
        }
        print(String(format: "  opened (split, migrated) in %.0f ms", Date().timeIntervalSince(started) * 1_000))
        expect(try Fixture.dumpUserRows(container) == expectedRows, "every attribute of every user row is unchanged (\(userRowCount) rows)")
        expect(try Fixture.cacheCounts(container) == expectedCache, "the cache keeps the channels, categories, series and the guide: \(try Fixture.cacheCounts(container))")
        expect(fileManager.fileExists(atPath: location.cacheStoreURL.path), "the cache store exists")
        expect(readMaintenanceNotes(location) == ["compactUserStore"], "only the compaction is left, for the next launch")
        expect(version(of: location.userStoreURL) == "2.0.0" && version(of: location.cacheStoreURL) == "2.0.0", "both stores are at 2.0.0 (\(version(of: location.userStoreURL) ?? "?"), \(version(of: location.cacheStoreURL) ?? "?"))")
        expect(rowCount("ZEPGPROGRAMME", in: location.userStoreURL) == 0 && rowCount("ZPLAYLISTCHANNEL", in: location.userStoreURL) == 0, "the library file holds no cache rows")
        expect(rowCount("ZPLAYLIST", in: location.cacheStoreURL) == 0 && rowCount("ZCHANNELBOOKMARK", in: location.cacheStoreURL) == 0, "the cache file holds no user rows")
        try Data("\(sizeBefore)".utf8).write(to: work.appendingPathComponent("size-before"))
        expect(rowCount("ACHANGE", in: location.userStoreURL) == 0 && rowCount("ACHANGE", in: location.cacheStoreURL) == 0, "no persistent history is left in either store")
        expect(isExcludedFromBackup(location.cacheStoreURL.deletingLastPathComponent()), "the cache folder is excluded from backups")
        let playlists = try await PlaylistImporter(container: container).playlistsMissingContent()
        expect(playlists.isEmpty, "no playlist needs its content again")
        let resetGuides = try await EPGImporter(container: container).resetSourcesMissingContent()
        expect(resetGuides == 0, "no guide needs loading again")
        // A save that touches both stores (as an import's commit does), then a delete across them.
        try await roundTrip(container)

        print("== a second launch")
        let reopenStarted = Date()
        if case .success(let again) = LibraryStore.open(location) {
            print(String(format: "  opened in %.0f ms", Date().timeIntervalSince(reopenStarted) * 1_000))
            expect(try Fixture.cacheCounts(again)["EPGProgramme"] == expectedCache["EPGProgramme"], "the same library opens again")
            // What the app does once the library is open (off the main thread): the round trip's history goes.
            expect(rowCount("ACHANGE", in: location.userStoreURL) > 0 || rowCount("ACHANGE", in: location.cacheStoreURL) > 0, "the round trip left history")
            let pruneStarted = Date()
            StoreHistory.prune(in: again, before: reopenStarted)
            print(String(format: "  history of earlier launches pruned in %.0f ms", Date().timeIntervalSince(pruneStarted) * 1_000))
            expect(rowCount("ACHANGE", in: location.userStoreURL) == 0 && rowCount("ACHANGE", in: location.cacheStoreURL) == 0, "the history of earlier launches is pruned")
        } else {
            expect(false, "the same library opens again")
        }

        print("== the cache store is lost (purged, restored backup, deleted)")
        let lost = try copy("cache-lost")
        _ = LibraryStore.open(lost)
        LibraryStore.removeStoreFiles(at: lost.cacheStoreURL)
        if case .success(let reopened) = LibraryStore.open(lost) {
            expect(try Fixture.dumpUserRows(reopened) == expectedRows, "the user rows are unchanged")
            expect(try Fixture.cacheCounts(reopened).values.allSatisfy { $0 == 0 }, "the cache is empty")
            let missing = try await PlaylistImporter(container: reopened).playlistsMissingContent()
            expect(missing.count == 1, "the playlist is imported again")
            let reset = try await EPGImporter(container: reopened).resetSourcesMissingContent()
            let sources = try ModelContext(reopened).fetch(FetchDescriptor<EPGSource>())
            expect(reset == 1 && sources.allSatisfy { $0.contentHash == nil || $0.currentImportID != nil }, "the loaded guide loads again, its validators gone (\(reset) reset)")
        } else {
            expect(false, "a library without its cache opens")
        }

        print("== the cache store is damaged")
        let damagedCache = try copy("cache-damaged")
        _ = LibraryStore.open(damagedCache)
        LibraryStore.removeStoreFiles(at: damagedCache.cacheStoreURL)
        try Data(repeating: 0x5A, count: 8_192).write(to: damagedCache.cacheStoreURL)
        if case .success(let reopened) = LibraryStore.open(damagedCache) {
            expect(try Fixture.dumpUserRows(reopened) == expectedRows, "it is recreated; the user rows are unchanged")
        } else {
            expect(false, "a library with a damaged cache opens")
        }

        print("== the library store is damaged")
        let damaged = try copy("user-damaged")
        _ = LibraryStore.open(damaged)
        var bytes = try Data(contentsOf: damaged.userStoreURL)
        bytes.replaceSubrange(0..<16, with: Data(repeating: 0x00, count: 16))
        try bytes.write(to: damaged.userStoreURL)
        let damagedHash = digest(of: damaged.userStoreURL)
        expect(LibraryStore.open(damaged).failure == .damaged, "reported as damaged")
        expect(digest(of: damaged.userStoreURL) == damagedHash, "the file is left exactly as it was")
        let archive = try LibraryStore.makeArchive(of: damaged.userStoreURL)
        expect(fileSize(archive) > 0, "Export a Copy makes a ZIP (\(fileSize(archive) / 1_024) KB)")
        try LibraryStore.startOver(damaged)
        let backups = LibraryStore.backups(damaged)
        expect(backups.count == 1 && digest(of: backups[0].directory.appendingPathComponent("default.store")) == damagedHash, "Start Over keeps the file as a backup, unchanged")
        if case .success(let fresh) = LibraryStore.open(damaged) {
            expect(try ModelContext(fresh).fetchCount(FetchDescriptor<Playlist>()) == 0, "then an empty library opens")
        } else {
            expect(false, "an empty library opens after Start Over")
        }

        print("== a library written by a newer version")
        let newer = work.appendingPathComponent("newer", isDirectory: true)
        try? fileManager.removeItem(at: newer)
        try fileManager.createDirectory(at: newer, withIntermediateDirectories: true)
        let newerLocation = LibraryStoreLocation.isolated(in: newer, userStoreName: "default.store")
        try writeNewerStore(at: newerLocation.userStoreURL)
        let newerHash = digest(of: newerLocation.userStoreURL)
        expect(LibraryStore.open(newerLocation).failure == .newerVersion, "reported as written by a newer version")
        expect(digest(of: newerLocation.userStoreURL) == newerHash, "the file is left exactly as it was")

        print("== a split interrupted before the clone")
        let interrupted = try copy("interrupted")
        try Data(#"{"purgeUserStore":true,"purgeCacheStore":true}"#.utf8).write(to: interrupted.maintenanceURL)
        if case .success(let resumed) = LibraryStore.open(interrupted) {
            expect(try Fixture.dumpUserRows(resumed) == expectedRows && (try Fixture.cacheCounts(resumed)) == expectedCache, "it is done again at the next launch, nothing lost")
            expect(readMaintenanceNotes(interrupted) == ["compactUserStore"], "and finished (the compaction waits for the next launch)")
        } else {
            expect(false, "an interrupted split finishes")
        }

        print("== a new installation")
        let fresh = work.appendingPathComponent("fresh", isDirectory: true)
        try? fileManager.removeItem(at: fresh)
        let freshLocation = LibraryStoreLocation.isolated(in: fresh, userStoreName: "default.store")
        if case .success(let empty) = LibraryStore.open(freshLocation) {
            expect(try ModelContext(empty).fetchCount(FetchDescriptor<Playlist>()) == 0 && version(of: freshLocation.userStoreURL) == "2.0.0", "two empty stores at 2.0.0")
        } else {
            expect(false, "a new installation opens")
        }
    }

    /// The launch after the split, in a process of its own (as the app's next launch is): the library file is
    /// compacted before anything opens it.
    @MainActor
    static func relaunch(work: URL) throws {
        print("== the launch after the split (a new process)")
        let location = LibraryStoreLocation.isolated(in: work.appendingPathComponent("split", isDirectory: true), userStoreName: "default.store")
        let sizeBefore = Int(String(decoding: try Data(contentsOf: work.appendingPathComponent("size-before")), as: UTF8.self)) ?? 0
        let started = Date()
        guard case .success(let container) = LibraryStore.open(location) else {
            expect(false, "the library opens")
            return
        }
        print(String(format: "  opened (compacted) in %.0f ms", Date().timeIntervalSince(started) * 1_000))
        let sizeAfter = fileSize(location.userStoreURL) + fileSize(URL(fileURLWithPath: location.userStoreURL.path + "-wal"))
        expect(sizeAfter < sizeBefore / 4, "the library file was compacted: \(sizeBefore / 1_024) KB -> \(sizeAfter / 1_024) KB")
        expect(!FileManager.default.fileExists(atPath: location.maintenanceURL.path), "no maintenance left")
        expect(try ModelContext(container).fetchCount(FetchDescriptor<ChannelBookmark>()) > 0, "the user rows are there")
    }

    /// Writes into both stores in one save, reads back, deletes across both (as deleting a playlist does).
    @MainActor
    private static func roundTrip(_ container: ModelContainer) async throws {
        let context = ModelContext(container)
        let playlistID = UUID()
        let importID = UUID()
        let playlist = Playlist(uuid: playlistID, name: "Round Trip", url: URL(fileURLWithPath: "/round-trip.m3u"), createdOn: .now)
        playlist.currentImportID = importID
        context.insert(playlist)
        context.insert(PlaylistChannel(uuid: UUID(), name: "One", groupName: "G", url: URL(string: "http://example.com/1"), importID: importID, playlistID: playlistID))
        context.insert(PlaylistChannelGroup(uuid: UUID(), name: "G", sortIndex: 0, channelCount: 1, importID: importID, playlistID: playlistID))
        try context.save()
        let fresh = ModelContext(container)
        let channels = try fresh.fetchCount(FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.playlistID == playlistID }))
        let playlists = try fresh.fetchCount(FetchDescriptor<Playlist>(predicate: #Predicate { $0.uuid == playlistID }))
        expect(channels == 1 && playlists == 1, "a save across both stores reads back")
        try await PlaylistImporter(container: container).deletePlaylist(uuid: playlistID)
        let left = try fresh.fetchCount(FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.playlistID == playlistID }))
            + fresh.fetchCount(FetchDescriptor<PlaylistChannelGroup>(predicate: #Predicate { $0.playlistID == playlistID }))
            + fresh.fetchCount(FetchDescriptor<Playlist>(predicate: #Predicate { $0.uuid == playlistID }))
        expect(left == 0, "deleting a playlist deletes its content in the cache store")
    }

    /// A store of a schema 3.0.0 this build does not know.
    private static func writeNewerStore(at url: URL) throws {
        let schema = Schema(versionedSchema: FutureSchema.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.insert(FutureSchema.Playlist(uuid: UUID(), name: "From the future"))
        try context.save()
    }

    enum FutureSchema: VersionedSchema {
        static let versionIdentifier = Schema.Version(3, 0, 0)
        static var models: [any PersistentModel.Type] {
            [Playlist.self]
        }

        @Model
        final class Playlist {
            @Attribute(.unique) var uuid: UUID
            var name: String
            var addedInVersion3: String = "new"

            init(uuid: UUID, name: String) {
                self.uuid = uuid
                self.name = name
            }
        }
    }

    // MARK: - Downloads list

    static func downloads() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("library-check-downloads-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: folder)
        }
        func unreadableCopies() -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(DownloadManifest.unreadableCopyPrefix) }
        }
        func keptFolders() -> Set<UUID> {
            guard let data = try? Data(contentsOf: DownloadManifest.keptFoldersURL(in: folder)), let ids = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(ids.compactMap(UUID.init(uuidString:)))
        }
        /// A list element by its id, as a JSON object (to compare contents).
        func entryObject(id: UUID, in data: Data) throws -> NSDictionary? {
            let list = try JSONSerialization.jsonObject(with: data) as? [Any] ?? []
            return list.compactMap { $0 as? NSDictionary }.first { $0["id"] as? String == id.uuidString }
        }
        func recordJSON(_ id: UUID, _ playlistID: UUID) -> String {
            """
            {"id":"\(id)","item":{"id":"\(UUID())","playlistID":"\(playlistID)","name":"Record","url":"http://example.com/\(id).mp4"},"status":"completed","addedOn":"2026-11-01T10:00:00Z"}
            """
        }
        let known = UUID()
        let olderBuild = UUID()
        let newerBuild = UUID()
        let broken = UUID()
        let orphan = UUID()
        let playlistID = UUID()
        // A record as this build writes it, one of an earlier build (no fraction, languages, retries…), one of a later
        // build (a status and a failure reason this build does not know, a field it does not have), one this build
        // cannot read (no link), and a value that is not a record at all.
        let json = """
        [
          {"id":"\(known)","item":{"id":"\(UUID())","playlistID":"\(playlistID)","name":"Known","url":"http://example.com/a.mp4","groupName":"Movies","kindRawValue":1},
           "status":"completed","method":"file","addedOn":"2026-11-01T10:00:00Z","fraction":1,"bytesWritten":10,"bytesOnDisk":10,
           "failureIsPermanent":false,"allowsCellular":false,"automaticRetries":0,"isMissing":false},
          {"id":"\(olderBuild)","item":{"id":"\(UUID())","playlistID":"\(playlistID)","url":"http://example.com/b.mp4"},
           "status":"failed","addedOn":"2026-10-01T10:00:00Z","failureReason":{"other":{"_0":"unknown error"}}},
          {"id":"\(newerBuild)","item":{"id":"\(UUID())","playlistID":"\(playlistID)","name":"Later","url":"http://example.com/c.mp4","kindRawValue":2},
           "status":"uploading","method":"teleport","addedOn":"2026-12-01T10:00:00Z","failureReason":{"quantum":{}},"futureField":42},
          {"id":"\(broken)","item":{"id":"\(UUID())","playlistID":"\(playlistID)"},"status":"completed"},
          17
        ]
        """
        try Data(json.utf8).write(to: DownloadManifest.url(in: folder))
        for id in [known, olderBuild, newerBuild, broken, orphan] {
            try fileManager.createDirectory(at: folder.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
        }

        print("== lenient reading")
        var read = DownloadManifest.read(in: folder)
        expect(read.records.map(\.id) == [known, olderBuild, newerBuild], "the three readable records are kept, in order (\(read.records.count))")
        expect(read.unreadableCount == 2 && read.unreadableIDs == [broken] && read.unreadableWithoutID == 1, "the unreadable ones are counted, with the id that could be read")
        if read.records.count == 3 {
            let older = read.records[1]
            expect(older.fraction == 0 && older.automaticRetries == 0 && older.item.groupName == "" && older.item.kind == .movie, "missing fields take their defaults")
            expect(older.failureMessage == DownloadFailure.Reason.unexpectedMessage, "\"unknown error\" from an earlier build reads as a sentence: \(older.failureMessage ?? "nil")")
            let newer = read.records[2]
            expect(newer.status == .failed && newer.method == nil && newer.failureReason == .unexpected, "unknown values of a later build: failed, to probe again, an unexpected stop")
        }
        expect(unreadableCopies().isEmpty, "a list whose unreadable records are written back needs no copy")
        expect(keptFolders() == [broken], "the folder of the unreadable record is kept on disk (\(keptFolders()))")

        print("== orphan sweep")
        expect(DownloadManifest.orphanedFolders(in: folder, read: read, records: read.records).isEmpty, "no sweep while a record's id is unknown")
        var complete = read
        complete.unreadableWithoutID = 0
        let orphans = DownloadManifest.orphanedFolders(in: folder, read: complete, records: complete.records)
        expect(orphans.map(\.lastPathComponent) == [orphan.uuidString], "only the folder nobody owns is an orphan (\(orphans.map(\.lastPathComponent)))")

        print("== writing and reading back")
        let brokenJSON = try entryObject(id: broken, in: Data(contentsOf: DownloadManifest.url(in: folder)))
        try DownloadManifest.write(read.records, keeping: &read, in: folder)
        let again = DownloadManifest.read(in: folder)
        expect(again.records == read.records, "what this build writes, it reads back")
        expect(again.unreadableCount == 2 && again.unreadableIDs == [broken], "the records it cannot read are written back")
        let rewrittenJSON = try entryObject(id: broken, in: Data(contentsOf: DownloadManifest.url(in: folder)))
        expect(brokenJSON != nil && rewrittenJSON == brokenJSON, "with every field they had")
        expect(DownloadManifest.orphanedFolders(in: folder, read: again, records: again.records).isEmpty, "still no sweep while a record's id is unknown")

        print("== a record of a newer build, after a save and a relaunch")
        // Without the record that has no id, the sweep runs: it must spare the folder of the one with an id.
        var withID = DownloadManifest.decode(Data("[\(recordJSON(known, playlistID)), \(String(decoding: try JSONSerialization.data(withJSONObject: brokenJSON ?? [:]), as: UTF8.self))]".utf8))
        try DownloadManifest.write(withID.records, keeping: &withID, in: folder)
        var relaunch = DownloadManifest.read(in: folder)
        try DownloadManifest.write(relaunch.records, keeping: &relaunch, in: folder)
        let next = DownloadManifest.read(in: folder)
        let sweptAfterSave = DownloadManifest.orphanedFolders(in: folder, read: next, records: next.records).map(\.lastPathComponent)
        expect(next.knowsEveryRecord && !sweptAfterSave.contains(broken.uuidString), "its folder is not an orphan at the next launch (\(sweptAfterSave))")
        expect(Set(sweptAfterSave) == [olderBuild.uuidString, newerBuild.uuidString, orphan.uuidString], "the folders nobody owns are (\(sweptAfterSave))")
        // A list written without it (by an earlier build): the kept folders still protect it.
        try Data("[\(recordJSON(known, playlistID))]".utf8).write(to: DownloadManifest.url(in: folder))
        let rewrittenByOlder = DownloadManifest.read(in: folder)
        let sweptByOlder = DownloadManifest.orphanedFolders(in: folder, read: rewrittenByOlder, records: rewrittenByOlder.records).map(\.lastPathComponent)
        expect(!sweptByOlder.contains(broken.uuidString), "nor once a list without it replaced the file (\(sweptByOlder))")

        print("== a file that is not a list, then a save")
        let damaged = Data("{not json".utf8)
        try damaged.write(to: DownloadManifest.url(in: folder))
        var unreadable = DownloadManifest.read(in: folder)
        expect(unreadable.isUnreadableFile && unreadable.records.isEmpty && !unreadable.knowsEveryRecord, "nothing is read, and nothing is swept")
        expect(DownloadManifest.orphanedFolders(in: folder, read: unreadable, records: []).isEmpty, "no folder is taken for an orphan")
        expect(unreadableCopies().count == 1, "a copy of the file is kept before it is written again")
        _ = DownloadManifest.read(in: folder)
        expect(unreadableCopies().count == 1, "the same damaged file is copied once (\(unreadableCopies().count))")
        let everyFolder: Set<UUID> = [known, olderBuild, newerBuild, broken, orphan]
        expect(keptFolders() == everyFolder, "every download folder is kept (\(keptFolders().count))")
        // The viewer adds a download: the next save writes a list without the lost records.
        let added = UUID()
        try fileManager.createDirectory(at: folder.appendingPathComponent(added.uuidString), withIntermediateDirectories: true)
        let addedRecord = DownloadManifest.decode(Data("[\(recordJSON(added, playlistID))]".utf8)).records
        try DownloadManifest.write(addedRecord, keeping: &unreadable, in: folder)
        let afterSave = DownloadManifest.read(in: folder)
        let sweptAfterDamage = DownloadManifest.orphanedFolders(in: folder, read: afterSave, records: afterSave.records)
        expect(afterSave.knowsEveryRecord && sweptAfterDamage.isEmpty, "at the next launch no folder of the lost list is swept (\(sweptAfterDamage.map(\.lastPathComponent)))")
        try fileManager.removeItem(at: folder.appendingPathComponent(orphan.uuidString))
        _ = DownloadManifest.read(in: folder)
        expect(keptFolders() == everyFolder.subtracting([orphan]), "a kept folder that is gone leaves the list")
        let readable = DownloadManifest.decode(Data("[\(recordJSON(broken, playlistID))]".utf8))
        var ownedAgain = readable
        try DownloadManifest.write(readable.records, keeping: &ownedAgain, in: folder)
        _ = DownloadManifest.read(in: folder)
        expect(!keptFolders().contains(broken), "and so does one a readable record owns again")

        print("== a kept list that cannot be read, a list that cannot be opened")
        try Data("garbage".utf8).write(to: DownloadManifest.keptFoldersURL(in: folder))
        let keptDamaged = DownloadManifest.read(in: folder)
        expect(keptDamaged.keptFolderIDs == everyFolder.subtracting([orphan, broken]).union([added]), "every folder no record owns is kept (\(keptDamaged.keptFolderIDs.count))")
        let manifestURL = DownloadManifest.url(in: folder)
        let before = try Data(contentsOf: manifestURL)
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: manifestURL.path)
        var locked = DownloadManifest.read(in: folder)
        expect(locked.couldNotOpenFile && !locked.knowsEveryRecord, "a list that cannot be opened: nothing is swept")
        expect((try? DownloadManifest.write([], keeping: &locked, in: folder)) == nil, "and it is not replaced")
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
        expect(try Data(contentsOf: manifestURL) == before, "it is unchanged")

        print("== a folder that cannot be listed")
        try unlistableFolder(recordJSON: recordJSON)

        print("== failure reasons")
        let unknown = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSLocalizedDescriptionKey: "unknown error"])
        expect(DownloadFailure.Reason(classifying: unknown) == .unexpected, "NSURLErrorUnknown is an unexpected stop, not \"unknown error\"")
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11_800, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)])
        expect(DownloadFailure.Reason(classifying: wrapped) == .network(.timedOut), "a URL error wrapped by AVFoundation keeps its kind")
        expect(DownloadFailure.Reason(classifying: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)) == .badResponse, "a bad server response")
        expect(DownloadFailure.Reason(classifying: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .insufficientSpace, "a full disk")
        expect(DownloadFailure.Reason(classifying: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)) == .storage, "a file that cannot be written")
        let described = NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "The provider closed the account."])
        expect(DownloadFailure.Reason(classifying: described) == .other("The provider closed the account."), "a useful description is kept")
        expect(DownloadFailure.Reason(classifying: NSError(domain: "CoreMediaErrorDomain", code: -12_938)) == .unexpected, "an error without a description is an unexpected stop")
        let withNumber = NSError(domain: "Test", code: 404, userInfo: [NSLocalizedDescriptionKey: "The server example.com answered (error 404)"])
        expect(DownloadFailure.Reason(classifying: withNumber) == .other("The server example.com answered (error 404)"), "a useful description with a host and a number is kept")
        for stored in ["Impossibile completare l’operazione. (Errore NSURLErrorDomain -1.)", "操作を完了できませんでした。（AVFoundationErrorDomainエラー-11800）", "Der Vorgang konnte nicht abgeschlossen werden. (Fluxo.DownloadError Fehler 2.)"] {
            expect(DownloadFailure.Reason.isUninformative(stored), "Foundation's text for an error without a description, in another language: \(stored)")
        }
        expect(!DownloadFailure.Reason.isUninformative("Couldn't reach example.com (code 404)") && !DownloadFailure.Reason.isUninformative("The account expired on 2026-10-01."), "a sentence that only mentions a host or a number is informative")
        for server in ["The stream is offline (host example.COM, status 500)", "The provider refused the link (server Example.com 403)"] {
            expect(!DownloadFailure.Reason.isUninformative(server), "a server's own text ending with a host or a dotted name and a number is informative: \(server)")
        }
        for stored in ["The operation couldn’t be completed. (com.apple.AVKit error 3.)", "Não foi possível concluir a operação. (Erro Fluxo.DownloadError 2.)", "ไม่สามารถดำเนินการให้เสร็จสิ้นได้ (ข้อผิดพลาด NSURLErrorDomain -1)", "A művelet nem hajtható végre. (NSPOSIXErrorDomain hiba: 28.)"] {
            expect(DownloadFailure.Reason.isUninformative(stored), "Foundation's text, with an Apple domain, a Swift type, combining marks or a colon: \(stored)")
        }
    }

    /// The downloads folder cannot be listed for a launch (0o300: its files can still be read and written): a save
    /// then never shrinks or removes the kept list, so no folder of a lost list is swept at the next launch.
    static func unlistableFolder(recordJSON: (UUID, UUID) -> String) throws {
        let fileManager = FileManager.default
        let playlistID = UUID()
        func makeFolder(_ ids: [UUID]) throws -> URL {
            let folder = fileManager.temporaryDirectory.appendingPathComponent("library-check-unlistable-\(UUID().uuidString)", isDirectory: true)
            for id in ids {
                try fileManager.createDirectory(at: folder.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
            }
            return folder
        }
        func keptEntries(_ folder: URL) -> [String]? {
            guard let data = try? Data(contentsOf: DownloadManifest.keptFoldersURL(in: folder)) else {
                return nil
            }
            return try? JSONDecoder().decode([String].self, from: data)
        }
        func setListable(_ folder: URL, _ listable: Bool) throws {
            try fileManager.setAttributes([.posixPermissions: listable ? 0o755 : 0o300], ofItemAtPath: folder.path)
        }
        func record(_ id: UUID) -> [DownloadRecord] {
            DownloadManifest.decode(Data("[\(recordJSON(id, playlistID))]".utf8)).records
        }

        // 1. A damaged list, then a save; a launch that cannot list the folder, then a save; a normal launch.
        let lost = [UUID(), UUID()]
        let folder = try makeFolder(lost)
        defer {
            try? setListable(folder, true)
            try? fileManager.removeItem(at: folder)
        }
        try Data("{not json".utf8).write(to: DownloadManifest.url(in: folder))
        var first = DownloadManifest.read(in: folder)
        expect(first.keptFolderIDs == Set(lost), "launch 1: the folders of the lost list are kept (\(first.keptFolderIDs.count))")
        try DownloadManifest.write([], keeping: &first, in: folder)
        try setListable(folder, false)
        var second = DownloadManifest.read(in: folder)
        expect(second.couldNotListFolders && !second.knowsEveryRecord, "launch 2: the folder cannot be listed, so nothing is swept")
        expect(second.keptFolderIDs == Set(lost), "and the kept folders are the ones on disk (\(second.keptFolderIDs.count))")
        expect(DownloadManifest.orphanedFolders(in: folder, read: second, records: second.records).isEmpty, "no orphan is found")
        let added = UUID()
        try fileManager.createDirectory(at: folder.appendingPathComponent(added.uuidString), withIntermediateDirectories: true)
        try DownloadManifest.write(record(added), keeping: &second, in: folder)
        expect(Set((keptEntries(folder) ?? []).compactMap(UUID.init(uuidString:))) == Set(lost), "the save leaves the kept list as it is (\(keptEntries(folder) ?? ["no file"]))")
        try setListable(folder, true)
        let third = DownloadManifest.read(in: folder)
        let swept = DownloadManifest.orphanedFolders(in: folder, read: third, records: third.records)
        expect(third.knowsEveryRecord && swept.isEmpty, "launch 3: no folder of the lost list is swept (\(swept.map(\.lastPathComponent)))")
        expect(third.records.map(\.id) == [added], "the download added meanwhile is listed")

        // 2. The list is damaged while the folder cannot be listed: the kept list notes that every folder is kept.
        let unseen = [UUID(), UUID()]
        let otherFolder = try makeFolder(unseen)
        defer {
            try? setListable(otherFolder, true)
            try? fileManager.removeItem(at: otherFolder)
        }
        try Data("{not json".utf8).write(to: DownloadManifest.url(in: otherFolder))
        try setListable(otherFolder, false)
        var blind = DownloadManifest.read(in: otherFolder)
        expect(blind.couldNotListFolders && blind.keepsEveryFolder && !blind.knowsEveryRecord, "a lost list in a folder that cannot be listed: every folder is kept")
        expect(keptEntries(otherFolder) == [DownloadManifest.everyFolderMarker], "noted in the kept list (\(keptEntries(otherFolder) ?? ["no file"]))")
        let addedBlind = UUID()
        try fileManager.createDirectory(at: otherFolder.appendingPathComponent(addedBlind.uuidString), withIntermediateDirectories: true)
        try DownloadManifest.write(record(addedBlind), keeping: &blind, in: otherFolder)
        try setListable(otherFolder, true)
        let listed = DownloadManifest.read(in: otherFolder)
        let sweptBlind = DownloadManifest.orphanedFolders(in: otherFolder, read: listed, records: listed.records)
        expect(listed.knowsEveryRecord && sweptBlind.isEmpty, "at the next listing no folder is swept (\(sweptBlind.map(\.lastPathComponent)))")
        expect(listed.keptFolderIDs == Set(unseen) && !listed.keepsEveryFolder, "the folders found are kept by id, the note is resolved (\(listed.keptFolderIDs.count))")
        expect(Set(keptEntries(otherFolder) ?? []) == Set(unseen.map(\.uuidString)), "and saved so")

        // 3. A kept list that cannot be read, in a folder that cannot be listed: replaced by the note, never removed.
        try Data("garbage".utf8).write(to: DownloadManifest.keptFoldersURL(in: otherFolder))
        try setListable(otherFolder, false)
        var unknown = DownloadManifest.read(in: otherFolder)
        try DownloadManifest.write(unknown.records, keeping: &unknown, in: otherFolder)
        expect(keptEntries(otherFolder) == [DownloadManifest.everyFolderMarker], "an unreadable kept list becomes the note (\(keptEntries(otherFolder) ?? ["no file"]))")
        try setListable(otherFolder, true)
        let relisted = DownloadManifest.read(in: otherFolder)
        expect(DownloadManifest.orphanedFolders(in: otherFolder, read: relisted, records: relisted.records).isEmpty && relisted.keptFolderIDs == Set(unseen), "and no folder is swept at the next listing")
    }

    // MARK: - Helpers

    /// The maintenance steps still pending.
    private static func readMaintenanceNotes(_ location: LibraryStoreLocation) -> [String] {
        guard let data = try? Data(contentsOf: location.maintenanceURL), let notes = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
            return []
        }
        return notes.filter(\.value).map(\.key).sorted()
    }

    private static func version(of store: URL) -> String? {
        let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: store)
        return (metadata?[NSStoreModelVersionIdentifiersKey] as? [String])?.first
    }

    private static func rowCount(_ table: String, in store: URL) -> Int {
        var database: OpaquePointer?
        defer {
            sqlite3_close(database)
        }
        guard sqlite3_open_v2(store.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return -1
        }
        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            // No table: no rows of that model in this file.
            return 0
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }

    private static func digest(of url: URL) -> Int {
        (try? Data(contentsOf: url))?.hashValue ?? 0
    }
}

extension Result where Failure == LibraryOpenFailure {
    var failure: LibraryOpenFailure? {
        if case .failure(let failure) = self {
            return failure
        }
        return nil
    }
}
