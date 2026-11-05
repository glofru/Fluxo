//
//  ProgrammeRecommender.swift
//  Fluxo
//
//  "For You Tonight" in the Guide: programmes of the next hours the viewer is likely to want.
//
//  Candidates are the programmes on now and in the next six hours on the guide channels the viewer watches or
//  likes (and the channels of their groups); the built-in ranking favors their channels, on-air and soon
//  programmes, and programme categories that recur on their channels. With Apple Intelligence the on-device
//  model picks and explains them (`ProgrammePicks`) and can look for more with the `searchGuide` tool.
//

import Foundation
import FoundationModels
import os

struct ProgrammeCandidate: Sendable {
    let programme: GuideProgramme
    let channel: GuideChannel
    /// Bookmark weight of the channel (0 for channels the viewer never watched).
    let channelWeight: Double
    let isFavorite: Bool
    let groupScore: Double
    var score: Double = 0

    /// The built-in reason, shown without Apple Intelligence.
    func reason(now: Date) -> String {
        reasonOptions(now: now)[0]
    }

    /// Ways to say why, best first (see `ReasonVariety`): the main reason, then the programme's category and its
    /// timing, so four favorites in a row do not all say "On your favorite channel".
    func reasonOptions(now: Date) -> [String] {
        let category = programme.categories.first.map { $0.prefix(1).uppercased(with: OnDeviceModel.responseLocale) + $0.dropFirst() }
        let startsSoon = programme.start > now && programme.start.timeIntervalSince(now) < 3_600
        var options: [String] = []
        if isFavorite {
            options.append(String(localized: "On your favorite channel"))
            if let category {
                options.append(String(localized: "\(category) on a favorite channel"))
            }
            options.append(startsSoon ? String(localized: "Starts soon on a favorite") : String(localized: "From your favorites"))
        }
        if channelWeight > 0.5 {
            // The card shows the channel's name already.
            options.append(String(localized: "A channel you watch"))
            options.append(String(localized: "You watch this channel often"))
        }
        if groupScore > 0.3 {
            let group = ChannelCandidate.displayGroup(channel.item.groupName)
            options.append(String(localized: "Because you watch \(group)"))
            if let category {
                options.append(String(localized: "\(category), like your \(group) channels"))
            }
            options.append(String(localized: "More from \(group)"))
        }
        if programme.isOnAir(at: now) {
            options.append(String(localized: "On now"))
        } else if startsSoon {
            options.append(String(localized: "Starts soon"))
        }
        if let category {
            options.append(String(localized: "\(category), coming up"))
        }
        options.append(String(localized: "Coming up"))
        return options
    }
}

/// Picks, for each card of a row, the first reason the cards before it did not use, so the built-in reasons
/// vary. When every option is taken, the card keeps its main reason.
enum ReasonVariety {
    static func pick(_ options: [[String]]) -> [String] {
        var used: Set<String> = []
        return options.map { candidates in
            let reason = candidates.first { !used.contains($0) } ?? candidates.first ?? ""
            used.insert(reason)
            return reason
        }
    }
}

enum ProgrammeRecommender {

    static let listSize = 8
    static let promptCandidates = 24
    /// How far ahead the suggestions look.
    static let window: TimeInterval = 6 * 3_600

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Recommendations")

    /// The guide channels worth reading the programmes of: the viewer's channels first, then those of their groups,
    /// then (for a new library) the first ones.
    static func channelsToScan(_ channels: [GuideChannel], profile: TasteProfile, limit: Int = 40) -> [GuideChannel] {
        var picked: [GuideChannel] = []
        var seen: Set<UUID> = []
        func add(_ channel: GuideChannel) {
            if picked.count < limit, seen.insert(channel.id).inserted {
                picked.append(channel)
            }
        }
        let weighted = channels.filter { profile.channelWeights[$0.item.bookmarkKey ?? ""] != nil }
            .sorted { (profile.channelWeights[$0.item.bookmarkKey ?? ""] ?? 0) > (profile.channelWeights[$1.item.bookmarkKey ?? ""] ?? 0) }
        weighted.forEach(add)
        let groups = Set(profile.groups.prefix(6).map { "\($0.playlistID.uuidString)|\($0.groupName)" })
        channels.filter { groups.contains("\($0.item.playlistID.uuidString)|\($0.item.groupName)") }.forEach(add)
        if picked.count < 20 {
            channels.prefix(30).forEach(add)
        }
        return picked
    }

