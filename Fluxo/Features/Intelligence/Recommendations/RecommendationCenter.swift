//
//  RecommendationCenter.swift
//  Fluxo
//
//  Runs and caches the recommendations: "For You" (channels, Home) and "For You Tonight" (programmes, Guide).
//  Neither suggests adult content while Settings › Recommendations › "Hide adult content from recommendations" is on,
//  unless the playlists have nothing else (`MatureContentFilter`), nor the same title twice.
//
//  A request first publishes the built-in ranking (fast, no model), then, when Apple Intelligence is available,
//  replaces it with the model's picks. Results are cached per scope and taste fingerprint (the channels that weigh
//  most, the favorites and the categories watched most, a three-hour slot of the day, whether a guide is loaded): Home
//  and the Guide show the cached list at once and the model only runs again when one of these changes. The model's
//  channel picks are also kept in the app's defaults, so a relaunch does not run it again.
//
//  The model is a few seconds of work on the device, so it runs only when it is worth it:
//  - one run at a time, after a short pause (`modelDelay`): switching playlists quickly runs it for the last one only;
//  - not on its own in Low Power Mode or while the device is hot (the built-in ranking shows; New Suggestions still
//    asks the model);
//  - after a failure, not again for the same taste until a backoff has passed (`ModelBackoff`, kept across launches);
//    a run cut short (the app went to the background, the scope changed) is not a failure.
//

import Foundation
import Observation
import os
import SwiftData

@MainActor
@Observable
final class RecommendationCenter {

    typealias ChannelList = RecommendationList<ChannelRecommendation>
    typealias ProgrammeList = RecommendationList<ProgrammeRecommendation>

    /// How long the model's picks stay valid when nothing else changes.
    static let personalizedLifetime: TimeInterval = 3 * 3_600
    static let programmeLifetime: TimeInterval = 30 * 60

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Recommendations")
    private static let storedPicksKey = "intelligence.forYou.picks"

    private(set) var channelLists: [RecommendationScope: ChannelList] = [:]
    private(set) var programmeLists: [RecommendationScope: ProgrammeList] = [:]
    /// Scopes whose list the model is working on.
    private(set) var personalizingChannels: Set<RecommendationScope> = []
    private(set) var personalizingProgrammes: Set<RecommendationScope> = []

