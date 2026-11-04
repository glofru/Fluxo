//
//  ChannelRecommender.swift
//  Fluxo
//
//  "For You" on Home: channels the viewer is likely to want now.
//
//  1. Candidates (no model): channels of the groups the viewer watches most, channels with a name like the most
//     watched ones, favorites, and, for a library without history, the first groups of each playlist.
//  2. Built-in ranking (no model): group affinity, on-air programmes, variety. This is what the row shows at
//     once, and all it shows without Apple Intelligence.
//  3. Apple Intelligence (on device): the model reads a short profile and the numbered candidates, may search
//     the library for more with the `searchChannels` tool, and answers with `ChannelPicks` (numbers and short
//     reasons, as structured output). Numbers are checked against the candidates, so nothing is invented.
//

import Foundation
import FoundationModels
import os
import SwiftData

/// A channel that can be suggested, and why it is in the list.
struct ChannelCandidate: Sendable {

    enum Origin: Sendable, Hashable {
        case favorite
        case history(watchCount: Int)
        /// A channel of a group the viewer watches.
        case group(String)
        /// A channel whose name is like one the viewer watches.
        case similar(String)
        /// No history yet: a channel of one of the first groups.
        case discover(String)
        /// Found by the model with the search tool.
        case search(String)
    }

    let item: ChannelItem
    let origin: Origin
    var programme: GuideProgramme?
    var score: Double = 0

    /// The built-in reason, shown without Apple Intelligence.
    var reason: String {
        reasonOptions[0]
    }

    /// Ways to say why, best first; `ReasonVariety` picks one that the cards before did not use yet, so a row
    /// does not say "Because you watch News" three times.
    var reasonOptions: [String] {
        let onNow = programme.map { String(localized: "On now: \($0.title)") }
        switch origin {
        case .favorite:
            if let programme {
                return [TextParts.line([String(localized: "Your favorite", comment: "Apple Intelligence suggestions: why a channel is suggested. A programme title follows after a separator, as in 'Your favorite · Evening News'."), programme.title])]
            }
            return [String(localized: "One of your favorites"), String(localized: "From your favorites")]
        case .history(let watchCount):
            // Only older history gets here: the recent channels are in Continue Watching.
            let first = watchCount >= 3 ? String(localized: "You watch this often") : String(localized: "Watch it again")
            return [first] + [onNow].compactMap { $0 }
        case .group(let group):
            let name = Self.displayGroup(group)
            return [String(localized: "Because you watch \(name)")] + [onNow, String(localized: "More from \(name)"), String(localized: "Also in \(name)")].compactMap { $0 }
        case .similar(let name):
            return [String(localized: "Like \(name)")] + [onNow, String(localized: "Similar to \(name)")].compactMap { $0 }
        case .discover(let group):
            let name = Self.displayGroup(group)
            return [String(localized: "From \(name)")] + [onNow, String(localized: "Explore \(name)")].compactMap { $0 }
        case .search:
            return [String(localized: "Matches what you watch")] + [onNow].compactMap { $0 }
        }
    }

    var groupKey: String {
        "\(item.playlistID.uuidString)|\(item.groupName)"
    }

    static func displayGroup(_ name: String) -> String {
        name.isEmpty ? String(localized: "Other") : name
    }
}

enum ChannelRecommender {

    static let listSize = 10
    static let maximumPerGroup = 3
    /// Candidates listed in the prompt (a few hundred tokens).
    static let promptCandidates = 24
    /// History entries Home already shows in Continue Watching (`RecentlyWatchedRow.fetchLimit`).
    static let continueWatchingCount = 20

    /// Favorites Home already shows in the Favorites row, right below For You (`FavoritesRow.fetchLimit`).
    static let favoritesRowCount = 20

    /// What Home shows in the rows around For You, Continue Watching and Favorites, for these playlists: For
    /// You suggests other channels. Favorites past the row's first ones can still be suggested.
    static func shownKeys(profile: TasteProfile, playlistIDs: Set<UUID>) -> (keys: Set<String>, entries: [BookmarkSnapshot]) {
        let history = profile.history.filter { playlistIDs.contains($0.item.playlistID) }.prefix(continueWatchingCount)
        let favorites = profile.favorites.filter { playlistIDs.contains($0.item.playlistID) }.prefix(favoritesRowCount)
        let entries = Array(history) + Array(favorites)
        return (Set(entries.compactMap(\.item.bookmarkKey)), entries)
    }

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Recommendations")

