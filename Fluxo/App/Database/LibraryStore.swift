//
//  LibraryStore.swift
//  Fluxo
//
//  Opens the app's SwiftData stores (see docs/library-store.md):
//
//  - the library store (`default.store`, Application Support, backed up): what the user made (`ModelRegistry.user`).
//    It is never moved, emptied or recreated without the user's say: when it cannot be opened the app shows
//    `LibraryRecoveryView` (Try Again, Export a Copy, Start with an Empty Library, which keeps a backup);
//  - the cache store (`Cache.store`, Caches, never backed up and purgeable by the system): what imports write again
//    (`ModelRegistry.cache`). Recreated empty whenever it cannot be opened; the next refresh fills it
//    (`PlaylistImporter.playlistsMissingContent`, `EPGImporter.resetSourcesMissingContent`).
//
//  Both are configurations of one `ModelContainer`, so a `ModelContext` reads and writes either transparently.
//  Stores written before the split (schema 1.0.0, everything in `default.store`) are split once, without copying a
//  row: the file is cloned (APFS: instant, no extra space) to become the cache store, then each file drops the other
//  side's rows (`Maintenance`), and the library file is compacted.
//

import CoreData
import Foundation
import os
import SQLite3
import SwiftData

/// Why the library store could not be opened (`LibraryRecoveryView` explains each).
enum LibraryOpenFailure: String, Error, Equatable, Sendable, CaseIterable {
    /// Written by a newer version of Fluxo (its schema is newer than this build's): opening it here could lose what
    /// that version added.
    case newerVersion
    /// The file cannot be read right now: the device is locked (data protection), or an I/O or permission error.
    case temporarilyUnavailable
    /// Opening it needs a migration and the device is nearly full.
    case notEnoughSpace
    /// Not a readable SQLite database any more.
    case damaged
    /// Anything else (a migration this build cannot make, an error SwiftData does not explain).
    case cannotOpen
}

/// Where the two stores, the maintenance notes and the backups of a library live.
struct LibraryStoreLocation: Sendable, Equatable {
    let userStoreURL: URL
    let cacheStoreURL: URL
    /// Kept copies of a library the user chose to start over from (`LibraryStore.startOver`).
    let backupsDirectory: URL

    /// The app's library: the store SwiftData has always used (Application Support/default.store), the cache in
    /// Caches/Fluxo (outside the backups, and the place tvOS and iOS expect data they may purge).
    static var standard: LibraryStoreLocation {
        let support = URL.applicationSupportDirectory
        return LibraryStoreLocation(
            userStoreURL: support.appendingPathComponent("default.store"),
            cacheStoreURL: URL.cachesDirectory.appendingPathComponent("Fluxo", isDirectory: true).appendingPathComponent("Cache.store"),
            backupsDirectory: support.appendingPathComponent("Library Backups", isDirectory: true)
        )
    }

    /// An isolated library in `directory` (the debug harness, the checks in Tools).
    static func isolated(in directory: URL, userStoreName: String = "Fluxo.store") -> LibraryStoreLocation {
        LibraryStoreLocation(
            userStoreURL: directory.appendingPathComponent(userStoreName),
            cacheStoreURL: directory.appendingPathComponent("Cache", isDirectory: true).appendingPathComponent("Cache.store"),
            backupsDirectory: directory.appendingPathComponent("Library Backups", isDirectory: true)
        )
    }

    /// The notes of a split that has not finished, next to the library store.
    var maintenanceURL: URL {
        userStoreURL.deletingLastPathComponent().appendingPathComponent(".\(userStoreURL.lastPathComponent).maintenance.json")
    }
}

/// A copy of a library kept by Start with an Empty Library.
struct LibraryBackup: Identifiable, Hashable, Sendable {
    let directory: URL
    let createdOn: Date
    let bytes: Int64

    var id: URL {
        directory
    }
}

enum LibraryStore {