    /// Scores the candidates (higher is better) and keeps the best, at most two per channel.
    static func rank(_ candidates: [ProgrammeCandidate], now: Date, limit: Int = listSize) -> [ProgrammeCandidate] {
        // Categories that recur on the viewer's channels tonight say what they like.
        var categoryWeights: [String: Double] = [:]
        for candidate in candidates where candidate.channelWeight > 0 {
            for category in candidate.programme.categories {
                categoryWeights[category.lowercased(), default: 0] += candidate.channelWeight
            }
        }
        let topCategoryWeight = categoryWeights.values.max() ?? 1
        var scored = candidates.map { candidate -> ProgrammeCandidate in
            var candidate = candidate
            let programme = candidate.programme
            var score = min(2.5, candidate.channelWeight) + (candidate.isFavorite ? 1 : 0) + candidate.groupScore
            if programme.isOnAir(at: now) {
                // Better early in the programme than near its end.
                score += 0.8 * (1 - programme.progress(at: now))
            } else {
                score += max(0, 0.6 - programme.start.timeIntervalSince(now) / window)
            }
            if programme.stop.timeIntervalSince(programme.start) >= 25 * 60 {
                score += 0.3
            }
            let category = programme.categories.map { categoryWeights[$0.lowercased()] ?? 0 }.max() ?? 0
            score += 0.8 * category / topCategoryWeight
            candidate.score = score
            return candidate
        }
        scored.sort { $0.score > $1.score }
        var perChannel: [UUID: Int] = [:]
        var result: [ProgrammeCandidate] = []
        for candidate in scored where result.count < limit {
            let count = perChannel[candidate.channel.id, default: 0]
            guard count < 2 else {
                continue
            }
            perChannel[candidate.channel.id] = count + 1
            result.append(candidate)
        }
        return result
    }

    // MARK: - Apple Intelligence

    static func personalize(
        ranked: [ProgrammeCandidate],
        profile: TasteProfile,
        search: @escaping @Sendable (String) async -> [ProgrammeCandidate],
        now: Date = .now
    ) async throws -> [ProgrammeRecommendation] {
        #if os(tvOS)
        throw OnDeviceModelUnavailable()
        #else
        let listed = Array(ranked.prefix(promptCandidates))
        let registry = CandidateRegistry(listed)
        let tool = SearchGuideTool(registry: registry, now: now, search: search)
        let session = OnDeviceModel.session(tools: [tool], instructions: instructions)
        let prompt = prompt(candidates: listed, profile: profile, now: now)

        let clock = ContinuousClock()
        let started = clock.now
        let response = try await OnDeviceModel.withTimeout(seconds: 30) {
            try await session.respond(to: prompt, generating: ProgrammePicks.self, options: OnDeviceModel.options(maximumTokens: 450))
        }
        logger.notice("For You Tonight: \(response.content.picks.count) picks in \(String(describing: clock.now - started), privacy: .public)")

        var seen: Set<String> = []
        let valid = response.content.picks.compactMap { pick in registry.candidate(number: pick.number).map { (pick, $0) } }
        let reasons = await OnDeviceModel.localized(valid.map(\.0.reason))
        let picks = zip(valid, reasons).compactMap { entry, reason -> ProgrammeRecommendation? in
            let candidate = entry.1
            let recommendation = ProgrammeRecommendation(
                programme: candidate.programme,
                channel: candidate.channel,
                reason: ChannelRecommender.cleanReason(reason, fallback: candidate.reason(now: now))
            )
            guard seen.insert(recommendation.id).inserted else {
                return nil
            }
            return recommendation
        }
        guard picks.count >= 3 else {
            throw RecommendationError.tooFewPicks
        }
        return Array(picks.prefix(listSize))
        #endif
    }

