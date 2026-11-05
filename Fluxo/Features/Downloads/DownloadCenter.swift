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
    fileprivate(set) var bytesExpected: Int64?
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

@MainActor
@Observable
final class DownloadCenter {

    nonisolated static let resumeDataFileName = "resume.data"
    nonisolated static let manifestFileName = "downloads.json"
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

    @ObservationIgnored private let transport: DownloadTransport
    @ObservationIgnored private let container: ModelContainer?
    @ObservationIgnored private var indexByKey: [String: Int] = [:]
    /// The same entries by what stays when a provider renews its links (`identityKey`).
    @ObservationIgnored private var indexByIdentity: [String: Int] = [:]
    @ObservationIgnored private var indexByID: [UUID: Int] = [:]
    @ObservationIgnored private var progressObjects: [UUID: DownloadProgress] = [:]
    /// Downloads whose transfer is being started (probe, HLS loading), so the queue does not start them twice.
    @ObservationIgnored private var starting: Set<UUID> = []
    /// File transfers being stopped (their resume data is on its way): they start again only once it is kept.
    @ObservationIgnored private var stopping: Set<UUID> = []
    @ObservationIgnored private var convertingID: UUID?
    @ObservationIgnored private var isStarted = false
    /// The transfers that survived a relaunch were matched with their records: the queue may start transfers.
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Downloads queued again after a network error: the queue starts them no earlier than this (5, 20, 80 s).
    @ObservationIgnored private var retryNotBefore: [UUID: Date] = [:]
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
        records = Self.readManifest(in: self.directory)
    }

    /// Restores the transfers that ran before the app was relaunched, checks the files and starts the queue. Once.
    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
        NetworkMonitor.shared.addObserver { [weak self] online in
            if online {
                self?.networkDidReturn()
            }
        }
        verifyCompletedFiles()
        let needsTransport = records.contains { $0.status.isPending && $0.status != .failed }
        Task {
            let restored = needsTransport ? await transport.restoreTasks() : [:]
            reconcile(restored: restored)
            isReady = true
            if DownloadPreferences.deletesWatched {
                deleteWatched(onlyIfIdle: true)
            }
            pump()
        }
    }

    // MARK: - Queries

    func canDownload(_ item: ChannelItem) -> Bool {
        guard item.kind != .live, let scheme = item.url?.scheme?.lowercased() else {
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

    var watchedCount: Int {
        records.count(where: { $0.status == .completed && $0.watchedOn != nil })
    }

    /// Space the downloads take (what is downloaded so far for the others).
    var totalBytes: Int64 {
        records.reduce(0) { $0 + ($1.status == .completed ? $1.bytesOnDisk : $1.bytesWritten) }
    }

    /// Free space on the device for downloads.
    var availableBytes: Int64? {
        Self.availableCapacity(at: directory)
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
            $0.failure = nil
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
                $0.failure = nil
                $0.automaticRetries = 0
            }
        }
        pump()
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

    /// Starts queued downloads while transfer slots are free, and the next conversion.
    private func pump() {
        // Not before the restored transfers are matched: a record could be started twice.
        guard isReady else {
            return
        }
        if convertingID == nil, let next = records.first(where: { $0.status == .converting }) {
            convert(next.id)
        }
        guard NetworkMonitor.shared.isOnline else {
            // Transfers wait; they start when the network returns.
            return
        }
        var running = records.count(where: { ($0.status == .downloading || $0.status == .preparing) })
        let now = Date.now
        for record in records where record.status == .queued && !stopping.contains(record.id) {
            if let notBefore = retryNotBefore[record.id], notBefore > now {
                // Waiting for its automatic retry: the queue goes on with the next ones meanwhile.
                continue
            }
            guard running < DownloadPreferences.maximumConcurrentTransfers else {
                break
            }
            running += 1
            begin(record.id)
        }
    }

    /// Probes the link if needed, checks the space and starts the transfer.
    private func begin(_ id: UUID) {
        guard !starting.contains(id) else {
            return
        }
        starting.insert(id)
        retryNotBefore[id] = nil
        update(id) { $0.status = .preparing }
        Task {
            defer {
                starting.remove(id)
            }
            do {
                try await startTransfer(id)
            } catch {
                guard record(id: id)?.status == .preparing else {
                    return
                }
                // The probe and the HLS loading wrap their errors: a timeout or a dropped connection there is
                // retried like one during the transfer.
                let failure = DownloadTransport.failure(from: error)
                fail(id, failure, isNetworkError: failure.isNetworkError || DownloadTransport.isNetworkError(error))
            }
        }
    }

    private func startTransfer(_ id: UUID) async throws {
        guard var record = record(id: id) else {
            return
        }
        let allowsCellular = DownloadPreferences.allowsCellular

        // A suspended HLS task (paused in this run, or restored after a relaunch) continues as it is, unless it
        // runs in the session of the other Cellular Data setting: then it starts again from its partial package.
        if record.method == .hls, transport.hasTask(id: id) {
            if transport.sessionKind(of: id)?.allowsCellular == allowsCellular, transport.resume(id: id) {
                update(id) { $0.status = .downloading }
                return
            }
            transport.cancel(id: id)
        }

        if record.method == nil || (record.method != .hls && record.transferFileName == nil) {
            let probe: DownloadProbe
            do {
                probe = try await DownloadProbe.probe(record.item.url)
            } catch let failure as DownloadFailure where failure.isExpiredLink {
                if let renewed = await renewedItem(for: record), renewed.url != record.item.url {
                    update(id) { $0.item = renewed }
                    record.item = renewed
                    probe = try await DownloadProbe.probe(renewed.url)
                } else {
                    throw failure
                }
            }
            if probe.kind == .remux("bin") {
                Self.logger.info("Unrecognized content; it will be converted")
            }
            if let expected = probe.expectedBytes, let available = Self.availableCapacity(at: directory) {
                // A converted file needs room for the original and the MP4 until the original is deleted.
                let needed = expected * (probe.method == .remux ? 2 : 1) + DownloadPreferences.freeSpaceMargin
                if needed > available {
                    throw DownloadFailure.insufficientSpace
                }
            }
            update(id) {
                $0.method = probe.method
                $0.transferFileName = probe.transferFileName
                $0.bytesExpected = probe.expectedBytes
            }
            record = self.record(id: id) ?? record
        }
        guard self.record(id: id)?.status == .preparing else {
            return
        }

        if record.artworkFileName == nil, let name = await saveArtwork(for: record) {
            update(id) { $0.artworkFileName = name }
        }
        guard self.record(id: id)?.status == .preparing, let method = record.method else {
            return
        }

        switch method {
        case .hls:
            let partial = record.location.map(Self.homeURL(forRelativePath:))
            let plan = try await transport.startHLS(
                id: id,
                url: record.item.url,
                partialLocation: partial,
                title: TextParts.line([record.title, record.episodeLine]),
                artwork: artworkData(for: record),
                quality: DownloadPreferences.quality,
                allowsCellular: allowsCellular,
                availableBytes: Self.availableCapacity(at: directory)
            )
            guard self.record(id: id)?.status == .preparing else {
                // Paused or deleted while the stream was loading.
                if self.record(id: id)?.status == .paused {
                    transport.suspend(id: id)
                } else {
                    transport.cancel(id: id)
                }
                return
            }
            update(id) {
                $0.status = .downloading
                $0.allowsCellular = allowsCellular
                $0.qualityLabel = plan.qualityLabel ?? $0.qualityLabel
                $0.bytesExpected = plan.expectedBytes ?? $0.bytesExpected
                $0.duration = plan.duration ?? $0.duration
                $0.audioNames = plan.audioNames
                $0.subtitleNames = plan.subtitleNames
            }
            progress(for: self.record(id: id) ?? record).bytesExpected = plan.expectedBytes
        case .file, .remux:
            guard let fileName = record.transferFileName else {
                throw DownloadFailure.notVideo
            }
            let resumeURL = folder(of: id).appendingPathComponent(Self.resumeDataFileName)
            let resumeData = try? Data(contentsOf: resumeURL)
            try? FileManager.default.removeItem(at: resumeURL)
            transport.startFile(id: id, url: record.item.url, fileName: fileName, allowsCellular: allowsCellular, resumeData: resumeData)
            update(id) {
                $0.status = .downloading
                $0.allowsCellular = allowsCellular
            }
        }
    }

    // MARK: - Transfer events

    private func handle(_ event: DownloadTransferEvent) {
        switch event {
        case let .progress(id, written, expected, fraction):
            guard let record = record(id: id) else {
                return
            }
            let progress = progress(for: record)
            let now = CFAbsoluteTimeGetCurrent()
            if let last = progress.lastSample, now > last.time, written >= last.bytes, written > 0 {
                let speed = Double(written - last.bytes) / (now - last.time)
                progress.bytesPerSecond = progress.bytesPerSecond.map { $0 * 0.7 + speed * 0.3 } ?? speed
            }
            progress.lastSample = (now, written)
            progress.fraction = fraction
            if record.method == .hls {
                // Asset tasks count units, not bytes: estimate from the expected size.
                if let expected = record.bytesExpected {
                    progress.bytesWritten = Int64(Double(expected) * fraction)
                }
            } else {
                progress.bytesWritten = written
                if let expected {
                    progress.bytesExpected = expected
                }
            }
        case let .hlsLocation(id, url):
            // The first location reported wins (`willDownloadTo`; the asset's URL at completion is a fallback).
            update(id) {
                if $0.location == nil || $0.status != .downloading {
                    $0.location = Self.relativePathFromHome(url)
                }
            }
        case let .fileReceived(id, fileName):
            update(id) { $0.transferFileName = fileName }
        case let .finished(id, failure):
            transferDidFinish(id, failure: failure)
        }
    }

    private func transferDidFinish(_ id: UUID, failure: DownloadTransferFailure?) {
        guard let record = record(id: id) else {
            return
        }
        Self.logger.info("Transfer finished (\(record.status.rawValue, privacy: .public)): \(failure.map { String(describing: $0) } ?? "success", privacy: .public)")
        switch failure {
        case .cancelled:
            // Pause, Delete, or a move to the other session: whoever cancelled already updated the record.
            return
        case .failed(let failure, let isNetworkError):
            guard record.status == .downloading else {
                return
            }
            fail(id, failure, isNetworkError: isNetworkError)
        case nil:
            guard record.status == .downloading || record.status == .paused else {
                return
            }
            switch record.method {
            case .hls:
                completeHLS(id)
            case .file:
                completeFile(id)
            case .remux:
                update(id) {
                    $0.status = .converting
                    $0.fraction = 1
                }
                pump()
            case nil:
                fail(id, .incomplete, isNetworkError: false)
            }
        }
        pump()
    }

    private func completeHLS(_ id: UUID) {
        guard let record = record(id: id), let relative = record.location else {
            Self.logger.error("HLS download finished without a location")
            fail(id, .incomplete, isNetworkError: false)
            return
        }
        let url = Self.homeURL(forRelativePath: relative)
        let asset = AVURLAsset(url: url)
        guard asset.assetCache?.isPlayableOffline ?? FileManager.default.fileExists(atPath: url.path) else {
            Self.logger.error("HLS download not playable offline at \(url.path, privacy: .public)")
            fail(id, .incomplete, isNetworkError: false)
            return
        }
        // Kept before downloads the system may purge first under storage pressure.
        let policy = AVMutableAssetDownloadStorageManagementPolicy()
        policy.priority = .important
        policy.expirationDate = .distantFuture
        AVAssetDownloadStorageManager.shared().setStorageManagementPolicy(policy, for: url)
        let size = Self.allocatedSize(of: url)
        update(id) {
            $0.status = .completed
            $0.completedOn = .now
            $0.fraction = 1
            $0.bytesOnDisk = size
            $0.isMissing = false
            $0.failure = nil
        }
        didComplete(id)
    }

    private func completeFile(_ id: UUID) {
        guard let record = record(id: id), let name = record.transferFileName else {
            fail(id, .incomplete, isNetworkError: false)
            return
        }
        let url = folder(of: id).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail(id, .incomplete, isNetworkError: false)
            return
        }
        try? FileManager.default.removeItem(at: folder(of: id).appendingPathComponent(Self.resumeDataFileName))
        let size = Self.allocatedSize(of: url)
        update(id) {
            $0.status = .completed
            $0.completedOn = .now
            $0.fraction = 1
            $0.location = name
            $0.bytesOnDisk = size
            $0.isMissing = false
            $0.failure = nil
        }
        loadDuration(of: id, url: url)
        didComplete(id)
    }

    private func didComplete(_ id: UUID) {
        progressObjects[id] = nil
        if let record = record(id: id) {
            AccessibilityAnnouncer.announce(String(localized: "\(TextParts.line([record.title, record.episodeLine])) downloaded", comment: "VoiceOver announcement: a download finished; the placeholder is the movie or episode."))
        }
    }

    private func fail(_ id: UUID, _ failure: DownloadFailure, isNetworkError: Bool) {
        guard let record = record(id: id) else {
            return
        }
        if isNetworkError, record.automaticRetries < Self.maximumAutomaticRetries {
            update(id) {
                $0.status = .queued
                $0.automaticRetries += 1
            }
            retryNotBefore[id] = .now.addingTimeInterval(Double(5 << min(4, record.automaticRetries * 2)))
            scheduleRetry()
            return
        }
        Self.logger.error("Download failed: \(failure.message, privacy: .public)")
        if record.status == .preparing, !isNetworkError {
            // It could not even start (no space, not a video, refused): said at once, not only in the list.
            let name = TextParts.line([record.title, record.episodeLine])
            notice = DownloadNotice(
                title: String(localized: "Can't Download “\(name)”", comment: "Title of the alert when a download cannot start; the placeholder is the movie or episode."),
                message: failure.message
            )
        }
        update(id) {
            $0.status = .failed
            $0.failure = failure.message
            $0.failureIsPermanent = failure.isPermanent
        }
        if failure.isPermanent || record.method == nil {
            // Nothing worth keeping (the probe failed, or the format cannot be played).
            removeFolderContents(of: id, keepingArtwork: true)
        }
        pump()
    }

    /// Runs the queue again when the earliest waiting retry is due.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = nil
        let now = Date.now
        retryNotBefore = retryNotBefore.filter { $0.value > now && record(id: $0.key)?.status == .queued }
        guard let due = retryNotBefore.values.min() else {
            return
        }
        retryTask = Task {
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else {
                return
            }
            pump()
            scheduleRetry()
        }
    }

    private func networkDidReturn() {
        // Network failures count again from zero once the network is back, and wait no longer.
        retryNotBefore.removeAll()
        retryTask?.cancel()
        retryTask = nil
        for record in records where record.status == .failed && !record.failureIsPermanent && record.automaticRetries > 0 && record.automaticRetries <= Self.maximumAutomaticRetries {
            update(record.id) {
                $0.status = .queued
                $0.failure = nil
                $0.automaticRetries = 0
            }
        }
        pump()
    }

    // MARK: - Conversion

    /// Copies a downloaded original into MP4 (stream copy), then deletes the original.
    private func convert(_ id: UUID) {
        guard convertingID == nil, let record = record(id: id), let sourceName = record.transferFileName else {
            if let record = record(id: id), record.transferFileName == nil {
                fail(id, .incomplete, isNetworkError: false)
            }
            return
        }
        let folder = folder(of: id)
        let source = folder.appendingPathComponent(sourceName)
        let destination = folder.appendingPathComponent("media.mp4")
        guard FileManager.default.fileExists(atPath: source.path) else {
            fail(id, .incomplete, isNetworkError: false)
            return
        }
        convertingID = id
        #if canImport(UIKit)
        // A few more seconds to finish if the app goes to the background meanwhile. When they run out, the
        // background task ends at once (the system terminates an app that keeps it past its time): the conversion
        // is then suspended with the app and continues when it comes back. If the app is terminated meanwhile,
        // the record is still Converting and the conversion starts again at the next launch.
        let backgroundTask = BackgroundActivity(name: "Convert download")
        #endif
        Task {
            let result = await Task.detached(priority: .utility) {
                DownloadConversion.convert(source, to: destination)
            }.value
            #if canImport(UIKit)
            backgroundTask.end()
            #endif
            convertingID = nil
            guard self.record(id: id)?.status == .converting else {
                // Deleted meanwhile: the result goes, and the next conversion may start.
                try? FileManager.default.removeItem(at: destination)
                pump()
                return
            }
            switch result {
            case .success(let duration):
                try? FileManager.default.removeItem(at: source)
                let size = Self.allocatedSize(of: destination)
                update(id) {
                    $0.status = .completed
                    $0.completedOn = .now
                    $0.location = destination.lastPathComponent
                    $0.transferFileName = destination.lastPathComponent
                    $0.bytesOnDisk = size
                    $0.duration = duration > 0 ? duration : $0.duration
                    $0.failure = nil
                    $0.isMissing = false
                }
                didComplete(id)
            case .failure(let failure):
                try? FileManager.default.removeItem(at: source)
                fail(id, failure, isNetworkError: false)
            }
            pump()
        }
    }

    // MARK: - Launch

    /// Matches the records with the transfers that survived the relaunch.
    private func reconcile(restored: [UUID: DownloadTransport.SessionKind]) {
        for record in records where !starting.contains(record.id) {
            let id = record.id
            switch record.status {
            case .preparing:
                update(id) { $0.status = .queued }
            case .downloading:
                if restored[id] == nil {
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
        // Transfers of downloads that no longer exist.
        for id in restored.keys where record(id: id) == nil {
            transport.cancel(id: id)
        }
    }

    /// Completed downloads whose media is gone (the system purged an HLS package, a file was removed) are marked
    /// missing; their sizes are refreshed.
    private func verifyCompletedFiles() {
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

    private func markMissing(_ id: UUID) {
        update(id) { $0.isMissing = true }
    }

    /// Downloads a missing download again.
    private func redownload(_ id: UUID) {
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
            $0.failure = nil
            $0.automaticRetries = 0
        }
        pump()
    }

    // MARK: - Files

    private func folder(of id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func mediaURL(of record: DownloadRecord) -> URL? {
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

    private func removeMedia(of record: DownloadRecord, keepingArtwork: Bool = false) {
        if record.method == .hls, let location = record.location {
            try? FileManager.default.removeItem(at: Self.homeURL(forRelativePath: location))
        }
        if keepingArtwork {
            removeFolderContents(of: record.id, keepingArtwork: true)
        } else {
            try? FileManager.default.removeItem(at: folder(of: record.id))
        }
    }

    private func removeFolderContents(of id: UUID, keepingArtwork: Bool) {
        let artwork = record(id: id)?.artworkFileName
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder(of: id), includingPropertiesForKeys: nil)) ?? []
        for url in contents where !(keepingArtwork && url.lastPathComponent == artwork) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Keeps a copy of the entry's artwork with the download, so it shows offline.
    private func saveArtwork(for record: DownloadRecord) async -> String? {
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

    private func artworkData(for record: DownloadRecord) async -> Data? {
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
    private func renewedItem(for record: DownloadRecord) async -> DownloadedItem? {
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

    private func loadDuration(of id: UUID, url: URL) {
        Task {
            guard let duration = try? await AVURLAsset(url: url).load(.duration).seconds, duration.isFinite, duration > 0 else {
                return
            }
            update(id) { $0.duration = duration }
        }
    }

    // MARK: - Records

    private func update(_ id: UUID, _ change: (inout DownloadRecord) -> Void) {
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
        let url = directory.appendingPathComponent(Self.manifestFileName)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Could not save the downloads: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func readManifest(in directory: URL) -> [DownloadRecord] {
        let url = directory.appendingPathComponent(manifestFileName)
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([DownloadRecord].self, from: data)
        } catch {
            logger.error("Could not read the downloads: \(error.localizedDescription, privacy: .public)")
            return []
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

    nonisolated static func availableCapacity(at url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : FileManager.default.temporaryDirectory
        guard let capacity = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
              capacity > 0 else {
            return nil
        }
        return capacity
    }
}

#if canImport(UIKit)
/// A UIKit background task that ends exactly once: when the work is done, or when its time runs out.
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        // The expiration handler runs on the main thread; it keeps the activity alive until it has ended.
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            DownloadCenter.logger.info("Background time ran out: \(name, privacy: .public) continues in the foreground")
            end()
        }
    }

    func end() {
        guard identifier != .invalid else {
            return
        }
        let ending = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(ending)
    }
}
#endif

/// Copies a downloaded file into MP4 with the remux engine (no re-encoding).
enum DownloadConversion {
    nonisolated static func convert(_ source: URL, to destination: URL) -> Result<TimeInterval, DownloadFailure> {
        // Written under a hidden name and renamed when complete, so a partial MP4 is never taken for a finished one.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".converting.mp4")
        try? FileManager.default.removeItem(at: temporary)
        var duration: Double = 0
        var buffer = [CChar](repeating: 0, count: 512)
        let result = source.path.withCString { sourcePointer in
            temporary.path.withCString { destinationPointer in
                buffer.withUnsafeMutableBufferPointer { pointer in
                    fluxo_remux_convert_file(sourcePointer, destinationPointer, &duration, pointer.baseAddress, Int32(pointer.count))
                }
            }
        }
        guard result == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            let message = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let failure = DownloadFailure.unsupportedFormat
            return .failure(message.isEmpty ? failure : DownloadFailure(message: "\(failure.message) (\(EngineMessage.localized(message)))", isPermanent: true))
        }
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return .failure(DownloadFailure(message: error.localizedDescription))
        }
        return .success(duration)
    }
}
