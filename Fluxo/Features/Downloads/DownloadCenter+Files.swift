//
//  DownloadCenter+Files.swift
//  Fluxo
//
//  The offline downloads (DownloadCenter) at launch and on disk: reconciliation with the surviving transfers,
//  the files and artwork of each download, paths and sizes.
//

import AVFoundation
import Foundation
import Observation
import os
import SwiftData

extension DownloadCenter {
    // MARK: - Launch

    /// Matches the records with the transfers that survived the relaunch.
    func reconcile(restored: [UUID: DownloadTransport.SessionKind]) {
        var received: [UUID] = []
        for record in records where !starting.contains(record.id) {
            let id = record.id
            switch record.status {
            case .preparing:
                update(id) { $0.status = .queued }
            case .downloading:
                if restored[id] == nil, hasReceivedFile(record) {
                    // The transfer ended while no one listened (the app was not running, or the library was not
                    // open yet): its file is already in the download's folder, so it is kept, not downloaded again.
                    received.append(id)
                } else if restored[id] == nil {
                    // The transfer was lost (the app was force-quit): it starts again, from its resume data or
                    // its partial HLS package.
                    update(id) { $0.status = .queued }
                }
            case .paused:
                if restored[id] != nil, record.method != .hls {
                    transport.cancel(id: id)
                }
            case .queued:
                if restored[id] != nil {
                    // Its transfer survived (the app quit before the record said so): adopted as it is.
                    update(id) { $0.status = .downloading }
                }
            case .converting, .completed, .failed:
                if restored[id] != nil {
                    transport.cancel(id: id)
                }
            }
        }
        // Transfers of downloads that no longer exist. Not those of records this build cannot read (a newer build's,
        // written back by every save): that build still owns them.
        for id in restored.keys where record(id: id) == nil && !manifestRead.unreadableIDs.contains(id) {
            transport.cancel(id: id)
        }
        for id in received {
            Self.logger.info("Keeping a download whose transfer finished while the app was not listening")
            transferDidFinish(id, failure: nil)
        }
    }

    /// The file of a file transfer is in the download's folder. The transport moves it there only once the whole
    /// response arrived with a success status (a partial transfer leaves resume data, never the file).
    private func hasReceivedFile(_ record: DownloadRecord) -> Bool {
        guard record.method == .file || record.method == .remux, let name = record.transferFileName else {
            return false
        }
        return FileManager.default.fileExists(atPath: folder(of: record.id).appendingPathComponent(name).path)
    }

    /// Completed downloads whose media is gone (the system purged an HLS package, a file was removed) are marked
    /// missing; their sizes are refreshed.
    func verifyCompletedFiles() {
        for record in records where record.status == .completed {
            guard let url = mediaURL(of: record), FileManager.default.fileExists(atPath: url.path) else {
                if !record.isMissing {
                    markMissing(record.id)
                }
                continue
            }
            if record.isMissing {
                update(record.id) { $0.isMissing = false }
            }
        }
    }

    func markMissing(_ id: UUID) {
        update(id) { $0.isMissing = true }
    }

    /// Downloads a missing download again.
    func redownload(_ id: UUID) {
        guard let record = record(id: id) else {
            return
        }
        removeMedia(of: record, keepingArtwork: true)
        update(id) {
            $0.status = .queued
            $0.isMissing = false
            $0.location = nil
            $0.method = nil
            $0.transferFileName = nil
            $0.fraction = 0
            $0.bytesWritten = 0
            $0.bytesOnDisk = 0
            $0.completedOn = nil
            $0.watchedOn = nil
            $0.failureReason = nil
            $0.automaticRetries = 0
        }
        pump()
    }

    // MARK: - Files

