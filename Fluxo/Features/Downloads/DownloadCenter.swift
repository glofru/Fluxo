//
//  DownloadCenter.swift
//  Fluxo
//
//  Offline downloads of movies and episodes: the queue, the transfers (`DownloadTransport`), the conversion of
//  formats AVPlayer cannot play into MP4 (the remux engine), the manifest on disk, and what the UI asks: is this
//  downloaded, how far along is it, where is the file to play.
//
//  - A download is keyed like a bookmark (playlist + stream URL), so a downloaded episode plays with the resume
//    position, the watched state and the series progress of the playlist entry.
//  - At most `DownloadPreferences.maximumConcurrentTransfers` transfers run at once; the others wait in order.
//  - Before a transfer starts, the link is probed (HLS or a file, its size) and the free space is checked (twice
//    the size for a file that is converted afterwards).
//  - Network failures are retried automatically (three times, from where the transfer stopped); a refused or
//    vanished link is looked up again in the current copy of the playlist (providers renew their links), then
//    reported. A download whose media the system removed (storage pressure) is marked missing.
//  - Files live in `Application Support/Downloads/<id>/` (excluded from backups: they can be downloaded again);
//    HLS packages where AVFoundation puts them. The manifest is `Downloads/downloads.json`.
//

import AVFoundation
import Foundation
import Observation
import os
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// The progress of one transfer. Its own object, so only the rows that show it re-render as it moves.
@MainActor
@Observable
final class DownloadProgress {
    fileprivate(set) var fraction: Double = 0
    fileprivate(set) var bytesWritten: Int64 = 0
    /// The size of the download, once known (the transfer sets it when its plan gives it).
    var bytesExpected: Int64?
    /// Smoothed transfer speed; nil until measured.
    fileprivate(set) var bytesPerSecond: Double?

    @ObservationIgnored fileprivate var lastSample: (time: CFAbsoluteTime, bytes: Int64)?

    /// The time left at the current speed.
    var remaining: TimeInterval? {
        guard let bytesPerSecond, bytesPerSecond > 0, let bytesExpected, bytesExpected > bytesWritten else {
            return nil
        }
        return Double(bytesExpected - bytesWritten) / bytesPerSecond
    }

    /// A progress event of the transfer: `written` of `expected` bytes, `fraction` done. Asset tasks of HLS
    /// (`countsUnits`) count units, not bytes: their bytes are estimated from `estimatedSize`, the expected size of
    /// the download.
    func update(written: Int64, expected: Int64?, fraction: Double, countsUnits: Bool, estimatedSize: Int64?) {
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastSample, now > last.time, written >= last.bytes, written > 0 {
            let speed = Double(written - last.bytes) / (now - last.time)
            bytesPerSecond = bytesPerSecond.map { $0 * 0.7 + speed * 0.3 } ?? speed
        }
        lastSample = (now, written)
        self.fraction = fraction
        if countsUnits {
            if let estimatedSize {
                bytesWritten = Int64(Double(estimatedSize) * fraction)
            }
        } else {
            bytesWritten = written
            if let expected {
                bytesExpected = expected
            }
        }
    }
}

/// The downloaded movies and the series with downloaded episodes, for the Library.
enum DownloadGroup: Identifiable {
    case single(DownloadRecord)
    case series(id: String, title: String, records: [DownloadRecord])

    var id: String {
        switch self {
        case .single(let record):
            return record.id.uuidString
        case .series(let id, _, _):
            return id
        }
    }

    var records: [DownloadRecord] {
        switch self {
        case .single(let record):
            return [record]
        case .series(_, _, let records):
            return records
        }
    }
}

/// The offline downloads. This file has their state, the queries and the actions; the queue and the transfers are in
/// `DownloadCenter+Transfers`, the conversion to MP4 in `DownloadCenter+Conversion`, launch and the files on disk in
/// `DownloadCenter+Files`. The extensions use the state declared here, so it is internal; `records` changes here only.
@MainActor
@Observable
final class DownloadCenter {
    nonisolated static let resumeDataFileName = "resume.data"
    /// The automatic retries of a transfer after network failures.
    static let maximumAutomaticRetries = 3

    static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Downloads")