    static var instructions: String {
        """
        You are the TV guide assistant of Fluxo, a TV app. From a numbered list of programmes on the viewer's own \
        channels, on now or in the next hours, choose the ones the viewer is most likely to enjoy.
        Prefer programmes on the channels the viewer watches most, of the kinds those channels show, and \
        programmes that suit the time of day. Avoid short fillers and mix different channels.
        Only use numbers from the list or returned by the searchGuide tool; never invent programmes. Call \
        searchGuide only when an obvious interest of the viewer is missing from the list.
        \(OnDeviceModel.languageInstruction) A reason has at most six words, is addressed to the viewer and \
        does not repeat the programme title.
        """
    }

    static func prompt(candidates: [ProgrammeCandidate], profile: TasteProfile, now: Date) -> String {
        var lines: [String] = ["Now: \(ViewingMoment.description(of: now))."]
        let watched = profile.history.prefix(8).map { "\($0.item.displayName) (\($0.watchCount)×)" }
        lines.append(watched.isEmpty ? "The viewer has not watched anything yet." : "The viewer often watches: \(watched.joined(separator: "; ")).")
        let favorites = profile.favorites.prefix(8).map(\.item.displayName)
        if !favorites.isEmpty {
            lines.append("Favorite channels: \(favorites.joined(separator: "; ")).")
        }
        lines.append("Programmes:")
        for (index, candidate) in candidates.enumerated() {
            lines.append("\(index + 1). \(describe(candidate, now: now))")
        }
        lines.append("Choose the 6 best programmes for the viewer, best first. Write the reasons in \(OnDeviceModel.responseLanguageName).")
        return lines.joined(separator: "\n")
    }

    /// "21:30–23:00 on Sky Cinema Uno: Dune (Film, Science fiction). A noble family…".
    static func describe(_ candidate: ProgrammeCandidate, now: Date) -> String {
        let programme = candidate.programme
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let time = programme.isOnAir(at: now) ? "on now until \(formatter.string(from: programme.stop))" : "\(formatter.string(from: programme.start))–\(formatter.string(from: programme.stop))"
        var text = "\(time) on \(candidate.channel.item.displayName): \(programme.title)"
        if !programme.categories.isEmpty {
            text += " (\(programme.categories.prefix(2).joined(separator: ", ")))"
        }
        let summary = programme.summary.isEmpty ? programme.subtitle : programme.summary
        if !summary.isEmpty {
            text += ". \(summary.prefix(70))"
        }
        return text
    }
}

#if !os(tvOS)
@Generable
struct ProgrammePicks {
    @Guide(description: "The best programmes for the viewer, best first.", .count(3...6))
    var picks: [ProgrammePick]
}

@Generable
struct ProgrammePick {
    @Guide(description: "The number of the programme, as listed.")
    var number: Int
    @Guide(description: "Why it suits the viewer, at most six words, without the title.")
    var reason: String
}

/// Lets the model look for upcoming programmes in the guide by keyword.
struct SearchGuideTool: Tool {

    let name = "searchGuide"
    let description = "Finds programmes on the viewer's channels in the next hours whose title or description contains a keyword, such as a sport, a team, a film genre or a show. Returns new numbered programmes."

    @Generable
    struct Arguments {
        @Guide(description: "One or two words, for example \"football\" or \"documentary\".")
        var keyword: String
    }

    let registry: CandidateRegistry<ProgrammeCandidate>
    let now: Date
    let search: @Sendable (String) async -> [ProgrammeCandidate]

    func call(arguments: Arguments) async throws -> String {
        guard registry.beginToolCall() else {
            return "No more searches. Choose from the programmes you have."
        }
        let keyword = arguments.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = Set(registry.all.map { "\($0.programme.id)|\($0.channel.id)" })
        let found = await search(keyword).filter { !known.contains("\($0.programme.id)|\($0.channel.id)") }.prefix(6)
        guard !found.isEmpty else {
            return "No programme in the next hours matches \"\(keyword)\"."
        }
        let numbers = registry.append(Array(found))
        return zip(numbers, found).map { "\($0). \(ProgrammeRecommender.describe($1, now: now))" }.joined(separator: "\n")
    }
}
#endif
