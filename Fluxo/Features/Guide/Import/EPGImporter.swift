//
//  EPGImporter.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import CryptoKit
import Foundation
import os
import SwiftData

/// Progress of a guide refresh, delivered a few times per second.
struct EPGRefreshProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case connecting
        case downloading
        case reading
        case finishing
    }

    var phase: Phase
    var fractionCompleted: Double?
    var bytes: Int64 = 0
    var programmeCount = 0

    static let connecting = EPGRefreshProgress(phase: .connecting)

    var message: String {
        switch phase {
        case .connecting:
            return String(localized: "Contacting the server…", comment: "TV guide download progress.")
        case .downloading:
            return String(localized: "Downloading \(bytes.formatted(.byteCount(style: .file)))…", comment: "TV guide download progress; the placeholder is the size downloaded so far, such as 12 MB.")
        case .reading:
            return String(localized: "Reading \(programmeCount) programmes…", comment: "TV guide import progress; the number grows as programmes are read.")
        case .finishing:
            return String(localized: "Saving \(programmeCount) programmes…", comment: "TV guide import progress while the programmes are saved.")
        }
    }
}

struct EPGRefreshSummary: Sendable {
    let channelCount: Int
    let storedChannelCount: Int
    let programmeCount: Int
    let downloadedBytes: Int64
    let duration: Duration
    /// False when the file ended early (it was still stored, having more programmes than the previous guide).
    var isComplete = true
}

enum EPGImportError: LocalizedError {
    case sourceNotFound
    case tooLarge(Int64)
    case notXMLTV
    case incomplete

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return String(localized: "The guide source no longer exists.", comment: "TV guide import error: the source was deleted during the download.")
        case .tooLarge(let bytes):
            return String(localized: "The guide is larger than \(bytes.formatted(.byteCount(style: .file))). Use a smaller guide, for example one for your country only.", comment: "TV guide import error; the placeholder is the size limit, such as 2 GB.")
        case .notXMLTV:
            return String(localized: "No TV guide found. Is this an XMLTV file?", comment: "TV guide import error: the file has no programmes. XMLTV is a file format name.")
        case .incomplete:
            return String(localized: "The guide file was incomplete, so the previous guide was kept. It is downloaded again later.", comment: "TV guide import error.")
        }
    }
}