    @ObservationIgnored
    weak var intelligence: FluxoIntelligence?
    @ObservationIgnored
    private let container: ModelContainer
    @ObservationIgnored
    private let epg: EPGStore
    @ObservationIgnored
    private var channelTasks: [RecommendationScope: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var programmeTasks: [RecommendationScope: Task<Void, Never>] = [:]
    /// The last model run asked for: one at a time, in order (`runModel`).
    @ObservationIgnored
    private var modelTail: Task<Void, Never>?
    /// The scope Home or the Guide asked for last: a model run waiting for another scope is skipped.
    @ObservationIgnored
    private var latestChannelScope: RecommendationScope?
    @ObservationIgnored
    private var latestProgrammeScope: RecommendationScope?
    @ObservationIgnored
    private var backoff = ModelBackoff(defaultsKey: "intelligence.forYou.failures")

    /// The pause before the model runs, so requests in quick succession run it once.
    static let modelDelay: Duration = .milliseconds(1_500)

    init(container: ModelContainer, epg: EPGStore) {
        self.container = container
        self.epg = epg
    }

    private var modelIsAvailable: Bool {
        intelligence?.isAvailable ?? false
    }

    // MARK: - For You (channels)

    /// Loads (or reuses) the "For You" channels of `scope`; returns when the final list is published. `force`
    /// ignores the caches (also after a load that was already running).
    func loadChannels(for scope: RecommendationScope, force: Bool = false) async {
        while let running = channelTasks[scope] {
            await running.value
            // A forced refresh asked during a load runs once more after it, so it is not lost.
            guard force else {
                return
            }
        }
        // The task frees its slot itself, before anyone awaiting it resumes. It is not a child of the caller:
        // Home, the Guide and Siri share one load, so a caller that goes away does not cancel it for the others.
        let task = Task { [weak self] in
            await self?.runChannels(for: scope, force: force)
            self?.channelTasks[scope] = nil
        }
        channelTasks[scope] = task
        await task.value
    }

    /// The suggestions for `scope`, loading them if needed (App Intents).
    func channels(for scope: RecommendationScope) async -> ChannelList? {
        await loadChannels(for: scope)
        return channelLists[scope]
    }

    private func runChannels(for scope: RecommendationScope, force: Bool) async {
        latestChannelScope = scope
        let container = container
        let now = Date.now
        let scopeImportIDs = scope.importIDs
        let (profile, filter) = await Task.detached(priority: .userInitiated) {
            let bookmarks = LibraryLookup.bookmarks(playlistIDs: nil, in: container)
            let profile = TasteProfile(history: bookmarks.history, favorites: bookmarks.favorites, now: now)
            return (profile, MatureContentFilter.forScope(importIDs: scopeImportIDs, container: container))
        }.value
        let useModel = modelIsAvailable
        let fingerprint = [
            scope.importIDs.map(\.uuidString).sorted().joined(separator: ","),
            profile.fingerprint,
            ViewingMoment.bucket(of: now),
            epg.hasGuide ? "guide" : "",
            useModel ? "ai" : "",
            OnDeviceModel.responseLanguageName,
            filter.isActive ? "no-adult" : "",
        ].joined(separator: "#")
        // Whether the model may run for this request (see the top of the file).
        let mayRunModel = useModel && (force || (!PowerMonitor.shared.isConstrained && !backoff.isBackingOff(fingerprint, now: now)))

        if !force, let cached = channelLists[scope], cached.fingerprint == fingerprint, cached.isPersonalized || !mayRunModel {
            return
        }

        let importIDs = scope.importIDs
        var candidates = await Task.detached(priority: .userInitiated) {
            await ChannelRecommender.candidates(profile: profile, importIDs: importIDs, filter: filter, container: container)
        }.value
        await attachProgrammes(to: &candidates)
        let ranked = ChannelRecommender.rank(candidates, profile: profile, limit: ChannelRecommender.promptCandidates)
        let shown = Array(ranked.prefix(ChannelRecommender.listSize))
        let builtIn = zip(shown, ReasonVariety.pick(shown.map(\.reasonOptions))).map { candidate, reason in
            ChannelRecommendation(item: candidate.item, reason: reason, programme: candidate.programme)
        }

        // A personalized list stored by an earlier launch, for the same taste and time slot.
        if !force, useModel, let stored = storedPicks(fingerprint: fingerprint, candidates: candidates, filter: filter) {
            channelLists[scope] = ChannelList(items: stored, isPersonalized: true, fingerprint: fingerprint, createdAt: now)
            return
        }
        let builtInList = ChannelList(items: Array(builtIn), isPersonalized: false, fingerprint: fingerprint, createdAt: now)
        guard mayRunModel, !ranked.isEmpty else {
            // A personalized list of the same scope stays while the model may not run (Low Power Mode, a backoff).
            if !(channelLists[scope]?.isPersonalized ?? false) || force {
                channelLists[scope] = builtInList
            }
            return
        }
        // Keep showing a personalized list while the model works on its replacement.
        if !(channelLists[scope]?.isPersonalized ?? false) {
            channelLists[scope] = builtInList
        }

        personalizingChannels.insert(scope)
        defer {
            personalizingChannels.remove(scope)
        }
        do {
            let picks = try await runModel(isCurrent: { [weak self] in force || self?.latestChannelScope == scope }) {
                try await Task.detached(priority: .userInitiated) {
                    try await ChannelRecommender.personalize(ranked: ranked, profile: profile, importIDs: importIDs, filter: filter, container: container, now: now)
                }.value
            }
            channelLists[scope] = ChannelList(items: picks, isPersonalized: true, fingerprint: fingerprint, createdAt: .now)
            storePicks(picks, fingerprint: fingerprint)
            backoff.succeeded(fingerprint)
        } catch is CancellationError {
            // Skipped or cut short: the built-in list stays, and the next request runs the model.
        } catch {
            Self.logger.error("For You personalization failed: \(String(describing: error), privacy: .public)")
            backoff.failed(fingerprint, now: .now)
            if !(channelLists[scope]?.isPersonalized ?? false) {
                channelLists[scope] = builtInList
            }
        }
    }

    /// Runs the model after `modelDelay`, after any other model run, unless the request is no longer current by then
    /// (another scope was asked for meanwhile): then it throws `CancellationError`.
    private func runModel<T: Sendable>(isCurrent: @escaping @MainActor () -> Bool, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = modelTail
        let run = Task { @MainActor () async throws -> T in
            await previous?.value
            try await Task.sleep(for: Self.modelDelay)
            guard isCurrent() else {
                throw CancellationError()
            }
            return try await work()
        }
        modelTail = Task {
            _ = try? await run.value
        }
        return try await run.value
    }

    /// Adds what the live candidates show now (one cached guide lookup each).
    private func attachProgrammes(to candidates: inout [ChannelCandidate]) async {
        guard epg.hasGuide else {
            return
        }
        for index in candidates.indices where candidates[index].item.kind == .live {
            candidates[index].programme = await epg.nowNext(for: candidates[index].item)?.current
        }
    }

    // MARK: - For You Tonight (programmes)

    func loadProgrammes(for scope: RecommendationScope, force: Bool = false) async {
        while let running = programmeTasks[scope] {
            await running.value
            // A forced refresh asked during a load runs once more after it, so it is not lost.
            guard force else {
                return
            }
        }
        // The task frees its slot itself, before anyone awaiting it resumes (and, as above, outlives its caller).
        let task = Task { [weak self] in
            await self?.runProgrammes(for: scope, force: force)
            self?.programmeTasks[scope] = nil
        }
        programmeTasks[scope] = task
        await task.value
    }

    func programmes(for scope: RecommendationScope) async -> ProgrammeList? {
        await loadProgrammes(for: scope)
        return programmeLists[scope]
    }

    private func runProgrammes(for scope: RecommendationScope, force: Bool) async {
        guard epg.hasGuide else {
            programmeLists[scope] = nil
            return
        }
        latestProgrammeScope = scope
        let container = container
        let now = Date.now
        let scopeImportIDs = scope.importIDs
        let (profile, filter) = await Task.detached(priority: .userInitiated) {
            let bookmarks = LibraryLookup.bookmarks(playlistIDs: nil, in: container)
            let profile = TasteProfile(history: bookmarks.history, favorites: bookmarks.favorites, now: now)
            return (profile, MatureContentFilter.forScope(importIDs: scopeImportIDs, container: container))
        }.value
        let useModel = modelIsAvailable
        let fingerprint = [
            scope.importIDs.map(\.uuidString).sorted().joined(separator: ","),
            profile.fingerprint,
            useModel ? "ai" : "",
            "\(epg.revision)",
            filter.isActive ? "no-adult" : "",
        ].joined(separator: "#")
        let backoffKey = "tonight#" + fingerprint
        let mayRunModel = useModel && (force || (!PowerMonitor.shared.isConstrained && !backoff.isBackingOff(backoffKey, now: now)))
        if !force, let cached = programmeLists[scope], cached.fingerprint == fingerprint,
           now.timeIntervalSince(cached.createdAt) < Self.programmeLifetime, cached.isPersonalized || !mayRunModel {
            return
        }

        let channels = await epg.guideChannels(importIDs: scope.importIDs).filter { filter.allows($0.item) }
        let scanned = ProgrammeRecommender.channelsToScan(channels, profile: profile)
        let favoriteKeys = Set(profile.favorites.compactMap(\.item.bookmarkKey))
        var candidates: [ProgrammeCandidate] = []
        let end = now.addingTimeInterval(ProgrammeRecommender.window)
        for channel in scanned {
            let upcoming = await epg.upcoming(for: channel.ref, from: now, limit: 5)
            for programme in upcoming where programme.start < end && programme.stop > now && filter.allows(programme: programme, on: channel.item) {
                candidates.append(Self.makeCandidate(programme, channel: channel, profile: profile, favoriteKeys: favoriteKeys))
            }
        }
        let ranked = ProgrammeRecommender.rank(candidates, now: now, limit: ProgrammeRecommender.promptCandidates)
        let shown = Array(ranked.prefix(ProgrammeRecommender.listSize))
        let builtIn = zip(shown, ReasonVariety.pick(shown.map { $0.reasonOptions(now: now) })).map { candidate, reason in
            ProgrammeRecommendation(programme: candidate.programme, channel: candidate.channel, reason: reason)
        }
        let builtInList = ProgrammeList(items: Array(builtIn), isPersonalized: false, fingerprint: fingerprint, createdAt: now)
        guard mayRunModel, !ranked.isEmpty else {
            programmeLists[scope] = builtInList
            return
        }
        if !(programmeLists[scope]?.isPersonalized ?? false) {
            programmeLists[scope] = builtInList
        }

        personalizingProgrammes.insert(scope)
        defer {
            personalizingProgrammes.remove(scope)
        }
        let search = makeGuideSearch(scope: scope, profile: profile, favoriteKeys: favoriteKeys, filter: filter, now: now)
        do {
            let picks = try await runModel(isCurrent: { [weak self] in force || self?.latestProgrammeScope == scope }) {
                try await Task.detached(priority: .userInitiated) {
                    try await ProgrammeRecommender.personalize(ranked: ranked, profile: profile, search: search, now: now)
                }.value
            }
            programmeLists[scope] = ProgrammeList(items: picks, isPersonalized: true, fingerprint: fingerprint, createdAt: .now)
            backoff.succeeded(backoffKey)
        } catch is CancellationError {
            // Skipped or cut short: the built-in list stays.
        } catch {
            Self.logger.error("For You Tonight personalization failed: \(String(describing: error), privacy: .public)")
            backoff.failed(backoffKey, now: .now)
            programmeLists[scope] = builtInList
        }
    }

    private nonisolated static func makeCandidate(_ programme: GuideProgramme, channel: GuideChannel, profile: TasteProfile, favoriteKeys: Set<String>) -> ProgrammeCandidate {
        let key = channel.item.bookmarkKey ?? ""
        return ProgrammeCandidate(
            programme: programme,
            channel: channel,
            channelWeight: profile.channelWeights[key] ?? 0,
            isFavorite: favoriteKeys.contains(key),
            groupScore: profile.groupScore(playlistID: channel.item.playlistID, groupName: channel.item.groupName)
        )
    }

    /// The `searchGuide` tool: programme search in the scope, limited to the suggestion window.
    private func makeGuideSearch(scope: RecommendationScope, profile: TasteProfile, favoriteKeys: Set<String>, filter: MatureContentFilter, now: Date) -> @Sendable @concurrent (String) async -> [ProgrammeCandidate] {
        let epg = epg
        let importIDs = scope.importIDs
        let end = now.addingTimeInterval(ProgrammeRecommender.window)
        return { keyword in
            let results = await epg.searchProgrammes(keyword, importIDs: importIDs, limit: 30)
            return results.filter { $0.programme.start < end && $0.programme.stop > now && filter.allows(programme: $0.programme, on: $0.channel) }.map { result in
                Self.makeCandidate(result.programme, channel: GuideChannel(item: result.channel, ref: result.ref), profile: profile, favoriteKeys: favoriteKeys)
            }
        }
    }

    // MARK: - Stored picks

    private struct StoredPicks: Codable {
        struct Pick: Codable {
            let key: String
            let reason: String
        }

        let fingerprint: String
        let createdAt: Date
        let picks: [Pick]
    }

    private func storePicks(_ picks: [ChannelRecommendation], fingerprint: String) {
        let stored = StoredPicks(
            fingerprint: fingerprint,
            createdAt: .now,
            picks: picks.compactMap { pick in pick.item.bookmarkKey.map { StoredPicks.Pick(key: $0, reason: pick.reason) } }
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.fluxo.set(data, forKey: Self.storedPicksKey)
        }
    }

    /// The stored picks when they were made for `fingerprint` and are still fresh, resolved against the
    /// candidates (or the library).
    private func storedPicks(fingerprint: String, candidates: [ChannelCandidate], filter: MatureContentFilter) -> [ChannelRecommendation]? {
        guard let data = UserDefaults.fluxo.data(forKey: Self.storedPicksKey),
              let stored = try? JSONDecoder().decode(StoredPicks.self, from: data),
              stored.fingerprint == fingerprint,
              Date.now.timeIntervalSince(stored.createdAt) < Self.personalizedLifetime else {
            return nil
        }
        let byKey = Dictionary(candidates.compactMap { candidate in candidate.item.bookmarkKey.map { ($0, candidate) } }, uniquingKeysWith: { first, _ in first })
        let picks = stored.picks.compactMap { pick -> ChannelRecommendation? in
            if let candidate = byKey[pick.key] {
                return ChannelRecommendation(item: candidate.item, reason: pick.reason, programme: candidate.programme)
            }
            return LibraryLookup.channel(forKey: pick.key, in: container).map { ChannelRecommendation(item: $0, reason: pick.reason, programme: nil) }
        }
        let distinct = ChannelRecommender.distinct(picks, filter: filter)
        return distinct.count >= 3 ? distinct : nil
    }

    /// Forgets every list (e.g. after Apple Intelligence was turned on or off).
    func invalidate() {
        channelLists.removeAll()
        programmeLists.removeAll()
        UserDefaults.fluxo.removeObject(forKey: Self.storedPicksKey)
        backoff.reset()
    }
}

/// When the model failed for a taste, it does not run again for it before 15 minutes, then 30, 1 hour and so on up
/// to 6 hours. Kept in the defaults (the newest few tastes), so a model that fails at every launch is not asked at
/// every launch.
struct ModelBackoff {

