//
//  EPGReader.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import os
import SwiftData

/// Answers every guide question off the main actor: which guide channel a playlist channel has, what it shows
/// now and next, its programmes over a time range, the playlist channels that have a guide, and programme search.
///
/// The matcher (`EPGChannelMatcher`) is built by `reload()` from the channels with programmes of the enabled
/// sources and the manual overrides; it is small (a few dictionaries of strings). Each query uses a fresh
/// `ModelContext`, so results always reflect the last committed refresh, and only value types leave the actor.
actor EPGReader {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "EPGReader")
    static let channelPageSize = 5_000

    private let container: ModelContainer
    private var matcher = EPGChannelMatcher.empty
    private var currentImportIDs: [UUID] = []
    private var sourceNames: [UUID: String] = [:]

    /// Now / next per guide channel, until the programme ends.
    private var nowNextCache: [GuideChannelRef: NowNext] = [:]
    /// Guide channels per scope (import IDs of the playlists), until the next reload.
    private var channelCache: [[UUID]: [GuideChannel]] = [:]

    init(container: ModelContainer) {
        self.container = container
    }

    /// Whether any enabled source has a guide.
    var hasGuide: Bool {
        !matcher.isEmpty
    }

    // MARK: - Matching

    /// Rebuilds the matcher. Call after a refresh, a source change or an override change.
    @discardableResult
    func reload() -> Bool {
        let context = makeContext()
        do {
            let sources = try context.fetch(EPGQueries.sources()).filter { $0.isEnabled && $0.currentImportID != nil }
            var indexed: [(EPGChannelMatcher.Source, [EPGChannelMatcher.Channel])] = []
            var importIDsBySource: [UUID: UUID] = [:]
            sourceNames = [:]
            for source in sources {
                guard let importID = source.currentImportID else {
                    continue
                }
                importIDsBySource[source.uuid] = importID
                sourceNames[source.uuid] = source.name
                let channels = try context.fetch(EPGQueries.matchableChannels(importID: importID)).map { channel in
                    EPGChannelMatcher.Channel(
                        channelID: channel.channelID,
                        names: [channel.displayName] + (channel.otherNames.isEmpty ? [] : channel.otherNames.components(separatedBy: "\n"))
                    )
                }
                indexed.append((EPGChannelMatcher.Source(sourceID: source.uuid, importID: importID, playlistID: source.playlistID), channels))
            }

            var overrides: [String: EPGChannelMatcher.Override] = [:]
            for override in try context.fetch(EPGQueries.overrides()) {
                if override.channelID.isEmpty {
                    overrides[override.key] = EPGChannelMatcher.Override.none
                } else if let sourceID = override.sourceID, let importID = importIDsBySource[sourceID] {
                    overrides[override.key] = .channel(GuideChannelRef(sourceID: sourceID, importID: importID, channelID: override.channelID))
                }
            }
            matcher = EPGChannelMatcher(sources: indexed, overrides: overrides)
            currentImportIDs = Array(importIDsBySource.values)
        } catch {
            Self.logger.error("Could not load the guide channels: \(error.localizedDescription, privacy: .public)")
            matcher = .empty
            currentImportIDs = []
        }
        nowNextCache.removeAll()
        channelCache.removeAll()
        return !matcher.isEmpty
    }

    func ref(for item: ChannelItem) -> GuideChannelRef? {
        guard item.kind == .live else {
            return nil
        }
        return matcher.match(item)
    }

    /// The automatic match, ignoring any override (shown by the matching picker).
    func automaticRef(for item: ChannelItem) -> GuideChannelRef? {
        matcher.automaticMatch(tvgID: item.tvgID, name: item.name, playlistID: item.playlistID)
    }

    // MARK: - Programmes

    func nowNext(for item: ChannelItem, at date: Date = .now) -> NowNext? {
        guard let ref = ref(for: item) else {
            return nil
        }
        return nowNext(for: ref, at: date)
    }

    func nowNext(for ref: GuideChannelRef, at date: Date = .now) -> NowNext? {
        if let cached = nowNextCache[ref], let validUntil = cached.validUntil, date < validUntil, cached.current.map({ $0.start <= date }) ?? true {
            return cached
        }
        let rows = (try? makeContext().fetch(EPGQueries.upcoming(ref: ref, from: date, limit: 2))) ?? []
        let programmes = rows.map(GuideProgramme.init)
        guard !programmes.isEmpty else {
            return nil
        }
        let value: NowNext
        if let first = programmes.first, first.start <= date {
            value = NowNext(current: first, next: programmes.dropFirst().first)
        } else {
            value = NowNext(current: nil, next: programmes.first)
        }
        if nowNextCache.count > 2_000 {
            nowNextCache.removeAll(keepingCapacity: true)
        }
        nowNextCache[ref] = value
        return value
    }

    func programmes(for ref: GuideChannelRef, in interval: DateInterval) -> [GuideProgramme] {
        ((try? makeContext().fetch(EPGQueries.programmes(ref: ref, overlapping: interval))) ?? []).map(GuideProgramme.init)
    }

    func upcoming(for ref: GuideChannelRef, from date: Date, limit: Int) -> [GuideProgramme] {
        ((try? makeContext().fetch(EPGQueries.upcoming(ref: ref, from: date, limit: limit))) ?? []).map(GuideProgramme.init)
    }

    // MARK: - Channels

    /// The live channels of the given playlist imports that have a guide, in playlist order.
    func guideChannels(importIDs: [UUID]) -> [GuideChannel] {
        guard !matcher.isEmpty else {
            return []
        }
        if let cached = channelCache[importIDs] {
            return cached
        }
        var result: [GuideChannel] = []
        var seen: Set<String> = []
        for importID in importIDs {
            var offset = 0
            while !Task.isCancelled {
                let page = (try? makeContext().fetch(EPGQueries.liveChannels(importID: importID, offset: offset, limit: Self.channelPageSize))) ?? []
                for channel in page {
                    let item = ChannelItem(channel)
                    guard let ref = matcher.match(item) else {
                        continue
                    }
                    // Playlists often list the same channel twice (HD / SD, backup URLs): keep the first.
                    let key = "\(item.playlistID.uuidString)|\(ref.sourceID.uuidString)|\(ref.channelID)"
                    if seen.insert(key).inserted {
                        result.append(GuideChannel(item: item, ref: ref))
                    }
                }
                guard page.count == Self.channelPageSize else {
                    break
                }
                offset += Self.channelPageSize
            }
        }
        if !Task.isCancelled {
            channelCache[importIDs] = result
        }
        return result
    }

    /// Guide channels for the manual matching picker.
    func channelChoices(term: String, limit: Int = 300) -> [GuideChannelChoice] {
        guard !currentImportIDs.isEmpty else {
            return []
        }
        let context = makeContext()
        let rows = (try? context.fetch(EPGQueries.channels(importIDs: currentImportIDs, term: term, limit: limit))) ?? []
        return rows.map { channel in
            GuideChannelChoice(
                ref: GuideChannelRef(sourceID: channel.sourceID, importID: channel.importID, channelID: channel.channelID),
                sourceName: sourceNames[channel.sourceID] ?? "",
                displayName: channel.displayName,
                icon: channel.icon,
                hasProgrammes: channel.hasProgrammes
            )
        }
    }

    func choice(for ref: GuideChannelRef) -> GuideChannelChoice? {
        let importID = ref.importID
        let channelID = ref.channelID
        var descriptor = FetchDescriptor<EPGChannel>(predicate: #Predicate { $0.importID == importID && $0.channelID == channelID })
        descriptor.fetchLimit = 1
        guard let channel = try? makeContext().fetch(descriptor).first else {
            return nil
        }
        return GuideChannelChoice(ref: ref, sourceName: sourceNames[ref.sourceID] ?? "", displayName: channel.displayName, icon: channel.icon, hasProgrammes: channel.hasProgrammes)
    }

    // MARK: - Search

    /// Programmes that have not ended whose title, subtitle or description contains `term`, on channels of the
    /// given playlist imports, soonest first (programmes on air now come first).
    func search(term: String, importIDs: [UUID], now: Date = .now, limit: Int = 150) -> [GuideSearchResult] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !currentImportIDs.isEmpty else {
            return []
        }
        guard !guideChannels(importIDs: importIDs).isEmpty else {
            return []
        }
        // Fetch more rows than needed: some belong to guide channels that are not in this scope.
        let rows = (try? makeContext().fetch(EPGQueries.search(term: term, importIDs: currentImportIDs, after: now, limit: limit * 4))) ?? []
        return results(of: rows, importIDs: importIDs, limit: limit)
    }

    /// Programmes that overlap `interval` with a category containing `term`, on channels of the given playlist
    /// imports, soonest first.
    func search(category term: String, importIDs: [UUID], overlapping interval: DateInterval, limit: Int) -> [GuideSearchResult] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !currentImportIDs.isEmpty else {
            return []
        }
        guard !guideChannels(importIDs: importIDs).isEmpty else {
            return []
        }
        let rows = (try? makeContext().fetch(EPGQueries.programmes(category: term, importIDs: currentImportIDs, overlapping: interval, limit: limit * 4))) ?? []
        return results(of: rows, importIDs: importIDs, limit: limit)
    }

    /// The rows on channels of the given playlist imports, with their channel.
    private func results(of rows: [EPGProgramme], importIDs: [UUID], limit: Int) -> [GuideSearchResult] {
        guard !rows.isEmpty else {
            return []
        }
        let channels = guideChannels(importIDs: importIDs)
        var channelByRef: [GuideChannelRef: ChannelItem] = [:]
        for channel in channels where channelByRef[channel.ref] == nil {
            channelByRef[channel.ref] = channel.item
        }
        var results: [GuideSearchResult] = []
        for row in rows {
            let ref = GuideChannelRef(sourceID: row.sourceID, importID: row.importID, channelID: row.channelID)
            guard let channel = channelByRef[ref] else {
                continue
            }
            results.append(GuideSearchResult(programme: GuideProgramme(row), channel: channel, ref: ref))
            if results.count >= limit {
                break
            }
        }
        return results
    }

    // MARK: - Private

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }
}
