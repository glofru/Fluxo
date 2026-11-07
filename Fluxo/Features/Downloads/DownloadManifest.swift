//
//  DownloadManifest.swift
//  Fluxo
//
//  Reads and writes `Downloads/downloads.json`, the list of offline downloads (`DownloadCenter`):
//
//  - records are decoded one by one, each field leniently (`DownloadRecord.init(from:)`). A record this build cannot
//    read is left out of the list it shows, but never lost: its JSON, every field of it, is written back by every save
//    (`ReadResult.unreadableEntries`), so a later build still reads it, and its folder keeps an owner;
//  - a file that is not a list at all is kept next to it (`downloads.unreadable-<date>.json`, the newest three) before
//    the next save replaces it;
//  - the folders whose owner this build cannot know are kept (`downloads.kept-folders.json`): every download folder
//    found while the file was not a list, and the folders of unreadable records. Written before the first save can
//    replace the file, read at every launch, so a folder stays protected after the list that named it is gone. An id
//    leaves it once its folder is gone or a readable record owns it again, which only a listing of the folder tells:
//    while the folder cannot be listed, the kept list only grows, and a list lost meanwhile is noted in it as
//    `everyFolderMarker` (every folder found at the next listing is kept);
//  - the folders of downloads that no record owns any more (`Downloads/<id>/`, left by a crash between creating a
//    download and saving the list, or by an earlier build) are found by `orphanedFolders`, never a kept one, and
//    only when every record was read or at least told its id.
//

import Foundation
import os

enum DownloadManifest {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Downloads")

    struct ReadResult: Sendable {
        var records: [DownloadRecord] = []
        /// The JSON of each record this build cannot read, with every field it had: `write` puts it back as it is.
        var unreadableEntries: [Data] = []
        /// The ids of those records, when they had a readable one.
        var unreadableIDs: Set<UUID> = []
        /// Unreadable records without a readable id: their folder cannot be told from an orphan.
        var unreadableWithoutID = 0
        /// The file exists but is not a JSON list (nothing could be read).
        var isUnreadableFile = false
        /// The download folders whose owner is unknown (`downloads.kept-folders.json`): never orphans.
        var keptFolderIDs: Set<UUID> = []
        /// Every folder found at the next listing is kept too: a list was lost while the folder could not be listed.
        var keepsEveryFolder = false
        /// The kept folders are on disk. When they are not, `write` saves them first, or does not replace the file.
        var keptFoldersSaved = true
        /// The download folder could not be listed: the kept folders were not checked against it, so they are never
        /// trimmed or removed from this read, and nothing is swept.
        var couldNotListFolders = false
        /// The file exists but could not be opened (not its content): `write` never replaces it.
        var couldNotOpenFile = false

        /// Records left out because this build cannot read them.
        var unreadableCount: Int {
            unreadableEntries.count
        }

        /// Every folder's owner is known: the orphan sweep may run.
        var knowsEveryRecord: Bool {
            !isUnreadableFile && unreadableWithoutID == 0 && keptFoldersSaved && !couldNotListFolders && !keepsEveryFolder
        }
    }

    static let fileName = "downloads.json"
    static let keptFoldersFileName = "downloads.kept-folders.json"
    /// The entry of the kept list that stands for every folder found at the next listing.
    static let everyFolderMarker = "*"
    static let unreadableCopyPrefix = "downloads.unreadable-"
    /// Copies of unreadable manifests kept.
    static let keptUnreadableCopies = 3

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func keptFoldersURL(in directory: URL) -> URL {
        directory.appendingPathComponent(keptFoldersFileName)
    }

    // MARK: - Reading

    static func read(in directory: URL, now: Date = .now) -> ReadResult {
        var result: ReadResult
        let url = url(in: directory)
        if !FileManager.default.fileExists(atPath: url.path) {
            result = ReadResult()
        } else if let data = try? Data(contentsOf: url) {
            result = decode(data)
            if result.isUnreadableFile {
                logger.error("The downloads list cannot be read: keeping a copy of it, and every download folder")
                keepUnreadableCopy(of: data, in: directory, now: now)
            } else if result.unreadableCount > 0 {
                logger.error("The downloads list has \(result.unreadableCount, privacy: .public) records this version cannot read: they are kept as they are")
            }
        } else {
            // Data protection, a storage error: what it holds is unknown this launch, so it stays as it is.
            logger.error("The downloads list cannot be opened: it is kept as it is")
            result = ReadResult(isUnreadableFile: true, couldNotOpenFile: true)
        }
        updateKeptFolders(&result, in: directory)
        return result
    }

    static func decode(_ data: Data) -> ReadResult {
        // Each element is decoded on its own, from its own JSON, so the one that fails is kept with all its content.
        guard let elements = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any] else {
            return ReadResult(isUnreadableFile: true)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result = ReadResult()
        for element in elements {
            guard let json = try? JSONSerialization.data(withJSONObject: element, options: [.fragmentsAllowed]) else {
                continue
            }
            if let record = try? decoder.decode(DownloadRecord.self, from: json) {
                result.records.append(record)
                continue
            }
            result.unreadableEntries.append(json)
            // At least its id, so its folder is not taken for an orphan.
            if let id = ((element as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)) {
                result.unreadableIDs.insert(id)
            } else {
                result.unreadableWithoutID += 1
            }
        }
        return result
    }

    // MARK: - Writing