    // MARK: - Candidates

    /// Candidates from the library (off the main actor), without programmes yet.
    static func candidates(profile: TasteProfile, importIDs: [UUID], container: ModelContainer) async -> [ChannelCandidate] {
        let playlists = LibraryLookup.visiblePlaylists(in: container).filter { importIDs.contains($0.importID) }
        let importByPlaylist = Dictionary(playlists.map { ($0.playlistID, $0.importID) }, uniquingKeysWith: { first, _ in first })
        var result: [ChannelCandidate] = []
        // What Continue Watching and Favorites show is not suggested again, by any origin (its group, a name like
        // it…), nor its HD / SD copies.
        let shown = shownKeys(profile: profile, playlistIDs: Set(importByPlaylist.keys))
        var seen: Set<String> = shown.keys
        for entry in shown.entries {
            seen.insert(nameKey(of: entry.item))
        }

        func add(_ item: ChannelItem, _ origin: ChannelCandidate.Origin) {
            guard item.url != nil else {
                return
            }
            // HD / SD copies and backup URLs of one channel count once, and so do the episodes of a series: the
            // series is suggested as a whole (its card opens the series page).
            guard seen.insert(item.bookmarkKey ?? item.id.uuidString).inserted, seen.insert(nameKey(of: item)).inserted else {
                return
            }
            result.append(ChannelCandidate(item: item, origin: origin))
        }

        let inScope = { (item: ChannelItem) in importByPlaylist[item.playlistID] != nil }

        for entry in profile.favorites where inScope(entry.item) {
            add(entry.item, .favorite)
        }
        // Older history, past what Continue Watching shows.
        for entry in profile.history.filter({ inScope($0.item) }).dropFirst(continueWatchingCount).prefix(8) {
            add(entry.item, .history(watchCount: entry.watchCount))
        }
        // The groups the viewer watches most.
        for group in profile.groups.prefix(6) {
            guard let importID = importByPlaylist[group.playlistID] else {
                continue
            }
            for item in LibraryLookup.channels(importID: importID, groupName: group.groupName, limit: 30, in: container) {
                add(item, .group(group.groupName))
            }
        }
        // Channels named like the most watched ones ("Sky Sport F1" → "Sky Sport MotoGP").
        // (Not for episodes: a series title shares no "brand" with other series.)
        for entry in profile.history.prefix(4) where entry.item.series == nil {
            let tokens = ChannelNameNormalizer.tokens(entry.item.displayName).filter { $0.count > 1 && $0 != "+" }
            guard tokens.count >= 2 else {
                continue
            }
            let brand = tokens.prefix(2).joined(separator: " ")
            for item in await LibraryLookup.searchChannels(brand, importIDs: importIDs, kind: entry.item.kind, limit: 12, in: container) {
                add(item, .similar(entry.item.displayName))
            }
        }
        // Nothing to go on (a new library): the first groups of each kind.
        if result.count < listSize {
            for kind in ChannelContentKind.allCases {
                for group in LibraryLookup.firstGroups(importIDs: importIDs, kind: kind, limit: kind == .live ? 4 : 2, in: container) {
                    for item in LibraryLookup.channels(importID: group.importID, groupName: group.name, limit: kind == .live ? 8 : 6, in: container) {
                        add(item, .discover(group.name))
                    }
                }
            }
        }
        return result
    }

    /// What makes two candidates the same: the series of an episode, otherwise the normalized name.
    static func nameKey(of item: ChannelItem) -> String {
        if let seriesKey = item.seriesBookmarkKey {
            return "series|\(seriesKey)"
        }
        return "\(item.playlistID.uuidString)|\(ChannelNameNormalizer.key(item.displayName))"
    }

    // MARK: - Built-in ranking

    /// Scores the candidates and keeps the best, with at most `maximumPerGroup` per group.
    static func rank(_ candidates: [ChannelCandidate], profile: TasteProfile, limit: Int = listSize) -> [ChannelCandidate] {
        var scored = candidates.enumerated().map { index, candidate -> ChannelCandidate in
            var candidate = candidate
            let onAir = candidate.programme != nil
            let groupScore = profile.groupScore(playlistID: candidate.item.playlistID, groupName: candidate.item.groupName)
            switch candidate.origin {
            case .favorite:
                candidate.score = onAir ? 2.2 : 0.9
            case .history(let watchCount):
                candidate.score = onAir ? 1.2 + min(0.6, Double(watchCount) * 0.1) : 0.4
            case .group:
                candidate.score = 1.2 + 2 * groupScore + (onAir ? 0.5 : 0)
            case .similar:
                candidate.score = 1.8 + (onAir ? 0.5 : 0)
            case .discover:
                candidate.score = 0.6 + (onAir ? 0.6 : 0)
            case .search:
                candidate.score = 1.0 + (onAir ? 0.4 : 0)
            }
            // Keep the playlist order between equal scores.
            candidate.score -= Double(index) * 0.0005
            return candidate
        }
        scored.sort { $0.score > $1.score }
        return diversified(scored, limit: limit)
    }