/// Downloads XMLTV guides and stores them, entirely off the main actor.
///
/// The file is streamed to disk, then read by `XMLTVParser` through `InflatingInputStream` on a utility queue,
/// so neither the download nor the (often gzip-compressed) XML is ever held in memory. Only programmes inside the
/// guide window (`windowBefore` … `windowAfter` around now) of channels that can match a playlist channel are
/// kept, and they are inserted in batches into short-lived background `ModelContext`s.
actor EPGImporter {

    /// How far back and ahead the guide keeps programmes.
    static let windowBefore: TimeInterval = 6 * 3_600
    static let windowAfter: TimeInterval = 7 * 86_400
    /// Downloads above this size are refused (whole-world guides are hundreds of MB compressed).
    static let maximumDownloadBytes: Int64 = 400 << 20
    /// Channel rows stored per guide (used by the manual matching picker); further channels are only counted.
    static let maximumStoredChannels = 60_000

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "EPGImporter")

    private let container: ModelContainer
    private let batchSize: Int
    private let downloadsDirectory: URL

    /// Imports writing rows right now; `purgeOrphanedContent()` must keep them.
    private var runningImports: Set<UUID> = []

    init(container: ModelContainer, batchSize: Int = 2_000, downloadsDirectory: URL? = nil) {
        self.container = container
        self.batchSize = batchSize
        self.downloadsDirectory = downloadsDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GuideDownloads", isDirectory: true)
    }

    // MARK: - Refresh

    /// Downloads the guide of a source and replaces its programmes. On failure (or cancellation) the previous
    /// guide stays, and `lastError` is set (not for cancellation).
    ///
    /// When the stored guide was read for the same wanted channels, the request is conditional (ETag /
    /// Last-Modified) and an unchanged file (304, or the same SHA-256) is neither downloaded nor read again.
    func refresh(sourceID: UUID, now: Date = .now, progress: @escaping @Sendable (EPGRefreshProgress) -> Void) async throws -> EPGRefreshSummary {
        let clock = ContinuousClock()
        let startedAt = clock.now
        progress(.connecting)

        let context = makeContext()
        guard let source = try context.fetch(EPGQueries.source(uuid: sourceID)).first else {
            throw EPGImportError.sourceNotFound
        }
        let url = source.url
        let playlistID = source.playlistID
        let previousHash = source.contentHash
        let hasCurrentImport = source.currentImportID != nil
        let previousValidators = HTTPValidators(entityTag: source.entityTag, lastModified: source.lastModifiedHeader)
        let previousCounts = (channels: source.channelCount, stored: source.storedChannelCount, programmes: source.programmeCount)
        source.lastAttemptOn = now
        try context.save()

        func unchangedSummary(downloadedBytes: Int64) -> EPGRefreshSummary {
            EPGRefreshSummary(
                channelCount: previousCounts.channels,
                storedChannelCount: previousCounts.stored,
                programmeCount: previousCounts.programmes,
                downloadedBytes: downloadedBytes,
                duration: clock.now - startedAt
            )
        }

        do {
            let wanted = try wantedChannels(playlistID: playlistID, sourceID: sourceID)
            // The stored programmes are only those of the channels wanted at the last import: if the playlist
            // channels changed meanwhile, the file must be read again even when it did not change.
            let isSameChannels = hasCurrentImport && Self.wantedFingerprint(inContentHash: previousHash) == wanted.fingerprint
            guard let file = try await download(url, validators: isSameChannels ? previousValidators : nil, progress: progress) else {
                try markUnchanged(sourceID: sourceID, now: now)
                Self.logger.info("Guide \(url.host() ?? "", privacy: .public): not modified")
                return unchangedSummary(downloadedBytes: 0)
            }
            defer {
                try? FileManager.default.removeItem(at: file.url)
            }
            try Task.checkCancellation()
            // Most guides are regenerated once a day: an identical file only needs its date updated (programmes
            // that ended are pruned separately).
            let contentHash = file.sha256 + "|" + wanted.fingerprint
            if hasCurrentImport, contentHash == previousHash {
                try markUnchanged(sourceID: sourceID, now: now, validators: file.validators)
                return unchangedSummary(downloadedBytes: file.bytes)
            }
            let summary = try await importFile(file.url, sourceID: sourceID, wanted: wanted, now: now, downloadedBytes: file.bytes, startedAt: startedAt, progress: progress)
            // A guide cut short is read again in full next time, even if the server sends the same file.
            try storeFileIdentity(summary.isComplete ? (contentHash, file.validators) : nil, sourceID: sourceID)
            Self.logger.info("Guide \(url.host() ?? "", privacy: .public): \(summary.programmeCount) programmes of \(summary.storedChannelCount)/\(summary.channelCount) channels in \(String(describing: summary.duration), privacy: .public)\(summary.isComplete ? "" : " (incomplete file)", privacy: .public)")
            return summary
        } catch {
            if !(error is CancellationError) {
                recordFailure(sourceID: sourceID, error: error)
            }
            throw error
        }
    }

    /// Reads a local XMLTV file (plain or gzip) into a new import of the source and makes it the current one.
    func importFile(
        _ fileURL: URL,
        sourceID: UUID,
        wanted: EPGWantedChannels,
        now: Date = .now,
        downloadedBytes: Int64 = 0,
        startedAt: ContinuousClock.Instant? = nil,
        progress: @escaping @Sendable (EPGRefreshProgress) -> Void
    ) async throws -> EPGRefreshSummary {
        let clock = ContinuousClock()
        let startedAt = startedAt ?? clock.now
        let importID = UUID()
        runningImports.insert(importID)
        defer {
            runningImports.remove(importID)
        }

        let window = DateInterval(start: now.addingTimeInterval(-Self.windowBefore), end: now.addingTimeInterval(Self.windowAfter))
        let job = EPGParseJob(
            container: container,
            fileURL: fileURL,
            sourceID: sourceID,
            importID: importID,
            window: window,
            wanted: wanted,
            batchSize: batchSize,
            maximumStoredChannels: Self.maximumStoredChannels,
            progress: progress
        )
        do {
            let result = try await job.run()
            guard result.channelCount > 0 || result.programmeCount > 0 else {
                throw EPGImportError.notXMLTV
            }
            try Task.checkCancellation()
            // A file cut short (truncated download or gzip, broken XML) is only better than nothing: keep the
            // current guide when it has more programmes.
            if !result.isComplete, try currentProgrammeCount(sourceID: sourceID) > result.programmeCount {
                throw EPGImportError.incomplete
            }
            progress(EPGRefreshProgress(phase: .finishing, fractionCompleted: 1, bytes: downloadedBytes, programmeCount: result.programmeCount))
            try commit(importID: importID, sourceID: sourceID, result: result, now: now)
            return EPGRefreshSummary(
                channelCount: result.channelCount,
                storedChannelCount: result.storedChannelCount,
                programmeCount: result.programmeCount,
                downloadedBytes: downloadedBytes,
                duration: clock.now - startedAt,
                isComplete: result.isComplete
            )
        } catch {
            discard(importID: importID)
            throw error
        }
    }

    // MARK: - Sources

    /// Creates `EPGSource`s for the guide URLs the playlist header lists and removes the ones it no longer lists.
    /// Returns the sources that were added (they need a first refresh).
    @discardableResult
    func syncSources(ofPlaylist playlistID: UUID) async throws -> [UUID] {
        let context = makeContext()
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.uuid == playlistID })
        descriptor.fetchLimit = 1
        let existing = try context.fetch(EPGQueries.sources(playlistID: playlistID))
        guard let playlist = try context.fetch(descriptor).first else {
            let removed = existing.map(RemovedSource.init)
            for source in existing {
                context.delete(source)
            }
            try context.save()
            try await deleteRows(of: removed)
            return []
        }

        let urls = Self.guideURLs(in: playlist.guideURLString)
        var added: [UUID] = []
        var removed: [RemovedSource] = []
        for source in existing where !urls.contains(source.url) {
            removed.append(RemovedSource(source))
            context.delete(source)
        }
        let known = Set(existing.map(\.url))
        for url in urls where !known.contains(url) {
            let source = EPGSource(url: url, name: Self.defaultName(for: url), playlistID: playlistID)
            context.insert(source)
            added.append(source.uuid)
        }
        try context.save()
        try await deleteRows(of: removed)
        return added
    }

    /// The loaded, enabled sources that serve `playlistID` (its own header guides and the guides the user added)
    /// whose stored programmes were selected for a different set of channels. Only the channels wanted at the
    /// last refresh were kept, so after the playlist changed these must be read again for its new channels to
    /// get a guide. Sources whose wanted channels did not change are left alone.
    func sourcesNeedingRematch(forPlaylist playlistID: UUID) throws -> [UUID] {
        let candidates = try makeContext().fetch(EPGQueries.sources())
            .filter { $0.isEnabled && $0.currentImportID != nil && ($0.playlistID == nil || $0.playlistID == playlistID) }
            .map { (uuid: $0.uuid, playlistID: $0.playlistID, fingerprint: Self.wantedFingerprint(inContentHash: $0.contentHash)) }
        var stale: [UUID] = []
        for candidate in candidates {
            let wanted = try wantedChannels(playlistID: candidate.playlistID, sourceID: candidate.uuid)
            if wanted.fingerprint != candidate.fingerprint {
                stale.append(candidate.uuid)
            }
        }
        return stale
    }

    /// The `EPGWantedChannels.fingerprint` part of `EPGSource.contentHash` ("<sha256>|<fingerprint>").
    private static func wantedFingerprint(inContentHash hash: String?) -> String? {
        guard let hash, let separator = hash.lastIndex(of: "|") else {
            return nil
        }
        return String(hash[hash.index(after: separator)...])
    }

    /// Playlists imported before the TV guide existed never had their header read: read just its first line
    /// (the `#EXTM3U` header) once, instead of waiting for the next playlist refresh.
    func discoverHeaderGuides() async {
        let pending: [(UUID, URL)]
        do {
            pending = try makeContext().fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.guideHeaderCheckedOn == nil && $0.currentImportID != nil }))
                .map { ($0.uuid, $0.url) }
        } catch {
            return
        }
        for (playlistID, url) in pending {
            guard !Task.isCancelled else {
                return
            }
            guard let urls = await Self.headerGuideURLs(of: url) else {
                // Offline or an error: try again at the next launch.
                continue
            }
            do {
                let context = makeContext()
                var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.uuid == playlistID })
                descriptor.fetchLimit = 1
                guard let playlist = try context.fetch(descriptor).first, playlist.guideHeaderCheckedOn == nil else {
                    continue
                }
                playlist.guideURLString = urls.isEmpty ? nil : urls.joined(separator: ",")
                playlist.guideHeaderCheckedOn = .now
                try context.save()
            } catch {
                Self.logger.error("Could not store the guide URLs of a playlist: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The guide URLs of a playlist's `#EXTM3U` header, reading only the start of the file. nil on failure.
    @concurrent static func headerGuideURLs(of playlistURL: URL) async -> [String]? {
        var request = URLRequest(url: playlistURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            var parser = M3UParser()
            var lineCount = 0
            for try await line in bytes.lines {
                parser.consume(Data((line + "\n").utf8)) { _ in }
                lineCount += 1
                // The header is the first line; stop at the first entry.
                if parser.sawHeader || lineCount >= 3 {
                    break
                }
            }
            return parser.guideURLs
        } catch {
            return nil
        }
    }

    /// `syncSources(ofPlaylist:)` for every playlist, and removal of the sources of deleted playlists.
    @discardableResult
    func syncAllSources() async throws -> [UUID] {
        let context = makeContext()
        let playlistIDs = try context.fetch(FetchDescriptor<Playlist>()).map(\.uuid)
        let sourcePlaylistIDs = Set(try context.fetch(EPGQueries.sources()).compactMap(\.playlistID))
        var added: [UUID] = []
        for playlistID in Set(playlistIDs).union(sourcePlaylistIDs) {
            added += try await syncSources(ofPlaylist: playlistID)
        }
        return added
    }

    /// `isEnabled` is false for a guide that iCloud sync brought from another device where it is turned off.
    func addSource(url: URL, name: String?, isEnabled: Bool = true) throws -> UUID {
        let context = makeContext()
        if let existing = try context.fetch(EPGQueries.sources()).first(where: { $0.url == url && $0.playlistID == nil }) {
            return existing.uuid
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = EPGSource(url: url, name: trimmed.isEmpty ? Self.defaultName(for: url) : trimmed, playlistID: nil)
        source.isEnabled = isEnabled
        context.insert(source)
        try context.save()
        return source.uuid
    }

    func setEnabled(_ isEnabled: Bool, sourceID: UUID) throws {
        let context = makeContext()
        guard let source = try context.fetch(EPGQueries.source(uuid: sourceID)).first else {
            return
        }
        source.isEnabled = isEnabled
        try context.save()
    }

    /// Deletes a source with its manual matches, channels and programmes (`removeSource` then `deleteRows`).
    /// Deleting a source that no longer exists does nothing.
    func deleteSource(_ sourceID: UUID) async throws {
        let removed = try removeSource(sourceID)
        try await deleteRows(of: [removed])
    }

    /// The quick part of deleting a source: the source row and the manual matches that point to it, in one save,
    /// so the guide stops showing it at once (`EPGReader` only reads the programmes of existing sources). Returns
    /// what `deleteRows(of:)` must then remove.
    func removeSource(_ sourceID: UUID) throws -> RemovedSource {
        let context = makeContext()
        var removed = RemovedSource(sourceID: sourceID, importIDs: [])
        if let source = try context.fetch(EPGQueries.source(uuid: sourceID)).first {
            removed = RemovedSource(source)
            context.delete(source)
        }
        try context.delete(model: EPGChannelOverride.self, where: Self.overridePredicate(sourceID: sourceID))
        try context.save()
        return removed
    }

    /// The slow part of deleting sources: their programmes (hundreds of thousands for a large guide) and channels.
    ///
    /// Programmes go a few channels at a time through the `importID` + `channelID` index, each chunk in its own
    /// save: one huge delete would hold the store's write lock for seconds and block every other save meanwhile
    /// (the main context's included). A last pass by `sourceID` removes rows of any other import of the source
    /// (a refresh that was cut short). Rows this leaves behind (the app quit meanwhile) are orphans, which
    /// `purgeOrphanedContent()` removes at the next launch.
    func deleteRows(of sources: [RemovedSource]) async throws {
        for source in sources {
            for importID in source.importIDs {
                var descriptor = FetchDescriptor<EPGChannel>(predicate: #Predicate { $0.importID == importID && $0.hasProgrammes == true })
                descriptor.propertiesToFetch = [\.channelID]
                let channelIDs = Array(Set(try makeContext().fetch(descriptor).map(\.channelID)))
                for start in stride(from: 0, to: channelIDs.count, by: Self.deletionChunkChannels) {
                    let chunk = Array(channelIDs[start..<min(start + Self.deletionChunkChannels, channelIDs.count)])
                    let context = makeContext()
                    try context.delete(model: EPGProgramme.self, where: #Predicate { $0.importID == importID && chunk.contains($0.channelID) })
                    try context.save()
                    await Task.yield()
                }
            }
            let context = makeContext()
            let sourceID = source.sourceID
            try context.delete(model: EPGProgramme.self, where: #Predicate { $0.sourceID == sourceID })
            try context.delete(model: EPGChannel.self, where: #Predicate { $0.sourceID == sourceID })
            try context.save()
        }
    }

    /// Channels whose programmes `deleteRows(of:)` deletes in one save (a few tens of thousands of rows for a
    /// week of half-hour programmes).
    static let deletionChunkChannels = 100

    /// A source removed from the store whose guide rows are still to be deleted.
    struct RemovedSource: Sendable {
        let sourceID: UUID
        /// The imports whose rows are deleted through the index (the current one).
        let importIDs: [UUID]

        init(sourceID: UUID, importIDs: [UUID]) {
            self.sourceID = sourceID
            self.importIDs = importIDs
        }

        init(_ source: EPGSource) {
            self.init(sourceID: source.uuid, importIDs: source.currentImportID.map { [$0] } ?? [])
        }
    }

    // MARK: - Maintenance

    /// Deletes programmes that ended more than `windowBefore` ago.
    func prune(now: Date = .now) throws {
        let cutoff = now.addingTimeInterval(-Self.windowBefore)
        let context = makeContext()
        try context.delete(model: EPGProgramme.self, where: #Predicate { $0.stop < cutoff })
        try context.save()
    }

    /// Removes guide rows that no source shows (an interrupted refresh) and sources of deleted playlists.
    func purgeOrphanedContent() async throws {
        let context = makeContext()
        let playlistIDs = Set(try context.fetch(FetchDescriptor<Playlist>()).map(\.uuid))
        var removed: [RemovedSource] = []
        for source in try context.fetch(EPGQueries.sources()) {
            if let playlistID = source.playlistID, !playlistIDs.contains(playlistID) {
                removed.append(RemovedSource(source))
                context.delete(source)
            }
        }
        try context.save()
        try await deleteRows(of: removed)

        let keep = Array(Set(try context.fetch(EPGQueries.sources()).compactMap(\.currentImportID)).union(runningImports))
        try context.delete(model: EPGProgramme.self, where: #Predicate { !keep.contains($0.importID) })
        try context.delete(model: EPGChannel.self, where: #Predicate { !keep.contains($0.importID) })
        let livePlaylistIDs = Array(playlistIDs)
        try context.delete(model: EPGChannelOverride.self, where: #Predicate { !livePlaylistIDs.contains($0.playlistID) })
        try context.save()
    }

    // MARK: - Private

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    /// The tvg-ids and names of the live channels the source can serve: the channels of its playlist, or of
    /// every playlist for a guide the user added. Fetched a page at a time.
    private func wantedChannels(playlistID: UUID?, sourceID: UUID) throws -> EPGWantedChannels {
        var wanted = EPGWantedChannels()
        let pageSize = 5_000
        let playlists = try makeContext().fetch(FetchDescriptor<Playlist>())
        let importIDs = playlists.filter { playlistID == nil || $0.uuid == playlistID }.compactMap(\.currentImportID)
        for importID in importIDs {
            var offset = 0
            while true {
                let context = makeContext()
                var descriptor = EPGQueries.liveChannels(importID: importID, offset: offset, limit: pageSize)
                descriptor.propertiesToFetch = [\.name, \.tvgID]
                let page = try context.fetch(descriptor)
                for channel in page {
                    wanted.add(tvgID: channel.tvgID, name: channel.name)
                }
                guard page.count == pageSize else {
                    break
                }
                offset += pageSize
            }
        }
        wanted.overrideIDs = Set(try makeContext().fetch(EPGQueries.overrides(sourceID: sourceID)).map(\.channelID).filter { !$0.isEmpty })
        return wanted
    }

    /// `ETag` / `Last-Modified` of a guide file.
    private struct HTTPValidators {
        var entityTag: String?
        var lastModified: String?

        var isEmpty: Bool {
            entityTag == nil && lastModified == nil
        }

        var requestHeaders: [String: String] {
            var headers: [String: String] = [:]
            headers["If-None-Match"] = entityTag
            headers["If-Modified-Since"] = lastModified
            return headers
        }
    }

    private struct DownloadedFile {
        let url: URL
        let bytes: Int64
        let sha256: String
        let validators: HTTPValidators
    }

    /// Streams the file to disk while hashing it. With `validators`, the request is conditional and nil is
    /// returned when the server replies 304 Not Modified.
    private func download(_ url: URL, validators: HTTPValidators?, progress: @escaping @Sendable (EPGRefreshProgress) -> Void) async throws -> DownloadedFile? {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        let fileURL = downloadsDirectory.appendingPathComponent("guide-\(UUID().uuidString).download")
        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? handle.close()
            }
            let clock = ContinuousClock()
            var lastProgressAt = clock.now
            var bytes: Int64 = 0
            var hasher = SHA256()
            let isConditional = validators.map { !$0.isEmpty } ?? false
            let stream = DownloadManager.stream(from: url, headers: isConditional ? validators?.requestHeaders ?? [:] : [:])
            do {
                for try await chunk in stream {
                    try handle.write(contentsOf: chunk.data)
                    hasher.update(data: chunk.data)
                    bytes += Int64(chunk.data.count)
                    if bytes > Self.maximumDownloadBytes {
                        throw EPGImportError.tooLarge(Self.maximumDownloadBytes)
                    }
                    let now = clock.now
                    if now - lastProgressAt >= .milliseconds(200) {
                        lastProgressAt = now
                        progress(EPGRefreshProgress(phase: .downloading, fractionCompleted: chunk.fractionCompleted, bytes: bytes))
                    }
                }
            } catch DownloadError.httpStatus(304) where isConditional {
                try? fileManager.removeItem(at: fileURL)
                return nil
            }
            // The stream ends quietly when the consuming task is cancelled.
            try Task.checkCancellation()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let response = stream.response
            let received = HTTPValidators(
                entityTag: response?.value(forHTTPHeaderField: "ETag"),
                lastModified: response?.value(forHTTPHeaderField: "Last-Modified")
            )
            return DownloadedFile(url: fileURL, bytes: bytes, sha256: digest, validators: received)
        } catch {
            try? fileManager.removeItem(at: fileURL)
            throw error
        }
    }

    private func commit(importID: UUID, sourceID: UUID, result: EPGParseJob.Result, now: Date) throws {
        let context = makeContext()
        guard let source = try context.fetch(EPGQueries.source(uuid: sourceID)).first else {
            throw EPGImportError.sourceNotFound
        }
        let previousImportID = source.currentImportID
        source.currentImportID = importID
        source.channelCount = result.channelCount
        source.storedChannelCount = result.storedChannelCount
        source.programmeCount = result.programmeCount
        source.lastRefreshedOn = now
        source.lastError = nil
        try context.save()

        if let previousImportID {
            do {
                try context.delete(model: EPGProgramme.self, where: #Predicate { $0.importID == previousImportID })
                try context.delete(model: EPGChannel.self, where: #Predicate { $0.importID == previousImportID })
                try context.save()
            } catch {
                // The new guide is already live; leftovers are removed by the next purge.
                Self.logger.error("Could not delete the previous guide: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The stored guide is current. `validators` replace the stored ones (a server may send new ones for the
    /// same file).
    private func markUnchanged(sourceID: UUID, now: Date, validators: HTTPValidators? = nil) throws {
        let context = makeContext()
        guard let source = try context.fetch(EPGQueries.source(uuid: sourceID)).first else {
            throw EPGImportError.sourceNotFound
        }
        source.lastRefreshedOn = now
        source.lastError = nil
        if let validators {
            source.entityTag = validators.entityTag
            source.lastModifiedHeader = validators.lastModified
        }
        try context.save()
    }

    /// Remembers which file the stored guide was read from; nil forgets it, so the next refresh reads the file
    /// again whatever the server says.
    private func storeFileIdentity(_ identity: (contentHash: String, validators: HTTPValidators)?, sourceID: UUID) throws {
        let context = makeContext()
        guard let source = try context.fetch(EPGQueries.source(uuid: sourceID)).first else {
            return
        }
        source.contentHash = identity?.contentHash
        source.entityTag = identity?.validators.entityTag
        source.lastModifiedHeader = identity?.validators.lastModified
        try context.save()
    }

    private func currentProgrammeCount(sourceID: UUID) throws -> Int {
        let context = makeContext()
        guard let source = try context.fetch(EPGQueries.source(uuid: sourceID)).first, source.currentImportID != nil else {
            return 0
        }
        return source.programmeCount
    }

    private func discard(importID: UUID) {
        do {
            let context = makeContext()
            try context.delete(model: EPGProgramme.self, where: #Predicate { $0.importID == importID })
            try context.delete(model: EPGChannel.self, where: #Predicate { $0.importID == importID })
            try context.save()
        } catch {
            Self.logger.error("Could not discard a guide import: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordFailure(sourceID: UUID, error: any Error) {
        do {
            let context = makeContext()
            guard let source = try context.fetch(EPGQueries.source(uuid: sourceID)).first else {
                return
            }
            source.lastError = GuideRefreshFailure(error).stored
            try context.save()
        } catch {
            Self.logger.error("Could not record a guide failure: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func overridePredicate(sourceID: UUID) -> Predicate<EPGChannelOverride> {
        let sourceID: UUID? = sourceID
        return #Predicate { $0.sourceID == sourceID }
    }

    // MARK: - Helpers

    /// The http(s) URLs of a comma-separated `Playlist.guideURLString`.
    static func guideURLs(in value: String?) -> [URL] {
        guard let value else {
            return []
        }
        var seen: Set<URL> = []
        return value.split(separator: ",").compactMap { part -> URL? in
            let string = part.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else {
                return nil
            }
            return seen.insert(url).inserted ? url : nil
        }
    }

    /// The host, without "www." ("epg.example.com"): short enough for a row. The file name is shown next to
    /// it (`fileName(of:)`).
    static func defaultName(for url: URL) -> String {
        guard let host = url.host(), !host.isEmpty else {
            return url.absoluteString
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "guide.xml.gz"; nil when the URL has no file name.
    static func fileName(of url: URL) -> String? {
        let file = url.lastPathComponent
        return file.isEmpty || file == "/" ? nil : file
    }
}

/// One parse of a guide file on a utility queue: XMLParser reads synchronously, so it gets a thread of its own
/// instead of blocking the cooperative pool. Rows are written in batches, each in a fresh `ModelContext`.
///
/// Unchecked `Sendable`: the job is handed to that queue once (`run()`), and the parse state (the batches, `result`)
/// is only touched there, by the parser's callbacks on the parsing thread. The only state another thread reaches is
/// `cancellation`, behind its lock.
private final class EPGParseJob: @unchecked Sendable {

    struct Result: Sendable {
        var channelCount = 0
        var storedChannelCount = 0
        var programmeCount = 0
        /// False when the stream or the XML ended early (what was read is still stored).
        var isComplete = true
    }

    private let container: ModelContainer
    private let fileURL: URL
    private let sourceID: UUID
    private let importID: UUID
    private let window: DateInterval
    private let wanted: EPGWantedChannels
    private let batchSize: Int
    private let maximumStoredChannels: Int
    private let progress: @Sendable (EPGRefreshProgress) -> Void

    private let cancellation = OSAllocatedUnfairLock(initialState: false)

    // Only touched on the parse thread.
    private var channelBatch: [XMLTVChannel] = []
    private var channelWanted: [Bool] = []
    private var programmeBatch: [XMLTVProgramme] = []
    private var channelsWithProgrammes: Set<String> = []
    private var result = Result()
    private var lastProgress = Date.distantPast

    init(
        container: ModelContainer,
        fileURL: URL,
        sourceID: UUID,
        importID: UUID,
        window: DateInterval,
        wanted: EPGWantedChannels,
        batchSize: Int,
        maximumStoredChannels: Int,
        progress: @escaping @Sendable (EPGRefreshProgress) -> Void
    ) {
        self.container = container
        self.fileURL = fileURL
        self.sourceID = sourceID
        self.importID = importID
        self.window = window
        self.wanted = wanted
        self.batchSize = batchSize
        self.maximumStoredChannels = maximumStoredChannels
        self.progress = progress
    }

    @concurrent func run() async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try self.parseAndStore())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
        }
    }

    private var isCancelled: Bool {
        cancellation.withLock { $0 }
    }

    private func parseAndStore() throws -> Result {
        guard let stream = InflatingInputStream(fileURL: fileURL) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        stream.open()
        defer {
            stream.close()
        }
        if let error = stream.streamError {
            throw error
        }

        var storeError: (any Error)?
        let wanted = wanted
        let parser = XMLTVParser(
            window: window,
            wantsChannel: { channel in
                wanted.contains(channelID: channel.id, names: channel.displayNames)
            },
            wantsChannelID: { channelID in
                wanted.containsID(channelID)
            },
            onChannel: { [unowned self] channel, isWanted in
                result.channelCount += 1
                guard result.channelCount <= maximumStoredChannels || isWanted else {
                    return
                }
                channelBatch.append(channel)
                channelWanted.append(isWanted)
                if channelBatch.count >= batchSize {
                    do {
                        try flushChannels()
                    } catch {
                        storeError = error
                        cancellation.withLock { $0 = true }
                    }
                }
            },
            onProgramme: { [unowned self] programme in
                programmeBatch.append(programme)
                channelsWithProgrammes.insert(programme.channelID)
                if programmeBatch.count >= batchSize {
                    do {
                        try flushProgrammes()
                    } catch {
                        storeError = error
                        cancellation.withLock { $0 = true }
                    }
                }
                reportProgress(bytes: stream.totalBytesRead)
            },
            isCancelled: { [unowned self] in
                isCancelled
            }
        )

        do {
            try parser.parse(stream)
        } catch {
            throw storeError ?? error
        }
        if let storeError {
            throw storeError
        }
        if let streamError = stream.streamError, result.programmeCount + programmeBatch.count == 0 {
            throw streamError
        }
        result.isComplete = !parser.endedEarly && stream.streamError == nil
        try flushChannels()
        try flushProgrammes()
        try markChannelsWithProgrammes()
        result.storedChannelCount = channelsWithProgrammes.count
        return result
    }

    private func reportProgress(bytes: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastProgress) > 0.2 else {
            return
        }
        lastProgress = now
        progress(EPGRefreshProgress(phase: .reading, fractionCompleted: nil, bytes: bytes, programmeCount: result.programmeCount + programmeBatch.count))
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func flushChannels() throws {
        guard !channelBatch.isEmpty else {
            return
        }
        try autoreleasepool {
            let context = makeContext()
            for (channel, isWanted) in zip(channelBatch, channelWanted) {
                let names = channel.displayNames
                context.insert(EPGChannel(
                    sourceID: sourceID,
                    importID: importID,
                    channelID: channel.id,
                    displayName: names.first ?? channel.id,
                    otherNames: names.dropFirst().joined(separator: "\n"),
                    icon: channel.icon,
                    // Corrected by markChannelsWithProgrammes() at the end.
                    hasProgrammes: isWanted
                ))
            }
            try context.save()
        }
        channelBatch.removeAll(keepingCapacity: true)
        channelWanted.removeAll(keepingCapacity: true)
    }

    private func flushProgrammes() throws {
        guard !programmeBatch.isEmpty else {
            return
        }
        try autoreleasepool {
            let context = makeContext()
            for programme in programmeBatch {
                context.insert(EPGProgramme(
                    sourceID: sourceID,
                    importID: importID,
                    channelID: programme.channelID,
                    start: programme.start,
                    stop: programme.stop,
                    title: programme.title,
                    subtitle: programme.subtitle,
                    summary: programme.summary,
                    categories: programme.categories.joined(separator: "\n"),
                    icon: programme.icon,
                    episode: programme.episode
                ))
            }
            try context.save()
        }
        result.programmeCount += programmeBatch.count
        programmeBatch.removeAll(keepingCapacity: true)
    }

    /// Wanted channels without a single programme in the window are not matchable; channels that got
    /// programmes without a `<channel>` element get one.
    private func markChannelsWithProgrammes() throws {
        let importID = importID
        let context = makeContext()
        let wantedChannels = try context.fetch(FetchDescriptor<EPGChannel>(predicate: #Predicate { $0.importID == importID && $0.hasProgrammes == true }))
        var declared: Set<String> = []
        for channel in wantedChannels {
            declared.insert(channel.channelID)
            if !channelsWithProgrammes.contains(channel.channelID) {
                channel.hasProgrammes = false
            }
        }
        let undeclared = channelsWithProgrammes.subtracting(declared)
        if !undeclared.isEmpty {
            let undeclaredIDs = Array(undeclared)
            let existing = try context.fetch(FetchDescriptor<EPGChannel>(predicate: #Predicate { $0.importID == importID && undeclaredIDs.contains($0.channelID) }))
            for channel in existing {
                channel.hasProgrammes = true
            }
            for channelID in undeclared.subtracting(existing.map(\.channelID)) {
                result.channelCount += 1
                context.insert(EPGChannel(sourceID: sourceID, importID: importID, channelID: channelID, displayName: channelID, otherNames: "", icon: nil, hasProgrammes: true))
            }
        }
        try context.save()
    }
}