    func folder(of id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func mediaURL(of record: DownloadRecord) -> URL? {
        guard let location = record.location else {
            return nil
        }
        switch record.method {
        case .hls:
            return Self.homeURL(forRelativePath: location)
        case .file, .remux:
            return folder(of: record.id).appendingPathComponent(location)
        case nil:
            return nil
        }
    }

    func removeMedia(of record: DownloadRecord, keepingArtwork: Bool = false) {
        if record.method == .hls, let location = record.location {
            try? FileManager.default.removeItem(at: Self.homeURL(forRelativePath: location))
        }
        if keepingArtwork {
            removeFolderContents(of: record.id, keepingArtwork: true)
        } else {
            try? FileManager.default.removeItem(at: folder(of: record.id))
        }
    }

    func removeFolderContents(of id: UUID, keepingArtwork: Bool) {
        let artwork = record(id: id)?.artworkFileName
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder(of: id), includingPropertiesForKeys: nil)) ?? []
        for url in contents where !(keepingArtwork && url.lastPathComponent == artwork) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Keeps a copy of the entry's artwork with the download, so it shows offline.
    func saveArtwork(for record: DownloadRecord) async -> String? {
        guard let data = await artworkData(for: record) else {
            return nil
        }
        let folder = folder(of: record.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("artwork"), options: .atomic)
            return "artwork"
        } catch {
            return nil
        }
    }

    func artworkData(for record: DownloadRecord) async -> Data? {
        if let name = record.artworkFileName, let data = try? Data(contentsOf: folder(of: record.id).appendingPathComponent(name)) {
            return data
        }
        guard let logo = record.item.logo ?? originalLogo(of: record) else {
            return nil
        }
        if logo.hasPrefix("data:") {
            return LogoImageLoader.decodeDataURI(logo)
        }
        guard let url = URL(string: logo), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        // The logo cache usually has it already.
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if let cached = LogoImageLoader.shared.urlCache.cachedResponse(for: request)?.data {
            return cached
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count < 8 << 20 else {
            return nil
        }
        return data
    }

    /// The artwork of a playlist entry stored as a `data:` URI (not kept in the manifest): looked up in the store.
    private func originalLogo(of record: DownloadRecord) -> String? {
        guard let container else {
            return nil
        }
        let context = ModelContext(container)
        let playlistID = record.item.playlistID
        let url: URL? = record.item.url
        var descriptor = FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.playlistID == playlistID && $0.url == url })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.logo
    }

    /// The same entry in the current copy of its playlist, when its link changed (providers renew links that
    /// carry a token or credentials).
    func renewedItem(for record: DownloadRecord) async -> DownloadedItem? {
        guard let container else {
            return nil
        }
        let item = record.item
        return await Task.detached(priority: .utility) { () -> DownloadedItem? in
            let context = ModelContext(container)
            guard let importID = SeriesLookup.currentImportID(playlistID: item.playlistID, in: context) else {
                return nil
            }
            let name = item.name
            let kind = item.kindRawValue
            var descriptor = FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.importID == importID && $0.name == name && $0.kindRawValue == kind })
            descriptor.fetchLimit = 8
            let candidates = (try? context.fetch(descriptor)) ?? []
            let match = candidates.first { channel in
                ChannelItem(channel).series?.code == item.series?.code
            }
            return match.flatMap { DownloadedItem(ChannelItem($0)) }
        }.value
    }

    func loadDuration(of id: UUID, url: URL) {
        Task {
            guard let duration = try? await AVURLAsset(url: url).load(.duration).seconds, duration.isFinite, duration > 0 else {
                return
            }
            update(id) { $0.duration = duration }
        }
    }

    // MARK: - Paths and sizes

    /// HLS packages are stored relative to the home directory, whose path changes with app updates.
    nonisolated static func relativePathFromHome(_ url: URL) -> String {
        func normalized(_ path: String) -> String {
            // AVFoundation reports "/.nofollow/…" paths, and "/private/var" and "/var" are the same folder.
            var path = path
            if path.hasPrefix("/.nofollow/") {
                path = String(path.dropFirst("/.nofollow".count))
            }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let home = normalized(NSHomeDirectory())
        let path = normalized(url.path)
        if path.hasPrefix(home + "/") {
            return String(path.dropFirst(home.count + 1))
        }
        // Another spelling of the container: keep what follows its Library folder (AVFoundation's packages are
        // in Library/com.apple.UserManagedAssets.*).
        if let range = path.range(of: "/Library/", options: .backwards) {
            return "Library/" + path[range.upperBound...]
        }
        return path
    }

    nonisolated static func homeURL(forRelativePath path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
    }

    nonisolated static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return 0
        }
        guard values.isDirectory == true else {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let file as URL in enumerator {
                let fileValues = try? file.resourceValues(forKeys: keys)
                total += Int64(fileValues?.totalFileAllocatedSize ?? fileValues?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