    static func diversified(_ candidates: [ChannelCandidate], limit: Int) -> [ChannelCandidate] {
        var perGroup: [String: Int] = [:]
        var result: [ChannelCandidate] = []
        for candidate in candidates where result.count < limit {
            let count = perGroup[candidate.groupKey, default: 0]
            guard count < maximumPerGroup else {
                continue
            }
            perGroup[candidate.groupKey] = count + 1
            result.append(candidate)
        }
        return result
    }

    // MARK: - Apple Intelligence

    /// Lets the on-device model pick and explain the suggestions. Throws when the model fails or answers with
    /// fewer than three valid picks (the built-in list is then kept).
    static func personalize(
        ranked: [ChannelCandidate],
        profile: TasteProfile,
        importIDs: [UUID],
        container: ModelContainer,
        now: Date = .now
    ) async throws -> [ChannelRecommendation] {
        let listed = Array(ranked.prefix(promptCandidates))
        let registry = CandidateRegistry(listed)
        let playlistIDs = Set(LibraryLookup.visiblePlaylists(in: container).filter { importIDs.contains($0.importID) }.map(\.playlistID))
        let tool = SearchChannelsTool(registry: registry, importIDs: importIDs, excludedKeys: shownKeys(profile: profile, playlistIDs: playlistIDs).keys, container: container)
        let session = OnDeviceModel.session(tools: [tool], instructions: instructions)
        let prompt = prompt(candidates: listed, profile: profile, now: now)

        let clock = ContinuousClock()
        let started = clock.now
        let response = try await OnDeviceModel.withTimeout(seconds: 30) {
            try await session.respond(to: prompt, generating: ChannelPicks.self, options: OnDeviceModel.options(maximumTokens: 500))
        }
        logger.notice("For You: \(response.content.picks.count) picks in \(String(describing: clock.now - started), privacy: .public)")

        var seen: Set<String> = []
        let valid = response.content.picks.compactMap { pick in registry.candidate(number: pick.number).map { (pick, $0) } }
        let reasons = await OnDeviceModel.localized(valid.map(\.0.reason))
        let picks = zip(valid, reasons).compactMap { entry, reason -> ChannelRecommendation? in
            let candidate = entry.1
            let recommendation = ChannelRecommendation(item: candidate.item, reason: cleanReason(reason, fallback: candidate.reason), programme: candidate.programme)
            guard seen.insert(recommendation.id).inserted else {
                return nil
            }
            return recommendation
        }
        guard picks.count >= 3 else {
            throw RecommendationError.tooFewPicks
        }
        return Array(picks.prefix(listSize))
    }

    static var instructions: String {
        """
        You are the recommendation engine of Fluxo, a TV app. From a numbered list of channels, movies and series \
        in the viewer's own playlists, choose what the viewer is most likely to enjoy right now.
        Prefer channels like the ones the viewer watches most and their favorites, live programmes on now that \
        fit their interests, and things that suit the time of day. Mix a few different groups.
        Only use numbers from the list or returned by the searchChannels tool; never invent channels. Call \
        searchChannels only when an obvious interest of the viewer is missing from the list.
        \(OnDeviceModel.languageInstruction) A reason has at most six words, is addressed to the viewer and \
        does not repeat the channel name\(OnDeviceModel.responseLanguageCode == "en" ? ", for example \"Qualifying starts now, you follow F1\"" : "").
        """
    }