    private struct Entry: Codable {
        var failures: Int
        var retryAfter: Date
    }

    static let firstDelay: TimeInterval = 15 * 60
    static let longestDelay: TimeInterval = 6 * 3_600
    static let keptEntries = 8

    let defaultsKey: String
    private var entries: [String: Entry]

    init(defaultsKey: String) {
        self.defaultsKey = defaultsKey
        if let data = UserDefaults.fluxo.data(forKey: defaultsKey), let entries = try? JSONDecoder().decode([String: Entry].self, from: data) {
            self.entries = entries
        } else {
            entries = [:]
        }
    }

    func isBackingOff(_ key: String, now: Date) -> Bool {
        entries[key].map { now < $0.retryAfter } ?? false
    }

    mutating func failed(_ key: String, now: Date) {
        let failures = (entries[key]?.failures ?? 0) + 1
        let delay = min(Self.longestDelay, Self.firstDelay * pow(2, Double(failures - 1)))
        entries[key] = Entry(failures: failures, retryAfter: now.addingTimeInterval(delay))
        if entries.count > Self.keptEntries {
            for (oldKey, _) in entries.sorted(by: { $0.value.retryAfter < $1.value.retryAfter }).prefix(entries.count - Self.keptEntries) {
                entries[oldKey] = nil
            }
        }
        save()
    }

    mutating func succeeded(_ key: String) {
        guard entries.removeValue(forKey: key) != nil else {
            return
        }
        save()
    }

    mutating func reset() {
        entries.removeAll()
        save()
    }

    private func save() {
        if entries.isEmpty {
            UserDefaults.fluxo.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.fluxo.set(data, forKey: defaultsKey)
        }
    }
}