    nonisolated static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "LibraryStore")

    /// SQLite's files of a store.
    private static let fileSuffixes = ["", "-wal", "-shm"]
    /// Below this much free space, a store that fails to open is reported as `.notEnoughSpace`.
    static let minimumFreeSpace: Int64 = 200 * 1024 * 1024
    /// Backups kept (the newest).
    static let keptBackups = 2

    // MARK: - Opening

    /// Opens the library and its cache. The library store is never changed when it fails: the failure says why.
    /// The history of earlier launches is left to `StoreHistory.pruneEarlierLaunches` (off the main thread, once the
    /// app runs).
    static func open(_ location: LibraryStoreLocation) -> Result<ModelContainer, LibraryOpenFailure> {
        let fileManager = FileManager.default
        prepareDirectories(location)
        // First, while nothing of this process has the file open: a split's compaction (see `runPendingMaintenance`).
        compactIfPending(location)

        let userExists = fileManager.fileExists(atPath: location.userStoreURL.path)
        if userExists {
            // Never touch a store this build cannot read, or one a newer build wrote.
            switch inspect(location.userStoreURL) {
            case .failure(let failure):
                logger.error("The library store cannot be read: \(failure.rawValue, privacy: .public)")
                return .failure(failure)
            case .success(let version):
                if let version, version > FluxoMigrationPlan.currentVersion {
                    logger.error("The library store was written by a newer version (\(version.description, privacy: .public))")
                    return .failure(.newerVersion)
                }
                if let version, version < FluxoSchemaV2.versionIdentifier {
                    splitLegacyStoreIfNeeded(location)
                }
            }
        }
        runPendingMaintenance(location)

        if let container = try? openBoth(location) {
            return .success(container)
        }
        // The cache is the first suspect, and it is free to recreate.
        if fileManager.fileExists(atPath: location.cacheStoreURL.path), (try? openSingle(location.cacheStoreURL)) == nil {
            logger.error("The cache store cannot be opened: recreating it")
            removeStoreFiles(at: location.cacheStoreURL)
            if let container = try? openBoth(location) {
                return .success(container)
            }
        }
        let failure = classifyFailure(of: location.userStoreURL)
        logger.error("The library store cannot be opened: \(failure.rawValue, privacy: .public)")
        return .failure(failure)
    }

    /// Whether opening the library will first split a store of the first builds, or finish a split (seconds for a
    /// large library, once): the app then opens it off the main thread, behind "Updating Your Library…"
    /// (`LibrarySession`). The compaction at the launch after the split too: it rewrites the library file.
    static func needsUpgrade(_ location: LibraryStoreLocation) -> Bool {
        guard FileManager.default.fileExists(atPath: location.userStoreURL.path) else {
            return false
        }
        if !readMaintenance(location).isEmpty {
            return true
        }
        if case .success(let version?) = inspect(location.userStoreURL) {
            return version < FluxoSchemaV2.versionIdentifier
        }
        return false
    }

    /// In memory (the previews, the in-memory debug library): one store with every model.
    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: FluxoSchemaV2.self)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// The configurations of the two stores. iCloud sync is Fluxo's own (`CloudSync`, `CKSyncEngine`), so they opt out
    /// of SwiftData's CloudKit mirroring (`cloudKitDatabase: .none`): with the iCloud entitlement the default mirrors to
    /// the entitlement's container, which needs a schema without unique constraints and non-optional attributes, and
    /// the store would fail to open. They stay in the app's own container (`groupContainer: .none`) when the build has
    /// an App Group (the Apple TV app shares one with its Top Shelf extension, which never reads them).
    private static func configurations(_ location: LibraryStoreLocation) -> [ModelConfiguration] {
        [
            ModelConfiguration("Library", schema: Schema(ModelRegistry.user), url: location.userStoreURL, cloudKitDatabase: .none),
            ModelConfiguration("Cache", schema: Schema(ModelRegistry.cache), url: location.cacheStoreURL, cloudKitDatabase: .none),
        ]
    }

    private static func openBoth(_ location: LibraryStoreLocation) throws -> ModelContainer {
        let schema = Schema(versionedSchema: FluxoSchemaV2.self)
        do {
            return try ModelContainer(for: schema, migrationPlan: FluxoMigrationPlan.self, configurations: configurations(location))
        } catch {
            // A store SwiftData cannot place in the plan: one written by a development build before the schema was
            // versioned (1.0.0, other hashes). Earlier builds opened such stores with an inferred migration; so does
            // this one, once (afterwards the store is at 2.0.0). Never for a store of a newer version (checked by
            // `open`, before: such a migration would drop what that version added).
            logger.error("Could not open the stores with the migration plan, trying an inferred migration: \(String(describing: error), privacy: .public)")
            return try ModelContainer(for: schema, configurations: configurations(location))
        }
    }

    /// One store file alone, with every model of the current schema (a plan only accepts a whole versioned schema).
    private static func openSingle(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: FluxoSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, migrationPlan: FluxoMigrationPlan.self, configurations: configuration)
        } catch {
            return try ModelContainer(for: schema, configurations: configuration)
        }
    }

    private static func prepareDirectories(_ location: LibraryStoreLocation) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: location.userStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cacheDirectory = location.cacheStoreURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Caches is never backed up; an isolated library may keep its cache elsewhere.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cacheDirectory.setResourceValues(values)
    }

    // MARK: - Inspecting a store without opening it

    /// The schema version of the store at `url` (nil when it records none), or why it cannot be read.
    static func inspect(_ url: URL) -> Result<Schema.Version?, LibraryOpenFailure> {
        // First the file itself: a read that fails is the device (locked, I/O), a wrong header is a damaged file.
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer {
                try? handle.close()
            }
            let header = try handle.read(upToCount: 16) ?? Data()
            if header.isEmpty {
                // An empty file is a new database to SQLite.
                return .success(nil)
            }
            guard header == Data("SQLite format 3\0".utf8) else {
                return .failure(.damaged)
            }
        } catch {
            return .failure(.temporarilyUnavailable)
        }
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
            let identifiers = metadata[NSStoreModelVersionIdentifiersKey] as? [String] ?? []
            return .success(identifiers.compactMap(Schema.Version.init(text:)).max())
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadCorruptFileError {
                return .failure(.damaged)
            }
            return .failure(.temporarilyUnavailable)
        }
    }

    private static func classifyFailure(of url: URL) -> LibraryOpenFailure {
        switch inspect(url) {
        case .failure(let failure):
            return failure
        case .success(let version):
            if let version, version > FluxoMigrationPlan.currentVersion {
                return .newerVersion
            }
            if let available = PlatformStorage.availableCapacity(at: url.deletingLastPathComponent()), available < minimumFreeSpace {
                return .notEnoughSpace
            }
            return .cannotOpen
        }
    }

    // MARK: - Splitting a store of the first builds

    /// What is left to do of a split (it survives a crash or a kill in the middle).
    private struct Maintenance: Codable {
        /// The library store still holds the rows of the cache models.
        var purgeUserStore = false
        /// The cache store still holds the rows of the user models.
        var purgeCacheStore = false
        /// The library store's file still has the pages of the purged rows: compacted at the next launch, before the
        /// store is opened (SwiftData gives no way to close a store, and SQLite cannot shrink a file another
        /// connection of the process still has open).
        var compactUserStore = false

        init(purgeUserStore: Bool = false, purgeCacheStore: Bool = false, compactUserStore: Bool = false) {
            self.purgeUserStore = purgeUserStore
            self.purgeCacheStore = purgeCacheStore
            self.compactUserStore = compactUserStore
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            purgeUserStore = container.lenient(Bool.self, .purgeUserStore) ?? false
            purgeCacheStore = container.lenient(Bool.self, .purgeCacheStore) ?? false
            compactUserStore = container.lenient(Bool.self, .compactUserStore) ?? false
        }

        var isEmpty: Bool {
            !purgeUserStore && !purgeCacheStore && !compactUserStore
        }
    }

    private static func readMaintenance(_ location: LibraryStoreLocation) -> Maintenance {
        guard let data = try? Data(contentsOf: location.maintenanceURL), let maintenance = try? JSONDecoder().decode(Maintenance.self, from: data) else {
            return Maintenance()
        }
        return maintenance
    }

    private static func writeMaintenance(_ maintenance: Maintenance, _ location: LibraryStoreLocation) {
        if maintenance.isEmpty {
            try? FileManager.default.removeItem(at: location.maintenanceURL)
            return
        }
        do {
            try JSONEncoder().encode(maintenance).write(to: location.maintenanceURL, options: .atomic)
        } catch {
            logger.error("Could not write the library maintenance notes: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A 1.0.0 store holds everything. Its clone becomes the cache store (the guides and channels stay, nothing is
    /// downloaded again); each file then drops the other side's rows (`runPendingMaintenance`).
    private static func splitLegacyStoreIfNeeded(_ location: LibraryStoreLocation) {
        let fileManager = FileManager.default
        var maintenance = readMaintenance(location)
        guard !fileManager.fileExists(atPath: location.cacheStoreURL.path) || maintenance.purgeCacheStore else {
            // A cache from a split that finished, or created meanwhile: the library rows are purged below if needed.
            if !maintenance.purgeUserStore {
                maintenance.purgeUserStore = true
                writeMaintenance(maintenance, location)
            }
            return
        }
        if fileManager.fileExists(atPath: location.cacheStoreURL.path) {
            // The split already cloned it.
            return
        }
        logger.notice("Splitting the library store into the library and the cache")
        // Noted first: a kill after the clone still purges both files at the next launch.
        maintenance.purgeUserStore = true
        maintenance.purgeCacheStore = true
        writeMaintenance(maintenance, location)

        let cacheDirectory = location.cacheStoreURL.deletingLastPathComponent()
        // What an interrupted split left.
        for leftover in (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? [] where leftover.lastPathComponent.hasPrefix(".split-") {
            try? fileManager.removeItem(at: leftover)
        }
        let staging = cacheDirectory.appendingPathComponent(".split-\(UUID().uuidString).store")
        do {
            // The shared-memory file is rebuilt by SQLite; the database and its write-ahead log make the store.
            for suffix in ["", "-wal"] {
                let source = URL(fileURLWithPath: location.userStoreURL.path + suffix)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.copyItem(at: source, to: URL(fileURLWithPath: staging.path + suffix))
                }
            }
            // Core Data identifies stores by the UUID in their metadata, and a copy keeps it: a coordinator given two
            // stores with one UUID loads only one of them.
            var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: staging)
            metadata[NSStoreUUIDKey] = UUID().uuidString
            try NSPersistentStoreCoordinator.setMetadata(metadata, forPersistentStoreOfType: NSSQLiteStoreType, at: staging, options: nil)
            for suffix in ["", "-wal"] {
                let source = URL(fileURLWithPath: staging.path + suffix)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.moveItem(at: source, to: URL(fileURLWithPath: location.cacheStoreURL.path + suffix))
                }
            }
            // The shared-memory file reading the metadata left.
            removeStoreFiles(at: staging)
        } catch {
            // No cache then: the playlists and guides are downloaded again; the library is untouched.
            logger.error("Could not clone the library store for the cache: \(error.localizedDescription, privacy: .public)")
            removeStoreFiles(at: staging)
            removeStoreFiles(at: location.cacheStoreURL)
            maintenance.purgeCacheStore = false
            writeMaintenance(maintenance, location)
        }
    }

    /// Drops the rows each file keeps for the other store. Idempotent; what fails is tried again at the next launch
    /// (rows of the other store are never read, so they only take space meanwhile).
    private static func runPendingMaintenance(_ location: LibraryStoreLocation) {
        var maintenance = readMaintenance(location)
        guard !maintenance.isEmpty else {
            return
        }
        if maintenance.purgeCacheStore {
            if FileManager.default.fileExists(atPath: location.cacheStoreURL.path) {
                do {
                    try purge(ModelRegistry.user, from: location.cacheStoreURL)
                } catch {
                    logger.error("Could not prepare the cache store, recreating it: \(error.localizedDescription, privacy: .public)")
                    removeStoreFiles(at: location.cacheStoreURL)
                }
            }
            maintenance.purgeCacheStore = false
            writeMaintenance(maintenance, location)
        }
        if maintenance.purgeUserStore {
            do {
                try purge(ModelRegistry.cache, from: location.userStoreURL)
                maintenance.purgeUserStore = false
                maintenance.compactUserStore = true
                writeMaintenance(maintenance, location)
            } catch {
                logger.error("Could not remove the cache rows from the library store: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func purge(_ models: [any PersistentModel.Type], from url: URL) throws {
        let started = Date()
        defer {
            logger.notice("Purged \(url.lastPathComponent, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1_000)) ms")
        }
        try autoreleasepool {
            let container = try openSingle(url)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            for model in models {
                try context.delete(model: model)
            }
            try context.save()
            // The deletions' history would take as much room as the rows.
            try StoreHistory.delete(before: .now, in: context)
        }
    }

    private static func compactIfPending(_ location: LibraryStoreLocation) {
        var maintenance = readMaintenance(location)
        guard maintenance.compactUserStore else {
            return
        }
        if FileManager.default.fileExists(atPath: location.userStoreURL.path) {
            compact(location.userStoreURL)
        }
        maintenance.compactUserStore = false
        writeMaintenance(maintenance, location)
    }

    /// Gives the pages of the deleted rows back to the file system (they would be backed up otherwise). Only before
    /// anything of the process opened the store (`compactIfPending`): no connection but this one.
    private static func compact(_ url: URL) {
        let started = Date()
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return
        }
        defer {
            sqlite3_close(database)
        }
        if sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE); VACUUM; PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) != SQLITE_OK {
            logger.error("Could not compact the library store: \(String(cString: sqlite3_errmsg(database)), privacy: .public)")
        } else {
            logger.notice("Compacted the library store in \(Int(Date().timeIntervalSince(started) * 1_000)) ms")
        }
    }

    // MARK: - Files

    static func removeStoreFiles(at url: URL) {
        for suffix in fileSuffixes {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    private static func existingStoreFiles(at url: URL) -> [URL] {
        fileSuffixes.map { URL(fileURLWithPath: url.path + $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Start over, backups and export

    /// Start with an Empty Library: moves the library store into a backup folder (never deletes it), and the cache
    /// out of the way. The next `open` creates empty stores; iCloud sync then offers to restore what it has
    /// (`CloudSyncReconciler`: an empty library is lost, not deleted).
    static func startOver(_ location: LibraryStoreLocation, now: Date = .now) throws {
        let fileManager = FileManager.default
        let files = existingStoreFiles(at: location.userStoreURL)
        if !files.isEmpty {
            let backup = location.backupsDirectory.appendingPathComponent(backupName(for: now), isDirectory: true)
            try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
            for file in files {
                try fileManager.moveItem(at: file, to: backup.appendingPathComponent(file.lastPathComponent))
            }
            logger.notice("Library moved to the backup \(backup.lastPathComponent, privacy: .public)")
        }
        try? fileManager.removeItem(at: location.maintenanceURL)
        removeStoreFiles(at: location.cacheStoreURL)
        pruneBackups(location)
    }

    /// The kept backups, newest first.
    static func backups(_ location: LibraryStoreLocation) -> [LibraryBackup] {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(at: location.backupsDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { folder -> LibraryBackup? in
            let store = folder.appendingPathComponent(location.userStoreURL.lastPathComponent)
            guard fileManager.fileExists(atPath: store.path) else {
                return nil
            }
            let bytes = existingStoreFiles(at: store).reduce(Int64(0)) { total, file in
                total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return LibraryBackup(directory: folder, createdOn: created, bytes: bytes)
        }
        .sorted { $0.createdOn > $1.createdOn }
    }

    static func deleteBackup(_ backup: LibraryBackup) throws {
        try FileManager.default.removeItem(at: backup.directory)
    }

    private static func pruneBackups(_ location: LibraryStoreLocation) {
        for backup in backups(location).dropFirst(keptBackups) {
            try? deleteBackup(backup)
        }
    }

    private static func backupName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return "Library-\(formatter.string(from: date))"
    }

    /// A ZIP archive of the library store files (the store as it is on disk, closed), in the temporary folder, for
    /// the user to keep or send. `store` is the library store or the store of a backup.
    static func makeArchive(of store: URL, now: Date = .now) throws -> URL {
        let fileManager = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let name = "Fluxo Library \(formatter.string(from: now))"
        let staging = fileManager.temporaryDirectory.appendingPathComponent("LibraryExport-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: folder)
        }
        for file in existingStoreFiles(at: store) {
            try fileManager.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        }
        let archive = staging.appendingPathComponent("\(name).zip")
        var coordinationError: NSError?
        var copyError: (any Error)?
        // Reading a folder "for uploading" gives a ZIP of it.
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipped in
            do {
                try fileManager.copyItem(at: zipped, to: archive)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            throw error
        }
        return archive
    }
}

extension Schema.Version {
    /// "2.0.0".
    init?(text: String) {
        let parts = text.split(separator: ".").map { Int($0) }
        guard parts.count == 3, let major = parts[0], let minor = parts[1], let patch = parts[2] else {
            return nil
        }
        self.init(major, minor, patch)
    }
}