    /// Writes the records, then the unreadable entries of the list that was read, unchanged. The kept folders are
    /// saved first if they could not be at launch: until they are, the file the folders were found by stays.
    static func write(_ records: [DownloadRecord], keeping read: inout ReadResult, in directory: URL) throws {
        guard !read.couldNotOpenFile else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url(in: directory).path])
        }
        if !read.keptFoldersSaved {
            try saveKeptFolders(KeptFolders(ids: read.keptFolderIDs, everyFolder: read.keepsEveryFolder), listed: !read.couldNotListFolders, in: directory)
            read.keptFoldersSaved = true
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entries = try records.map { try encoder.encode($0) } + read.unreadableEntries
        var data = Data("[".utf8)
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                data.append(Data(",".utf8))
            }
            data.append(entry)
        }
        data.append(Data("]".utf8))
        try data.write(to: url(in: directory), options: .atomic)
    }

    private static func keepUnreadableCopy(of data: Data, in directory: URL, now: Date) {
        let fileManager = FileManager.default
        let copies = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(unreadableCopyPrefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        // The same damaged file at the next launch (nothing was saved meanwhile): one copy is enough.
        if let newest = copies.first, (try? Data(contentsOf: newest)) == data {
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let copy = directory.appendingPathComponent("\(unreadableCopyPrefix)\(formatter.string(from: now)).json")
        do {
            try data.write(to: copy, options: .atomic)
        } catch {
            logger.error("Could not keep a copy of the downloads list: \(error.localizedDescription, privacy: .public)")
        }
        let all = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(unreadableCopyPrefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(keptUnreadableCopies) {
            try? fileManager.removeItem(at: old)
        }
    }

    // MARK: - Kept folders

    /// The kept list: ids, and whether every folder found at the next listing is kept too.
    private struct KeptFolders: Equatable {
        var ids: Set<UUID> = []
        var everyFolder = false
    }

    /// Adds the folders whose owner this read could not know to the ones kept at earlier launches, drops the ids
    /// whose folder is gone or that a readable record owns again, and saves the list when it changed.
    private static func updateKeptFolders(_ result: inout ReadResult, in directory: URL) {
        let stored = readKeptFolders(in: directory)
        guard let folderList = downloadFolders(in: directory) else {
            // The folder cannot be listed (its own permissions, a storage error): nothing tells which folders exist,
            // so nothing is swept and no id leaves the kept list. It only grows: by the ids of unreadable records,
            // and, when the list was lost (or the kept list cannot be read), by every folder of the next listing.
            logger.error("The downloads folder cannot be listed: every download folder is kept")
            result.couldNotListFolders = true
            var kept = stored ?? KeptFolders(everyFolder: true)
            kept.ids.formUnion(result.unreadableIDs)
            if result.isUnreadableFile {
                kept.everyFolder = true
            }
            store(kept, listed: false, stored: stored, in: &result, directory: directory)
            return
        }
        let folders = Set(folderList.map(\.id))
        var kept = (stored?.ids ?? []).union(result.unreadableIDs)
        if result.isUnreadableFile || stored == nil || stored?.everyFolder == true {
            // Nothing tells which folders the lost list named: all of them are kept.
            kept.formUnion(folders)
        }
        kept.subtract(result.records.map(\.id))
        kept.formIntersection(folders)
        store(KeptFolders(ids: kept), listed: true, stored: stored, in: &result, directory: directory)
    }

    /// Sets the kept folders of `result` and saves them when they changed (not when the list could not be opened:
    /// it is never replaced then, so the kept list stays as it is too).
    private static func store(_ kept: KeptFolders, listed: Bool, stored: KeptFolders?, in result: inout ReadResult, directory: URL) {
        result.keptFolderIDs = kept.ids
        result.keepsEveryFolder = kept.everyFolder
        guard kept != stored, !result.couldNotOpenFile else {
            return
        }
        do {
            try saveKeptFolders(kept, listed: listed, in: directory)
        } catch {
            result.keptFoldersSaved = false
            logger.error("Could not save the download folders to keep: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The kept list; nil when the file exists but cannot be read.
    private static func readKeptFolders(in directory: URL) -> KeptFolders? {
        let url = keptFoldersURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return KeptFolders()
        }
        guard let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return KeptFolders(ids: Set(entries.compactMap(UUID.init(uuidString:))), everyFolder: entries.contains(everyFolderMarker))
    }

    /// Saves the kept list. An empty one removes the file, but only when it was checked against a listing of the
    /// folder (`listed`): one that was not is a list that could not be read, never a list with nothing to keep.
    private static func saveKeptFolders(_ kept: KeptFolders, listed: Bool, in directory: URL) throws {
        let url = keptFoldersURL(in: directory)
        if kept.ids.isEmpty, !kept.everyFolder, listed {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        let entries = kept.ids.map(\.uuidString).sorted() + (kept.everyFolder ? [everyFolderMarker] : [])
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    // MARK: - Orphans

    /// The download folders (named by a download id) that no record owns. Empty when an owner may be unknown.
    static func orphanedFolders(in directory: URL, read: ReadResult, records: [DownloadRecord]) -> [URL] {
        guard read.knowsEveryRecord else {
            return []
        }
        let owned = Set(records.map(\.id)).union(read.unreadableIDs).union(read.keptFolderIDs)
        return (downloadFolders(in: directory) ?? []).filter { !owned.contains($0.id) }.map(\.url)
    }

    /// The folders named by a download id; nil when the folder exists but cannot be listed.
    private static func downloadFolders(in directory: URL) -> [(id: UUID, url: URL)]? {
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            return []
        }
        guard isDirectory.boolValue, let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            return nil
        }
        return folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, let id = UUID(uuidString: folder.lastPathComponent) else {
                return nil
            }
            return (id, folder)
        }
    }
}