    static func prompt(candidates: [ChannelCandidate], profile: TasteProfile, now: Date) -> String {
        var lines: [String] = ["Now: \(ViewingMoment.description(of: now))."]
        let watched = profile.history.prefix(8).map { entry in
            "\(entry.item.series?.seriesTitle ?? entry.item.displayName) (\(entry.watchCount)×, \(ChannelCandidate.displayGroup(entry.item.groupName)))"
        }
        lines.append(watched.isEmpty ? "The viewer has not watched anything yet." : "The viewer often watches: \(watched.joined(separator: "; ")).")
        let favorites = profile.favorites.prefix(8).map { $0.item.series?.seriesTitle ?? $0.item.displayName }
        if !favorites.isEmpty {
            lines.append("Favorites: \(favorites.joined(separator: "; ")).")
        }
        lines.append("Candidates:")
        for (index, candidate) in candidates.enumerated() {
            lines.append("\(index + 1). \(describe(candidate))")
        }
        lines.append("Choose the 8 best candidates for right now, best first. Write the reasons in \(OnDeviceModel.responseLanguageName).")
        return lines.joined(separator: "\n")
    }

    /// "Sky Sport F1 (live TV, group Sport) — on now: Formula 1 Qualifying (Motorsport)".
    static func describe(_ candidate: ChannelCandidate) -> String {
        let item = candidate.item
        let kind: String
        switch item.kind {
        case .live:
            kind = "live TV"
        case .movie:
            kind = "movie"
        case .series:
            kind = "series"
        }
        // A series is suggested as a whole: its title, not the name of the episode that stands for it.
        var text = "\(item.series?.seriesTitle ?? item.displayName) (\(kind), group \(ChannelCandidate.displayGroup(item.groupName)))"
        if let programme = candidate.programme {
            text += " — on now: \(programme.title)"
            if !programme.categories.isEmpty {
                text += " (\(programme.categories.prefix(2).joined(separator: ", ")))"
            }
        }
        switch candidate.origin {
        case .favorite:
            text += " [favorite]"
        case .history:
            text += " [watched before]"
        default:
            break
        }
        return text
    }

    /// Trims the model's reason; falls back when it is empty or rambles.
    static func cleanReason(_ reason: String, fallback: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”.")))
        guard !trimmed.isEmpty, trimmed.count <= 60 else {
            return fallback
        }
        // The case mapping of the app's language (Turkish "izlediğin" → "İzlediğin"); scripts without case
        // are left as they are.
        return trimmed.prefix(1).uppercased(with: OnDeviceModel.responseLocale) + trimmed.dropFirst()
    }
}

enum RecommendationError: Error {
    case tooFewPicks
}

/// The structured answer of the model for "For You".
@Generable
struct ChannelPicks {
    @Guide(description: "The best candidates for the viewer right now, best first.", .count(3...8))
    var picks: [ChannelPick]
}

@Generable
struct ChannelPick {
    @Guide(description: "The number of the candidate, as listed.")
    var number: Int
    @Guide(description: "Why it suits the viewer now, at most six words, without the channel name.")
    var reason: String
}

/// Lets the model look up channels in the viewer's playlists by name or topic.
struct SearchChannelsTool: Tool {

    let name = "searchChannels"
    let description = "Finds channels, movies or series in the viewer's playlists whose name matches a short query, such as a brand, a sport or a genre. Returns new numbered candidates."

    @Generable
    struct Arguments {
        @Guide(description: "One to three words, for example \"Formula 1\" or \"Cinema\".")
        var query: String
    }

    let registry: CandidateRegistry<ChannelCandidate>
    let importIDs: [UUID]
    /// Continue Watching and the Favorites row: never returned.
    let excludedKeys: Set<String>
    let container: ModelContainer

    func call(arguments: Arguments) async throws -> String {
        guard registry.beginToolCall() else {
            return "No more searches. Choose from the candidates you have."
        }
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var known = Set(registry.all.compactMap(\.item.bookmarkKey)).union(excludedKeys)
        known.formUnion(registry.all.map { ChannelRecommender.nameKey(of: $0.item) })
        var found: [ChannelCandidate] = []
        for item in await LibraryLookup.searchChannels(query, importIDs: importIDs, limit: 24, in: container) where found.count < 6 {
            // One candidate per series.
            guard item.url != nil, !known.contains(item.bookmarkKey ?? ""), known.insert(ChannelRecommender.nameKey(of: item)).inserted else {
                continue
            }
            found.append(ChannelCandidate(item: item, origin: .search(query)))
        }
        guard !found.isEmpty else {
            return "Nothing in the playlists matches \"\(query)\"."
        }
        let numbers = registry.append(Array(found))
        return zip(numbers, found).map { "\($0). \(ChannelRecommender.describe($1))" }.joined(separator: "\n")
    }
}