    /// Application Support/Downloads, or the isolated folder of a debug run (`-FluxoDebugStore`).
    nonisolated static var defaultDirectory: URL {
        #if DEBUG
        if let directory = DebugEnvironment.shared?.downloadsDirectory {
            return directory
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Every download, oldest first.
    private(set) var records: [DownloadRecord] = [] {
        didSet {
            rebuildIndex()
        }
    }

    /// Why the last download could not start; shown in an alert, then cleared.
    var notice: DownloadNotice?

    let directory: URL

    @ObservationIgnored let transport: DownloadTransport
    @ObservationIgnored let container: ModelContainer?
    @ObservationIgnored private var indexByKey: [String: Int] = [:]
    /// The same entries by what stays when a provider renews its links (`identityKey`).
    @ObservationIgnored private var indexByIdentity: [String: Int] = [:]
    @ObservationIgnored private var indexByID: [UUID: Int] = [:]
    @ObservationIgnored var progressObjects: [UUID: DownloadProgress] = [:]
    /// Downloads whose transfer is being started (probe, HLS loading), so the queue does not start them twice.
    @ObservationIgnored var starting: Set<UUID> = []
    /// File transfers being stopped (their resume data is on its way): they start again only once it is kept.
    @ObservationIgnored var stopping: Set<UUID> = []
    @ObservationIgnored var convertingID: UUID?
    /// A conversion found the video encoder unavailable (the app in the background): conversions start again once
    /// the app is active.
    @ObservationIgnored var conversionsWaitForActiveApp = false
    @ObservationIgnored private var activeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isStarted = false
    /// The transfers that survived a relaunch were matched with their records: the queue may start transfers.
    @ObservationIgnored var isReady = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// How the manifest read at launch went: the records this build cannot read (written back by each save) and the
    /// folders kept for them (the orphan sweep).
    @ObservationIgnored var manifestRead = DownloadManifest.ReadResult()
    @ObservationIgnored var retryTask: Task<Void, Never>?
    /// Downloads queued again after a network error: the queue starts them no earlier than this (5, 20, 80 s).
    @ObservationIgnored var retryNotBefore: [UUID: Date] = [:]
    /// Downloads played to the end, deleted once they no longer play ("Delete Watched Downloads").
    @ObservationIgnored private var pendingWatchedDeletions: Set<UUID> = []
    /// Played to the end, to download the next episode (once per episode).
    @ObservationIgnored private var nextEpisodeRequested: Set<String> = []

    /// The entry that plays now (set by the app): its download is never deleted under it.
    @ObservationIgnored var currentlyPlayingItem: @MainActor () -> ChannelItem? = { nil }
    /// Stops playback of the entry that plays now when it plays from its download, which is about to be deleted
    /// (set by the app).
    @ObservationIgnored var willDeleteMedia: @MainActor () -> Void = {}

    init(container: ModelContainer?, directory: URL? = nil, transport: DownloadTransport? = nil) {
        self.container = container
        self.directory = directory ?? Self.defaultDirectory
        self.transport = transport ?? .shared
        Self.prepareDirectory(self.directory)
        let manifest = DownloadManifest.read(in: self.directory)
        manifestRead = manifest
        records = manifest.records
    }

    /// Restores the transfers that ran before the app was relaunched, checks the files and starts the queue. Once.
    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        guard PlatformFeatures.offlineDownloads else {
            // Apple TV: nothing downloads, so there is nothing to restore (the manifest stays empty).
            isReady = true
            return
        }
        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
        NetworkMonitor.shared.addObserver { [weak self] online in
            if online {
                self?.networkDidReturn()
            }
        }
        #if canImport(UIKit)
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.conversionsWaitForActiveApp else {
                    return
                }
                self.conversionsWaitForActiveApp = false
                self.pump()
            }
        }
        #endif
        verifyCompletedFiles()
        let needsTransport = records.contains { $0.status.isPending && $0.status != .failed }
        Task {
            let restored = needsTransport ? await transport.restoreTasks() : [:]
            reconcile(restored: restored)
            sweepOrphanedFolders()
            isReady = true
            if DownloadPreferences.deletesWatched {
                deleteWatched(onlyIfIdle: true)
            }
            pump()
        }
    }

    // MARK: - Queries

    func canDownload(_ item: ChannelItem) -> Bool {
        guard PlatformFeatures.offlineDownloads, item.kind != .live, let scheme = item.url?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    /// The download of `item`, if any. Views that ask while there is none must still redraw when one is added:
    /// `records` is read first (the indexes are not observed), so every lookup depends on it, found or not.
    func record(for item: ChannelItem) -> DownloadRecord? {
        let records = self.records
        guard let key = item.bookmarkKey else {
            return nil
        }
        if let index = indexByKey[key] {
            return records[index]
        }
        // The playlist was imported again with renewed links (a new token or password): the same entry still
        // finds its download, so it shows as downloaded and plays from the file.
        guard let url = item.url, let index = indexByIdentity[Self.identityKey(playlistID: item.playlistID, kind: item.kind.rawValue, name: item.name, episode: item.series?.code.rawValue, url: url)] else {
            return nil
        }
        return records[index]
    }

    /// An entry's playlist, kind, name, episode and file name: providers renew the token, user name or password in
    /// a link, not the stream's own file name (`…/movie/user/pass/1234.mkv`, `…/video.m3u8?token=…`).
    private nonisolated static func identityKey(playlistID: UUID, kind: Int, name: String?, episode: String?, url: URL) -> String {
        [playlistID.uuidString, String(kind), name ?? "", episode ?? "", url.lastPathComponent].joined(separator: "\u{1F}")
    }

    func record(id: UUID) -> DownloadRecord? {
        // `records` first, for the same reason as `record(for:)`.
        let records = self.records
        return indexByID[id].map { records[$0] }
    }

    func status(for item: ChannelItem) -> DownloadStatus? {
        record(for: item)?.status
    }

    /// The progress object of a download (created on first use).
    func progress(for record: DownloadRecord) -> DownloadProgress {
        if let progress = progressObjects[record.id] {
            return progress
        }
        let progress = DownloadProgress()
        progress.fraction = record.fraction
        progress.bytesWritten = record.bytesWritten
        progress.bytesExpected = record.bytesExpected
        progressObjects[record.id] = progress
        return progress
    }

    /// The local media of a completed download of `item`, to play instead of the stream; nil when there is none
    /// (or it went missing).
    func localPlaybackURL(for item: ChannelItem) -> URL? {
        guard let record = record(for: item), record.status == .completed, !record.isMissing else {
            return nil
        }
        guard let url = mediaURL(of: record), FileManager.default.fileExists(atPath: url.path) else {
            markMissing(record.id)
            return nil
        }
        return url
    }

    /// The entry to play for a download, with its own copy of the artwork.
    func playableItem(for record: DownloadRecord) -> ChannelItem {
        record.item.channelItem(logo: artworkSource(for: record))
    }

    /// The artwork to show: the copy kept with the download, else the playlist's.
    func artworkSource(for record: DownloadRecord) -> String? {
        if let name = record.artworkFileName {
            let url = folder(of: record.id).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.absoluteString
            }
        }
        return record.item.logo
    }

    /// Why a transfer that should run does not move: no network, or Wi-Fi only on cellular.
    func waitingReason(for record: DownloadRecord) -> String? {
        guard record.status == .downloading || record.status == .queued || record.status == .preparing else {
            return nil
        }
        let network = NetworkMonitor.shared
        if network.isOffline {
            return String(localized: "Waiting for a network connection", comment: "Status of a download that waits until the device is online again.")
        }
        if !DownloadPreferences.allowsCellular, network.isCellularOnly {
            return String(localized: "Waiting for Wi-Fi", comment: "Status of a download that waits for Wi-Fi because cellular data is not allowed for downloads.")
        }
        return nil
    }

    /// The downloads of a series, in watching order.
    func records(ofSeries playlistID: UUID, key: String) -> [DownloadRecord] {
        records
            .filter { $0.item.playlistID == playlistID && $0.item.seriesKey == key }
            .sorted { lhs, rhs in
                let left = lhs.item.series?.code
                let right = rhs.item.series?.code
                if let left, let right, left != right {
                    return left < right
                }
                return lhs.addedOn < rhs.addedOn
            }
    }

    /// Completed downloads of a series (series cards show a badge).
    func completedCount(ofSeries series: SeriesItem) -> Int {
        records.reduce(0) { count, record in
            count + (record.item.playlistID == series.playlistID && record.item.seriesKey == series.key && record.status == .completed ? 1 : 0)
        }
    }

    /// Movies alone, the episodes of a series together; newest first.
    var groups: [DownloadGroup] {
        var seriesRecords: [String: [DownloadRecord]] = [:]
        var order: [(date: Date, group: String?)] = []
        var singles: [String: DownloadRecord] = [:]
        for record in records {
            if let seriesID = record.seriesID {
                if seriesRecords[seriesID] == nil {
                    order.append((record.addedOn, seriesID))
                }
                seriesRecords[seriesID, default: []].append(record)
            } else {
                singles[record.id.uuidString] = record
                order.append((record.addedOn, record.id.uuidString))
            }
        }
        var groups: [(Date, DownloadGroup)] = []
        for (_, id) in order {
            guard let id else {
                continue
            }
            if let records = seriesRecords[id], let first = records.first, let key = first.item.seriesKey {
                let sorted = self.records(ofSeries: first.item.playlistID, key: key)
                let newest = records.map(\.addedOn).max() ?? first.addedOn
                groups.append((newest, .series(id: id, title: first.title, records: sorted)))
            } else if let record = singles[id] {
                groups.append((record.addedOn, .single(record)))
            }
        }
        return groups.sorted { $0.0 > $1.0 }.map(\.1)
    }

    /// `groups` with only the completed downloads (and without the missing ones when `excludingMissing`).
    func completedGroups(excludingMissing: Bool = false) -> [DownloadGroup] {
        func isShown(_ record: DownloadRecord) -> Bool {
            record.status == .completed && !(excludingMissing && record.isMissing)
        }
        return groups.compactMap { group in
            switch group {
            case .single(let record):
                return isShown(record) ? group : nil
            case let .series(id, title, records):
                let shown = records.filter(isShown)
                return shown.isEmpty ? nil : .series(id: id, title: title, records: shown)
            }
        }
    }

    var hasDownloads: Bool {
        !records.isEmpty
    }

    var completedCount: Int {
        records.count(where: { $0.status == .completed })
    }

    var activeCount: Int {
        records.count(where: { $0.status.isActive })
    }

    var pausedCount: Int {
        records.count(where: { $0.status == .paused })
    }

    /// Failed downloads that Retry can start again (not the ones whose format can never play).
    var retryableFailedCount: Int {
        records.count(where: { $0.status == .failed && !$0.failureIsPermanent })
    }

    var watchedCount: Int {
        records.count(where: { $0.status == .completed && $0.watchedOn != nil })
    }

    /// Space the downloads take (what is downloaded so far for the others).
    var totalBytes: Int64 {
        records.reduce(0) { $0 + ($1.status == .completed ? $1.bytesOnDisk : $1.bytesWritten) }
    }

    /// Free space on the device for downloads.
    var availableBytes: Int64? {
        PlatformStorage.availableCapacity(at: directory)
    }

    // MARK: - Actions

    /// Adds `item` to the queue. Nothing happens when it is already downloaded or queued.
    func download(_ item: ChannelItem) {
        enqueue([item])
    }

    /// Adds several items (a season) to the queue, in order.
    func download(_ items: [ChannelItem]) {
        enqueue(items)
    }

    func pause(_ id: UUID) {
        guard let record = record(id: id) else {
            return
        }
        switch record.status {
        case .queued, .preparing:
            update(id) { $0.status = .paused }
        case .downloading:
            update(id) { $0.status = .paused }
            switch record.method {
            case .hls:
                transport.suspend(id: id)
            case .file, .remux, nil:
                stopFileTransfer(id) {}
            }
        case .paused, .converting, .completed, .failed:
            return
        }
        pump()
    }

    func resume(_ id: UUID) {
        guard let record = record(id: id), record.status == .paused || record.status == .failed else {
            return
        }
        retryNotBefore[id] = nil
        update(id) {
            $0.status = .queued
            $0.failureReason = nil
            $0.automaticRetries = 0
        }
        pump()
    }

    /// Starts a failed download again (from where it stopped when possible).
    func retry(_ id: UUID) {
        guard let record = record(id: id) else {
            return
        }
        if record.isMissing {
            redownload(id)
            return
        }
        resume(id)
    }

    /// Deletes a download (stopping its transfer) and its files.
    func delete(_ id: UUID) {
        guard let record = record(id: id) else {
            return
        }
        if playingRecordID == id {
            willDeleteMedia()
        }
        transport.cancel(id: id)
        starting.remove(id)
        retryNotBefore[id] = nil
        pendingWatchedDeletions.remove(id)
        // A conversion of it cannot be stopped: it finishes on its own and its result is dropped. Its slot stays
        // taken until then, so two conversions never run at once.
        removeMedia(of: record)
        progressObjects[id] = nil
        records.removeAll { $0.id == id }
        saveSoon()
        pump()
    }

    func delete(_ ids: [UUID]) {
        for id in ids {
            delete(id)
        }
    }

    func pauseAll() {
        for record in records where record.status.isActive && record.status != .converting {
            pause(record.id)
        }
    }

    func resumeAll() {
        for record in records where record.status == .paused {
            update(record.id) {
                $0.status = .queued
                $0.failureReason = nil
                $0.automaticRetries = 0
            }
        }
        pump()
    }

    #if DEBUG
    /// Debug harness (`downloads-fake-failures`): lists a record as it is, without a transfer.
    func debugInsert(_ record: DownloadRecord) {
        records.append(record)
        saveSoon()
    }
    #endif

    /// Retry for every failed download that can be retried.
    func retryAllFailed() {
        for record in records where record.status == .failed && !record.failureIsPermanent {
            retry(record.id)
        }
    }

    func deleteAll() {
        delete(records.map(\.id))
    }

    /// Deletes the downloads played to the end. `onlyIfIdle` keeps the one that plays (launch, Settings).
    func deleteWatched(onlyIfIdle: Bool = true) {
        let playing = playingRecordID
        for record in records where record.status == .completed && record.watchedOn != nil {
            if onlyIfIdle, record.id == playing {
                pendingWatchedDeletions.insert(record.id)
                continue
            }
            delete(record.id)
        }
    }

    /// An item was played to the end (`ChannelLibrary`): its download counts as watched, may be deleted once
    /// something else plays, and may bring the next episode.
    func itemWasWatched(_ item: ChannelItem) {
        guard let record = record(for: item) else {
            return
        }
        if record.watchedOn == nil {
            update(record.id) { $0.watchedOn = .now }
        }
        if DownloadPreferences.deletesWatched, record.status == .completed {
            // Deleted once it no longer plays (at once when it does not, e.g. marked from the history).
            pendingWatchedDeletions.insert(record.id)
            playbackDidChange()
        }
        if DownloadPreferences.downloadsNextEpisode, item.series != nil, let key = item.bookmarkKey, !nextEpisodeRequested.contains(key), let container {
            nextEpisodeRequested.insert(key)
            Task {
                let next = await Task.detached(priority: .utility) {
                    SeriesLookup.nextEpisode(after: item, in: container)
                }.value
                if let next, self.record(for: next) == nil {
                    self.download(next)
                }
            }
        }
    }

    /// The download of what plays now, found like any lookup (by its link, or by what stays when the provider
    /// renews it), so a download kept under an older link is recognized too.
    private var playingRecordID: UUID? {
        currentlyPlayingItem().flatMap { record(for: $0)?.id }
    }

    /// What plays changed: watched downloads that no longer play are deleted ("Delete Watched Downloads").
    func playbackDidChange() {
        guard !pendingWatchedDeletions.isEmpty else {
            return
        }
        let playing = playingRecordID
        for id in pendingWatchedDeletions {
            guard let record = record(id: id), record.id != playing else {
                continue
            }
            pendingWatchedDeletions.remove(id)
            if DownloadPreferences.deletesWatched, record.watchedOn != nil {
                delete(id)
            }
        }
    }

    /// The playlist was deleted: so are its downloads.
    func playlistWasDeleted(_ playlistID: UUID) {
        delete(records.filter { $0.item.playlistID == playlistID }.map(\.id))
    }

    /// The Cellular Data setting changed: running transfers move to the session that applies it.
    func cellularSettingDidChange() {
        let allowsCellular = DownloadPreferences.allowsCellular
        for record in records where record.status == .downloading && record.allowsCellular != allowsCellular {
            let id = record.id
            switch record.method {
            case .hls:
                // AVFoundation continues the package that is already on disk.
                transport.cancel(id: id)
                update(id) { $0.status = .queued }
            case .file, .remux, nil:
                // Queued again once its resume data is kept, so it continues where it stopped.
                update(id) { $0.status = .paused }
                stopFileTransfer(id) { [weak self] in
                    self?.update(id) { record in
                        if record.status == .paused {
                            record.status = .queued
                        }
                    }
                }
            }
        }
        pump()
    }

    /// Cancels a file transfer keeping its resume data; until that is written, the download does not start again.
    private func stopFileTransfer(_ id: UUID, then: @escaping @MainActor () -> Void) {
        let url = folder(of: id).appendingPathComponent(Self.resumeDataFileName)
        stopping.insert(id)
        transport.pauseFile(id: id) { [weak self] data in
            if let data {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
            Task { @MainActor in
                self?.stopping.remove(id)
                then()
                self?.pump()
            }
        }
    }

    // MARK: - Queue

    private func enqueue(_ items: [ChannelItem]) {
        var added = 0
        for item in items where canDownload(item) {
            guard let snapshot = DownloadedItem(item) else {
                continue
            }
            if let existing = record(for: item) {
                if existing.status == .paused || existing.status == .failed {
                    resume(existing.id)
                }
                continue
            }
            records.append(DownloadRecord(id: UUID(), item: snapshot, status: .queued, addedOn: .now))
            added += 1
        }
        if added > 0 {
            AccessibilityAnnouncer.announce(added == 1
                ? String(localized: "Download added", comment: "VoiceOver announcement: a movie or episode was added to the downloads.")
                : String(localized: "\(added) downloads added", comment: "VoiceOver announcement: several episodes were added to the downloads; the placeholder is their number."))
        }
        saveSoon()
        pump()
    }

    // MARK: - Records

    func update(_ id: UUID, _ change: (inout DownloadRecord) -> Void) {
        guard let index = indexByID[id] else {
            return
        }
        var record = records[index]
        change(&record)
        guard record != records[index] else {
            return
        }
        records[index] = record
        saveSoon()
    }

    private func rebuildIndex() {
        var byKey: [String: Int] = [:]
        var byID: [UUID: Int] = [:]
        var byIdentity: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            byKey[record.key] = index
            byID[record.id] = index
            let item = record.item
            byIdentity[Self.identityKey(playlistID: item.playlistID, kind: item.kindRawValue, name: item.name, episode: item.series?.code.rawValue, url: item.url)] = index
        }
        indexByKey = byKey
        indexByID = byID
        indexByIdentity = byIdentity
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else {
                return
            }
            saveNow()
        }
    }

    /// Writes the manifest, with the latest progress of running transfers.
    func saveNow() {
        var snapshot = records
        for index in snapshot.indices {
            if let progress = progressObjects[snapshot[index].id], snapshot[index].status.isPending {
                snapshot[index].fraction = progress.fraction
                snapshot[index].bytesWritten = progress.bytesWritten
            }
        }
        do {
            try DownloadManifest.write(snapshot, keeping: &manifestRead, in: directory)
        } catch {
            Self.logger.error("Could not save the downloads: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes the folders of downloads no record owns (a crash between adding a download and saving the list, a
    /// download removed by an earlier build). Once, at launch, before the queue starts anything.
    private func sweepOrphanedFolders() {
        let orphans = DownloadManifest.orphanedFolders(in: directory, read: manifestRead, records: records)
        for folder in orphans {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                Self.logger.error("Could not delete an orphaned download folder: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !orphans.isEmpty {
            Self.logger.notice("Deleted \(orphans.count, privacy: .public) orphaned download folders")
        }
    }

    private static func prepareDirectory(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Downloads can be downloaded again: they stay out of device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }
}
