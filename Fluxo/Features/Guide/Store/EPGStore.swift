//
//  EPGStore.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import Observation
import os
import SwiftData

/// Main-actor front end of the TV guide: sources, refreshes, matching overrides and the query API the screens
/// (and other features) use.
///
/// - Sources: every `url-tvg` / `x-tvg-url` of a playlist header becomes an `EPGSource` after its import; users
///   can add XMLTV URLs in Settings.
/// - Refresh policy: at launch for sources older than `staleInterval`, hourly while the app runs, from a
///   background app refresh task on iOS, after a playlist import that lists a new guide, and on demand.
///   Refreshes run one at a time, in the background (`EPGImporter`).
/// - Queries (`nowNext(for:)`, `programmes(for:in:)`, `guideChannels(importIDs:)`, `searchProgrammes`) are
///   answered by `EPGReader` off the main actor and return value types.
///
/// `revision` changes whenever guide data or matching changes; views use it as a task identifier to reload.
@MainActor
@Observable
final class EPGStore {

    /// A guide is downloaded again when it is older than this.
    static let staleInterval: TimeInterval = 12 * 3_600

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "EPGStore")

    struct Failure: Identifiable {
        enum Kind {
            case refresh
            case deletion
        }

        let id = UUID()
        var kind = Kind.refresh
        let sourceName: String
        let message: String

        /// The title of the alert that shows it.
        var title: LocalizedStringResource {
            switch kind {
            case .refresh:
                "Could Not Load the TV Guide"
            case .deletion:
                LocalizedStringResource("Could Not Delete the Guide Source", comment: "Title of the alert shown when deleting a TV guide source failed.")
            }
        }
    }

    /// Bumped when guide data, sources or matching change.
    private(set) var revision = 0
    /// Whether at least one enabled source has a stored guide.
    private(set) var hasGuide = false
    /// False until the matcher was loaded once (screens show a spinner instead of "no guide" meanwhile).
    private(set) var isReady = false
    /// Progress of the refresh running for each source.
    private(set) var progress: [UUID: EPGRefreshProgress] = [:]
    /// Last refresh (or deletion) error, for the UI to present. Background refreshes do not set it.
    var failure: Failure?
    /// Sources being deleted. They are left out of every list at once (`visibleSources(_:)`), while the store
    /// removes them in the background.
    private(set) var deletingSourceIDs: Set<UUID> = []

    /// Channel whose guide matching the user is editing (presents `GuideChannelPicker`).
    var matchingTarget: ChannelItem?

    let reminders: ReminderCenter

    @ObservationIgnored
    private let container: ModelContainer
    @ObservationIgnored
    private let importer: EPGImporter
    @ObservationIgnored
    private let reader: EPGReader
    @ObservationIgnored
    private var refreshQueue: [UUID] = []
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    /// The refresh running now, so one source can be cancelled without stopping the queue.
    @ObservationIgnored
    private var currentRefresh: (sourceID: UUID, task: Task<EPGRefreshSummary, Error>)?
    @ObservationIgnored
    private var reportsFailures: Set<UUID> = []
    /// Sources asked for again while their refresh ran: it may have read the playlist channels before they
    /// changed, so they run once more.
    @ObservationIgnored
    private var pendingReruns: Set<UUID> = []
    @ObservationIgnored
    private var didStart = false
    @ObservationIgnored
    private var periodicTask: Task<Void, Never>?

    init(container: ModelContainer, reminders: ReminderCenter? = nil) {
        self.container = container
        importer = EPGImporter(container: container)
        reader = EPGReader(container: container)
        self.reminders = reminders ?? ReminderCenter(container: container)
    }

    var isRefreshing: Bool {
        !progress.isEmpty || !refreshQueue.isEmpty
    }

    // MARK: - Lifecycle

    /// Launch work: removes leftovers, prunes ended programmes, syncs the sources of every playlist, loads the
    /// matcher, then refreshes stale guides after a short delay (so launch and the first playback are not slowed
    /// down). Runs once.
    func start(refreshingStaleSources: Bool = true) {
        guard !didStart else {
            return
        }
        didStart = true
        reminders.start()
        Task { [weak self, importer] in
            // Independent steps: one failing does not stop the others.
            do {
                try await importer.purgeOrphanedContent()
            } catch {
                Self.logger.error("Guide cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
            do {
                try await importer.prune()
                try await importer.syncAllSources()
            } catch {
                Self.logger.error("Guide maintenance failed: \(error.localizedDescription, privacy: .public)")
            }
            await self?.reloadMatching()
            guard refreshingStaleSources else {
                return
            }
            try? await Task.sleep(for: .seconds(4))
            // Playlists imported before the guide existed: read their header once.
            await importer.discoverHeaderGuides()
            if (try? await importer.syncAllSources())?.isEmpty == false {
                await self?.reloadMatching()
            }
            self?.refreshStaleSources()
            self?.startPeriodicRefresh()
        }
    }

    /// Hourly check while the app runs (guides are refreshed when they are older than `staleInterval`).
    private func startPeriodicRefresh() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
                guard !Task.isCancelled else {
                    return
                }
                try? await self?.importer.prune()
                self?.refreshStaleSources()
            }
        }
    }

    /// Background app refresh (iOS): refreshes the stale guides within the time the system grants. Cancellation
    /// of the calling task (the system expiring it) cancels the download.
    func performBackgroundRefresh() async {
        start(refreshingStaleSources: false)
        let stale = staleSourceIDs()
        guard !stale.isEmpty else {
            return
        }
        await withTaskCancellationHandler {
            enqueue(stale, reportingFailures: false)
            await refreshTask?.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRefreshes()
            }
        }
    }

    // MARK: - Playlist events

    /// A playlist import finished: its header may list new or different guides, and its channels changed.
    func playlistDidImport(_ playlistID: UUID) {
        Task { [weak self, importer] in
            do {
                let added = try await importer.syncSources(ofPlaylist: playlistID)
                await self?.reloadMatching()
                // New guides load now. The guides already loaded for this playlist (its own and the ones the user
                // added) only kept the programmes of the channels wanted then: read them again when the wanted
                // channels changed, so new channels get their programmes now rather than at the next refresh.
                let rematch = try await importer.sourcesNeedingRematch(forPlaylist: playlistID)
                guard let self else {
                    return
                }
                self.enqueue(added + rematch, reportingFailures: false)
            } catch {
                Self.logger.error("Could not sync the guides of a playlist: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A playlist was deleted: its guides go too.
    func playlistWasDeleted(_ playlistID: UUID) {
        Task { [weak self, importer] in
            _ = try? await importer.syncSources(ofPlaylist: playlistID)
            try? await importer.purgeOrphanedContent()
            await self?.reloadMatching()
        }
    }

    // MARK: - Sources

    func addSource(url: URL, name: String?) async throws {
        let sourceID = try await importer.addSource(url: url, name: name)
        bumpRevision()
        enqueue([sourceID], reportingFailures: true)
    }

    /// Deletes a guide source with its programmes, channels and manual matches. Reminders are snapshots and stay.
    ///
    /// The source disappears from the lists right away (`deletingSourceIDs`; call it inside `withAnimation` to
    /// animate its row out). A refresh of the source is cancelled and awaited first, so that it writes no rows
    /// once they are deleted. Then the source row goes (the guide stops showing it), then its programmes, off the
    /// main actor and in chunks (`EPGImporter.deleteRows(of:)`).
    func deleteSource(_ sourceID: UUID) {
        guard deletingSourceIDs.insert(sourceID).inserted else {
            return
        }
        let runningRefresh = cancelRefresh(of: sourceID)
        let name = sourceName(sourceID)
        Task { [weak self, importer] in
            _ = try? await runningRefresh?.value
            let removed: EPGImporter.RemovedSource
            do {
                removed = try await importer.removeSource(sourceID)
            } catch {
                Self.logger.error("Could not delete a guide source: \(error.localizedDescription, privacy: .public)")
                self?.deletingSourceIDs.remove(sourceID)
                self?.failure = Failure(kind: .deletion, sourceName: name, message: error.localizedDescription)
                return
            }
            await self?.reloadMatching()
            do {
                try await importer.deleteRows(of: [removed])
            } catch {
                // The source is gone; its leftover rows are orphans, removed at the next launch.
                Self.logger.error("Could not delete the programmes of a guide source: \(error.localizedDescription, privacy: .public)")
            }
            self?.deletingSourceIDs.remove(sourceID)
        }
    }

    /// `sources` without the ones being deleted.
    func visibleSources(_ sources: [EPGSource]) -> [EPGSource] {
        deletingSourceIDs.isEmpty ? sources : sources.filter { !deletingSourceIDs.contains($0.uuid) }
    }

    func setEnabled(_ isEnabled: Bool, sourceID: UUID) {
        Task { [weak self, importer] in
            try? await importer.setEnabled(isEnabled, sourceID: sourceID)
            await self?.reloadMatching()
            if isEnabled {
                self?.refreshIfNeeded(sourceID)
            }
        }
    }

    // MARK: - Refresh

    /// Refreshes every enabled source now.
    func refreshAll() {
        enqueue(enabledSourceIDs(), reportingFailures: true)
    }

    func refresh(_ sourceID: UUID) {
        enqueue([sourceID], reportingFailures: true)
    }

    func refreshStaleSources() {
        enqueue(staleSourceIDs(), reportingFailures: false)
    }

    func cancelRefreshes() {
        refreshQueue.removeAll()
        pendingReruns.removeAll()
        currentRefresh?.task.cancel()
    }

    private func refreshIfNeeded(_ sourceID: UUID) {
        if staleSourceIDs().contains(sourceID) {
            enqueue([sourceID], reportingFailures: false)
        }
    }

    /// Cancels the refresh of a source, queued or running. Returns the running one, to await its end.
    @discardableResult
    private func cancelRefresh(of sourceID: UUID) -> Task<EPGRefreshSummary, Error>? {
        refreshQueue.removeAll { $0 == sourceID }
        pendingReruns.remove(sourceID)
        reportsFailures.remove(sourceID)
        guard let currentRefresh, currentRefresh.sourceID == sourceID else {
            return nil
        }
        currentRefresh.task.cancel()
        return currentRefresh.task
    }

    private func enqueue(_ sourceIDs: [UUID], reportingFailures: Bool) {
        for sourceID in sourceIDs where !refreshQueue.contains(sourceID) && !deletingSourceIDs.contains(sourceID) {
            guard progress[sourceID] == nil else {
                pendingReruns.insert(sourceID)
                continue
            }
            refreshQueue.append(sourceID)
            if reportingFailures {
                reportsFailures.insert(sourceID)
            }
        }
        guard refreshTask == nil, !refreshQueue.isEmpty else {
            return
        }
        refreshTask = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        defer {
            refreshTask = nil
        }
        while !refreshQueue.isEmpty {
            let sourceID = refreshQueue.removeFirst()
            progress[sourceID] = .connecting
            let importer = importer
            let task = Task { [weak self] in
                try await importer.refresh(sourceID: sourceID) { update in
                    Task { @MainActor in
                        // Ignore late updates of a refresh that already finished.
                        if self?.progress[sourceID] != nil {
                            self?.progress[sourceID] = update
                        }
                    }
                }
            }
            currentRefresh = (sourceID, task)
            do {
                _ = try await task.value
                await reloadMatching()
            } catch is CancellationError {
                // Stopped by the user, the source was deleted, or the background task expired.
            } catch {
                if reportsFailures.contains(sourceID) {
                    failure = Failure(sourceName: sourceName(sourceID), message: error.localizedDescription)
                }
                bumpRevision()
            }
            currentRefresh = nil
            reportsFailures.remove(sourceID)
            progress[sourceID] = nil
            if pendingReruns.remove(sourceID) != nil, !deletingSourceIDs.contains(sourceID) {
                // Usually quick: a 304 or an identical file for unchanged channels is not read again.
                refreshQueue.append(sourceID)
            }
        }
    }

    private func enabledSourceIDs() -> [UUID] {
        ((try? container.mainContext.fetch(EPGQueries.sources())) ?? []).filter(\.isEnabled).map(\.uuid)
    }

    private func staleSourceIDs(now: Date = .now) -> [UUID] {
        let sources = (try? container.mainContext.fetch(EPGQueries.sources())) ?? []
        return sources.filter { source in
            guard source.isEnabled else {
                return false
            }
            guard let refreshed = source.lastRefreshedOn else {
                // Never loaded: retry failed first loads at most every hour.
                return source.lastAttemptOn.map { now.timeIntervalSince($0) > 3_600 } ?? true
            }
            if let attempt = source.lastAttemptOn, attempt > refreshed, now.timeIntervalSince(attempt) < 3_600 {
                return false
            }
            return now.timeIntervalSince(refreshed) > Self.staleInterval
        }
        .map(\.uuid)
    }

    private func sourceName(_ sourceID: UUID) -> String {
        ((try? container.mainContext.fetch(EPGQueries.source(uuid: sourceID)))?.first?.name) ?? String(localized: "TV Guide", comment: "Name of a TV guide source that has no name.")
    }

    // MARK: - Matching

    /// Sets the guide channel of a playlist channel: a guide channel, nil for "no guide", or `automatic` to go
    /// back to automatic matching. Choosing a channel whose programmes were not stored refreshes its source.
    func setMatch(_ choice: GuideChannelChoice?, automatic: Bool = false, for item: ChannelItem) {
        guard let key = item.bookmarkKey else {
            return
        }
        let context = container.mainContext
        let existing = try? context.fetch(EPGQueries.override(key: key)).first
        if automatic {
            if let existing {
                context.delete(existing)
            }
        } else if let existing {
            existing.sourceID = choice?.ref.sourceID
            existing.channelID = choice?.ref.channelID ?? ""
            existing.updatedOn = .now
        } else {
            context.insert(EPGChannelOverride(key: key, playlistID: item.playlistID, sourceID: choice?.ref.sourceID, channelID: choice?.ref.channelID ?? ""))
        }
        do {
            try context.save()
        } catch {
            Self.logger.error("Could not save the guide match: \(error.localizedDescription, privacy: .public)")
        }
        Task {
            await reloadMatching()
            if let choice, !choice.hasProgrammes {
                enqueue([choice.ref.sourceID], reportingFailures: true)
            }
        }
    }

    /// Whether the user picked the guide channel of `item` by hand.
    func hasManualMatch(for item: ChannelItem) -> Bool {
        guard let key = item.bookmarkKey else {
            return false
        }
        return ((try? container.mainContext.fetchCount(EPGQueries.override(key: key))) ?? 0) > 0
    }

    /// Reloads the matcher from the store (previews and the debug demo, which do not call `start()`).
    func reloadGuide() {
        Task {
            await reloadMatching()
        }
    }

    private func reloadMatching() async {
        hasGuide = await reader.reload()
        isReady = true
        bumpRevision()
    }

    private func bumpRevision() {
        revision &+= 1
    }

    // MARK: - Queries

    /// What the channel shows now and next; nil when it has no guide.
    func nowNext(for item: ChannelItem, at date: Date = .now) async -> NowNext? {
        guard hasGuide, item.kind == .live else {
            return nil
        }
        return await reader.nowNext(for: item, at: date)
    }

    func guideRef(for item: ChannelItem) async -> GuideChannelRef? {
        guard hasGuide else {
            return nil
        }
        return await reader.ref(for: item)
    }

    func automaticRef(for item: ChannelItem) async -> GuideChannelRef? {
        await reader.automaticRef(for: item)
    }

    func programmes(for ref: GuideChannelRef, in interval: DateInterval) async -> [GuideProgramme] {
        await reader.programmes(for: ref, in: interval)
    }

    func upcoming(for ref: GuideChannelRef, from date: Date = .now, limit: Int = 6) async -> [GuideProgramme] {
        await reader.upcoming(for: ref, from: date, limit: limit)
    }

    /// The live channels of the given playlist imports that have a guide, in playlist order.
    func guideChannels(importIDs: [UUID]) async -> [GuideChannel] {
        guard hasGuide else {
            return []
        }
        return await reader.guideChannels(importIDs: importIDs)
    }

    /// Programmes that have not ended whose title, subtitle or description contains `term`, soonest first.
    func searchProgrammes(_ term: String, importIDs: [UUID], limit: Int = 150) async -> [GuideSearchResult] {
        guard hasGuide else {
            return []
        }
        return await reader.search(term: term, importIDs: importIDs, now: .now, limit: limit)
    }

    /// Programmes that overlap `interval` with a category containing `term` ("film"), soonest first.
    func searchProgrammes(inCategory term: String, importIDs: [UUID], overlapping interval: DateInterval, limit: Int = 60) async -> [GuideSearchResult] {
        guard hasGuide else {
            return []
        }
        return await reader.search(category: term, importIDs: importIDs, overlapping: interval, limit: limit)
    }

    func channelChoices(term: String) async -> [GuideChannelChoice] {
        await reader.channelChoices(term: term)
    }

    func choice(for ref: GuideChannelRef) async -> GuideChannelChoice? {
        await reader.choice(for: ref)
    }
}
