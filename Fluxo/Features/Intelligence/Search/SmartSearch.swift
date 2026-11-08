//
//  SmartSearch.swift
//  Fluxo
//
//  Natural-language search: "football tonight", "italian news channels", "something like Sky Sport F1".
//
//  The query becomes a `SearchPlan` (keywords, kind, country, time window, a channel to find similar ones to,
//  and whether programmes are wanted). With Apple Intelligence the on-device model writes the plan as structured
//  output, adding synonyms and translations ("football" → "calcio", "soccer"); without it a small rule-based
//  parser does the same for common words. The plan is then run against the library and the guide with the
//  regular token search and programme search, so every result is a real channel, group or programme.
//

import Foundation
import FoundationModels
import os
import SwiftData

/// What a natural-language query asks for.
struct SmartSearchPlan: Hashable, Sendable {

    enum Kind: String, Hashable, Sendable {
        case any
        case live
        case movies
        case series

        var contentKind: ChannelContentKind? {
            switch self {
            case .any:
                return nil
            case .live:
                return .live
            case .movies:
                return .movie
            case .series:
                return .series
            }
        }
    }

    enum Time: String, Hashable, Sendable {
        case any
        case now
        case tonight
        case today
        case tomorrow
    }

    var keywords: [String] = []
    var kind: Kind = .any
    /// ISO 3166 code, uppercased ("IT"); nil when none.
    var countryCode: String?
    var time: Time = .any
    var similarTo: String?
    var wantsProgrammes = false
    /// True when the on-device model wrote the plan.
    var isFromModel = false

    /// Nothing to search for. A kind and a time alone are a search ("films tomorrow": the films of the guide),
    /// except for live TV, which is every channel.
    var isEmpty: Bool {
        keywords.isEmpty && countryCode == nil && similarTo == nil && genreTerms.isEmpty
    }

    /// Words of guide categories, group names and channel names that mean the kind asked for: what a movie or
    /// series search without keywords looks for (`Movie / Drama`, `Film`, `Serie TV`, `Sky Cinema`).
    var genreTerms: [String] {
        switch kind {
        case .any, .live:
            return []
        case .movies:
            return ["film", "movie", "cinema", "pelicula"]
        case .series:
            return ["serie", "sitcom", "soap", "telenovela"]
        }
    }

    /// A search by kind alone ("films tomorrow", "italian movies"): programmes by category, groups and channels
    /// by name.
    var isGenreSearch: Bool {
        keywords.isEmpty && similarTo == nil && !genreTerms.isEmpty
    }

    /// The chips of the interpretation of `query`, as Smart Results show it: the viewer's own words, with the
    /// time, kind, country or "like …" as understood. Not the synonyms and translations searched as well ("Soccer",
    /// "Calcio" for "football"): shown, an English query would read as Italian. When no keyword is one of the
    /// viewer's words (a word said differently: "something to laugh at" is "comedy"), the first one stands for them.
    /// Japanese and Chinese put no spaces between words ("今夜のサッカー" is one run of letters), so there a keyword
    /// written in those scripts is the viewer's when it is part of what they typed ("サッカー").
    func summaryChips(for query: String) -> [String] {
        let said = Set(SmartSearchRules.words(query))
        var shown = self
        shown.keywords = keywords.filter { keyword in
            let words = SmartSearchRules.words(keyword)
            return !words.isEmpty && words.allSatisfy { word in
                said.contains(word) || (Self.isWrittenWithoutSpaces(word) && said.contains { $0.contains(word) })
            }
        }
        if shown.keywords.isEmpty {
            shown.keywords = Array(keywords.prefix(1))
        }
        return shown.summaryChips
    }

    /// A word of a script written without spaces between words: Chinese characters, kana, Thai, Lao, Khmer, Myanmar.
    /// Only there is a part of a typed run of letters a word of its own; in other scripts it is not ("sport" in
    /// "sports").
    static func isWrittenWithoutSpaces(_ word: String) -> Bool {
        word.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040 ... 0x30FF, 0x31F0 ... 0x31FF, // Hiragana, Katakana and its extensions
                 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0x20000 ... 0x3134F, // Chinese characters
                 0x0E00 ... 0x0EFF, 0x1000 ... 0x109F, 0x1780 ... 0x17FF: // Thai and Lao, Myanmar, Khmer
                true
            default:
                false
            }
        }
    }

    /// Readable chips of the plan ("Football", "Tonight", "Italy"): every keyword, synonyms included
    /// (`summaryChips(for:)` keeps the viewer's own words).
    var summaryChips: [String] {
        var chips = keywords.prefix(3).map { keyword in
            // "Serie A", not "Serie a".
            SmartSearchRules.contentPhrases(in: SmartSearchRules.words(keyword)) == [keyword] ? keyword.capitalized : keyword.prefix(1).uppercased() + keyword.dropFirst()
        }
        if let similarTo {
            chips.append(String(localized: "Like \(similarTo)"))
        }
        if let countryCode, let name = Locale.current.localizedString(forRegionCode: countryCode) {
            chips.append(name)
        }
        if let kind = kind.contentKind {
            chips.append(kind.title)
        }
        switch time {
        case .any:
            break
        case .now:
            chips.append(String(localized: "On Now"))
        case .tonight:
            chips.append(String(localized: "Tonight"))
        case .today:
            chips.append(String(localized: "Today"))
        case .tomorrow:
            chips.append(String(localized: "Tomorrow"))
        }
        return chips
    }

    /// The interval programmes must overlap, or nil for "any time that has not ended".
    func interval(now: Date, calendar: Calendar = .current) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
        func at(_ day: Date, hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        switch time {
        case .any:
            return nil
        case .now:
            return DateInterval(start: now, end: now.addingTimeInterval(1))
        case .tonight:
            // After midnight, "tonight" is the rest of the night that is going on.
            if calendar.component(.hour, from: now) < 4 {
                return DateInterval(start: now, end: max(now, at(today, hour: 4)))
            }
            let start = max(now, at(today, hour: 18))
            return DateInterval(start: start, end: max(start, at(tomorrow, hour: 4)))
        case .today:
            return DateInterval(start: now, end: max(now, at(tomorrow, hour: 4)))
        case .tomorrow:
            let start = at(tomorrow, hour: 5)
            let dayAfter = calendar.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow
            return DateInterval(start: start, end: at(dayAfter, hour: 4))
        }
    }
}

/// The results of a natural-language query.
struct SmartSearchResults: Sendable {
    /// Every run makes new results, even for the same query (after the guide reloads, say): Search on the Mac
    /// rebuilds its list for each (`SearchResultsList`).
    let id = UUID()
    let query: String
    let plan: SmartSearchPlan
    let channels: [ChannelItem]
    let groups: [GroupItem]
    let programmes: [GuideSearchResult]

    var isEmpty: Bool {
        channels.isEmpty && groups.isEmpty && programmes.isEmpty
    }
}

enum SmartSearch {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "SmartSearch")

    static let channelLimit = 24
    static let groupLimit = 12
    static let programmeLimit = 30

    /// Whether a query may be a sentence rather than a name: two or more words ("Sky Sport" also runs it, and its
    /// smart results are then a short section above the regular ones).
    static func isNaturalLanguage(_ query: String) -> Bool {
        SmartSearchRules.words(query).count >= 2
    }

    /// Whether Search should add smart results: for sentences with a cue the plain search cannot use (a time,
    /// a kind, a country, "like …", filler words), or when the plain search found nothing. "Sky Sport" alone is a
    /// name, and the plain results are what the viewer wants.
    static func shouldRun(for query: String, regularResultCount: Int?) -> Bool {
        guard isNaturalLanguage(query) else {
            return false
        }
        if regularResultCount == 0 {
            return true
        }
        return SmartSearchRules.hasCue(query)
    }

    // MARK: - Planning

    /// The plan of `query`: by the on-device model when `useModel`, else (or when the model fails) by the rules.
    @concurrent static func plan(for query: String, useModel: Bool) async -> SmartSearchPlan {
        let rules = SmartSearchRules.plan(for: query)
        #if os(tvOS)
        // No on-device model on Apple TV (`PlatformFeatures.onDeviceLanguageModel`).
        return rules
        #else
        guard useModel else {
            return rules
        }
        do {
            let session = OnDeviceModel.session(instructions: instructions)
            let response = try await OnDeviceModel.withTimeout(seconds: 12) {
                try await session.respond(to: "Query: \(query)", generating: GeneratedSearchPlan.self, options: OnDeviceModel.options(maximumTokens: 200))
            }
            let plan = response.content.plan(query: query)
            // The rules only match words that are there for sure: what they found wins over an empty field.
            var merged = plan
            if merged.time == .any {
                merged.time = rules.time
            }
            let phrases = SmartSearchRules.contentPhrases(in: SmartSearchRules.words(query))
            if phrases.isEmpty {
                if merged.kind == .any {
                    merged.kind = rules.kind
                }
            } else {
                // "Serie A" is football: a "series" kind of the model comes from the word, and the rules, which
                // read the phrase as a keyword, know better. The phrase is a keyword in any case.
                merged.kind = rules.kind
                let known = Set(merged.keywords.map { SmartSearchRules.words($0).joined(separator: " ") })
                merged.keywords = phrases.filter { !known.contains($0) } + merged.keywords
            }
            merged.countryCode = merged.countryCode ?? rules.countryCode
            merged.similarTo = rules.similarTo ?? merged.similarTo
            if merged.keywords.isEmpty && merged.similarTo == nil && merged.countryCode == nil {
                merged.keywords = rules.keywords
            }
            merged.wantsProgrammes = merged.wantsProgrammes || merged.time != .any
            return merged
        } catch {
            logger.error("Query planning failed: \(String(describing: error), privacy: .public)")
            return rules
        }
        #endif
    }

    static let instructions = """
        You turn a viewer's search in a TV app into a structured search plan. The app searches channel names, \
        group names and TV guide programmes with plain keywords, so give short keywords that literally appear in \
        names or programme titles: brands, sports, competitions, teams, genres. Add common synonyms and the \
        word in the viewer's language and in English when they differ (football: football, soccer, calcio). \
        Do not put time words, country names or words like "channels", "something" or "watch" in the keywords.
        Examples:
        Query "basketball tomorrow" → keywords basketball, NBA; time tomorrow; programmes true.
        Query "german news channels" → keywords news, nachrichten; country DE; kind live TV; programmes false.
        Query "something like Canal+ Sport" → similar to Canal+ Sport; no keywords; kind live TV.
        Only use "similar to" when the query asks for something like a named channel.
        """

    // MARK: - Running

    /// Runs `plan` against the library (channels and groups) and, when `includeGuide`, the guide (programmes).
    @concurrent static func run(_ plan: SmartSearchPlan, query: String, importIDs: [UUID], container: ModelContainer, epg: EPGStore, includeGuide: Bool = true, now: Date = .now) async -> SmartSearchResults {
        async let library = Task.detached(priority: .userInitiated) {
            await searchLibrary(plan, query: query, importIDs: importIDs, container: container)
        }.value
        let programmes = includeGuide ? await searchGuide(plan, query: query, importIDs: importIDs, container: container, epg: epg, now: now) : []
        let (channels, groups) = await library
        return SmartSearchResults(query: query, plan: plan, channels: channels, groups: groups, programmes: programmes)
    }

    @concurrent private static func searchLibrary(_ plan: SmartSearchPlan, query: String, importIDs: [UUID], container: ModelContainer) async -> ([ChannelItem], [GroupItem]) {
        let playlists = LibraryLookup.visiblePlaylists(in: container).filter { importIDs.contains($0.importID) }
        let country = CountryFilter(plan: plan, playlists: playlists)
        let countryTerms = country.terms
        let kind = plan.kind.contentKind

        func matchesCountry(name: String, group: String, playlistID: UUID) -> Bool {
            country.matches(name: name, group: group, playlistID: playlistID)
        }

        // Channels: every keyword, scored by how many keywords matched (and their rank).
        var scores: [String: (item: ChannelItem, score: Double)] = [:]
        func add(_ items: [ChannelItem], weight: Double) {
            for (rank, item) in items.enumerated() where matchesCountry(name: item.displayName, group: item.groupName, playlistID: item.playlistID) {
                let key = item.bookmarkKey ?? item.id.uuidString
                let score = weight + 1 / Double(rank + 2)
                scores[key] = (item, (scores[key]?.score ?? 0) + score)
            }
        }
        // The viewer's own words use the typo-tolerant name search as is; added synonyms ("info" for "news") must
        // be whole words of the name or group, or they find "Infotainment" or typo neighbours.
        let queryWords = Set(SmartSearchRules.words(query))
        func isSynonym(_ keyword: String) -> Bool {
            !SmartSearchRules.words(keyword).allSatisfy(queryWords.contains)
        }
        func hasWholeWords(_ keyword: String, in names: String...) -> Bool {
            let words = names.flatMap(SmartSearchRules.words)
            return SmartSearchRules.words(keyword).allSatisfy { word in words.contains { GuideMatch.wordMatches(word, $0) } }
        }
        for keyword in plan.keywords.prefix(6) {
            var found = await LibraryLookup.searchChannels(keyword, importIDs: importIDs, kind: kind, limit: 80, in: container)
            if isSynonym(keyword) {
                found = found.filter { hasWholeWords(keyword, in: $0.displayName, $0.groupName) }
            }
            add(found, weight: isSynonym(keyword) ? 1.5 : 2)
        }

        // Groups: keyword groups in the country, or the country's groups.
        var groups: [GroupItem] = []
        var seenGroups: Set<String> = []
        func addGroups(_ found: [GroupItem]) {
            for group in found where matchesCountry(name: "", group: group.name, playlistID: group.playlistID) && seenGroups.insert(group.id).inserted {
                groups.append(group)
            }
        }
        for keyword in plan.keywords.prefix(6) {
            var found = await LibraryLookup.searchGroups(keyword, importIDs: importIDs, kind: kind, limit: 30, in: container)
            if isSynonym(keyword) {
                found = found.filter { hasWholeWords(keyword, in: $0.name) }
            }
            addGroups(found)
        }
        // "Films tomorrow": the groups and channels named for the kind ("Cinema", "Sky Cinema Uno", "Serie TV"),
        // of any kind (movie channels are live TV), and the first movie or series groups of the playlists.
        if plan.isGenreSearch {
            for term in plan.genreTerms {
                addGroups(await LibraryLookup.searchGroups(term, importIDs: importIDs, limit: 20, in: container).filter { GuideMatch.hasWord(startingWith: term, in: $0.name) })
                let found = await LibraryLookup.searchChannels(term, importIDs: importIDs, limit: 40, in: container)
                add(found.filter { GuideMatch.hasWord(startingWith: term, in: $0.displayName) }, weight: 1.5)
            }
            if let kind {
                addGroups(LibraryLookup.firstGroups(importIDs: importIDs, kind: kind, limit: 6, in: container))
            }
        }
        if plan.keywords.isEmpty, plan.similarTo == nil {
            for term in countryTerms.sorted() where term.count >= 2 {
                addGroups(await LibraryLookup.searchGroups(term, importIDs: importIDs, kind: kind, limit: 20, in: container))
            }
            // The channels of the country's groups.
            for group in groups.prefix(4) {
                add(LibraryLookup.channels(importID: group.importID, groupName: group.name, limit: 12, in: container), weight: 1)
            }
        }

        // "Something like X": X's group and channels with a name like X's.
        if let similarTo = plan.similarTo,
           let reference = await LibraryLookup.searchChannels(similarTo, importIDs: importIDs, limit: 1, in: container).first {
            let referenceKey = reference.bookmarkKey ?? reference.id.uuidString
            let tokens = ChannelNameNormalizer.tokens(reference.displayName).filter { $0.count > 1 && $0 != "+" }
            if tokens.count >= 2 {
                add(await LibraryLookup.searchChannels(tokens.prefix(2).joined(separator: " "), importIDs: importIDs, kind: reference.kind, limit: 30, in: container), weight: 2)
            }
            if let importID = playlists.first(where: { $0.playlistID == reference.playlistID })?.importID {
                add(LibraryLookup.channels(importID: importID, groupName: reference.groupName, limit: 30, in: container), weight: 1.5)
            }
            scores[referenceKey] = nil
        }

        let channels = scores.values.sorted { $0.score > $1.score }.map(\.item)
        // HD / SD copies once, and a series once (its row opens the series page), whichever episode matched.
        var seenNames: Set<String> = []
        let unique = channels.filter { seenNames.insert(ChannelRecommender.nameKey(of: $0)).inserted }
        return (Array(unique.prefix(channelLimit)), Array(groups.prefix(groupLimit)))
    }

    @concurrent private static func searchGuide(_ plan: SmartSearchPlan, query: String, importIDs: [UUID], container: ModelContainer, epg: EPGStore, now: Date) async -> [GuideSearchResult] {
        guard await epg.hasGuide else {
            return []
        }
        let country = CountryFilter(plan: plan, playlists: plan.countryCode == nil ? [] : LibraryLookup.visiblePlaylists(in: container))
        if plan.isGenreSearch {
            return await searchGuideByGenre(plan, importIDs: importIDs, country: country, epg: epg, now: now)
        }
        guard !plan.keywords.isEmpty, plan.wantsProgrammes || plan.time != .any || plan.kind == .any else {
            return []
        }
        let interval = plan.interval(now: now)
        let queryWords = Set(SmartSearchRules.words(query))
        var results: [GuideSearchResult] = []
        var seen: Set<String> = []
        for keyword in plan.keywords.prefix(4) {
            let words = SmartSearchRules.words(keyword)
            guard !words.isEmpty else {
                continue
            }
            // The guide search matches every word as a substring of the title, subtitle or description, which is
            // right for the viewer's own words but not for added synonyms: "serie a" would match any description
            // with "series" and an "a". Synonyms, translations and short words must appear as whole words in the
            // title, subtitle or categories.
            // A competition ("serie a") is one name too, even when the viewer typed it.
            let isPhrase = !words.allSatisfy(queryWords.contains) || SmartSearchRules.contentPhrases(in: words) == [words.joined(separator: " ")]
            let shortWords = words.filter { $0.count < 3 }
            let isStrict = isPhrase || !shortWords.isEmpty
            for result in await epg.searchProgrammes(keyword, importIDs: importIDs, limit: isStrict ? 150 : 80) {
                if let interval, !(result.programme.start < interval.end && result.programme.stop > interval.start) {
                    continue
                }
                if !country.matches(result.channel) {
                    continue
                }
                if isPhrase, !GuideMatch.containsPhrase(words, in: result.programme) {
                    continue
                }
                // The viewer's own short words ("f1"), in any order, but whole.
                if !isPhrase, !shortWords.allSatisfy({ GuideMatch.containsPhrase([$0], in: result.programme) }) {
                    continue
                }
                if seen.insert(result.id).inserted {
                    results.append(result)
                }
                if results.count >= programmeLimit * 2 {
                    break
                }
            }
        }
        results.sort { $0.programme.start < $1.programme.start }
        return Array(results.prefix(programmeLimit))
    }

    /// Programmes whose category names the kind ("Film", "Movie / Drama", "Serie TV") in the plan's time window,
    /// or in the next day when it has none.
    @concurrent private static func searchGuideByGenre(_ plan: SmartSearchPlan, importIDs: [UUID], country: CountryFilter, epg: EPGStore, now: Date) async -> [GuideSearchResult] {
        let interval = plan.interval(now: now) ?? DateInterval(start: now, duration: 24 * 3_600)
        var results: [GuideSearchResult] = []
        var seen: Set<String> = []
        for term in plan.genreTerms {
            for result in await epg.searchProgrammes(inCategory: term, importIDs: importIDs, overlapping: interval, limit: programmeLimit * 2)
            where country.matches(result.channel) && seen.insert(result.id).inserted {
                results.append(result)
            }
        }
        results.sort { $0.programme.start < $1.programme.start }
        return Array(results.prefix(programmeLimit))
    }
}

/// The country of a plan ("italian news"), matched against the words of a channel's name, its group and its
/// playlist ("IT | Rai 1", group "Italia", playlist "Sky Italia"). Lets everything through without a country.
struct CountryFilter {

    let terms: Set<String>
    private let playlistNames: [UUID: String]

    init(plan: SmartSearchPlan, playlists: [VisiblePlaylist]) {
        terms = plan.countryCode.map(SmartSearchRules.countryTerms(for:)) ?? []
        playlistNames = Dictionary(playlists.map { ($0.playlistID, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    func matches(name: String, group: String, playlistID: UUID) -> Bool {
        guard !terms.isEmpty else {
            return true
        }
        let words = Set(SmartSearchRules.words(name) + SmartSearchRules.words(group) + SmartSearchRules.words(playlistNames[playlistID] ?? ""))
        return !words.isDisjoint(with: terms)
    }

    func matches(_ channel: ChannelItem) -> Bool {
        matches(name: channel.displayName, group: channel.groupName, playlistID: channel.playlistID)
    }
}

/// Whole-word matching of guide programmes, for the keywords smart search adds itself.
enum GuideMatch {

    /// Whether `phrase` (lowercased words without accents) appears as consecutive whole words in the programme's
    /// title, subtitle or one of its categories. A word may end in a number ("tg" matches "TG1").
    static func containsPhrase(_ phrase: [String], in programme: GuideProgramme) -> Bool {
        guard !phrase.isEmpty else {
            return false
        }
        let fields = [programme.title, programme.subtitle] + programme.categories
        return fields.contains { field in
            let words = SmartSearchRules.words(field)
            guard words.count >= phrase.count else {
                return false
            }
            return (0...(words.count - phrase.count)).contains { start in
                zip(phrase, words[start..<(start + phrase.count)]).allSatisfy(wordMatches)
            }
        }
    }

    static func wordMatches(_ word: String, _ candidate: String) -> Bool {
        candidate == word || (candidate.hasPrefix(word) && candidate.dropFirst(word.count).allSatisfy(\.isNumber))
    }

    /// Whether a word of `name` starts with `prefix` ("cinema" in "Sky Cinema Uno", "film" in "Films" or "Film4").
    static func hasWord(startingWith prefix: String, in name: String) -> Bool {
        SmartSearchRules.words(name).contains { $0.hasPrefix(prefix) }
    }
}

// MARK: - Structured output

#if !os(tvOS)
@Generable
enum GeneratedSearchKind {
    case anything
    case liveTV
    case movies
    case series
}

@Generable
enum GeneratedSearchTime {
    case anyTime
    case now
    case tonight
    case today
    case tomorrow
}

/// The plan as the on-device model writes it.
@Generable
struct GeneratedSearchPlan {
    @Guide(description: "Up to five short keywords that appear in channel names, group names or programme titles, with synonyms and translations.", .maximumCount(5))
    var keywords: [String]
    @Guide(description: "The kind of content asked for.")
    var kind: GeneratedSearchKind
    @Guide(description: "Two-letter ISO country code when the query names a country, a nationality or a language (italian: IT), otherwise an empty string.")
    var countryCode: String
    @Guide(description: "When the viewer wants to watch.")
    var time: GeneratedSearchTime
    @Guide(description: "The channel the viewer wants something similar to, otherwise an empty string.")
    var similarTo: String
    @Guide(description: "True when the viewer looks for TV programmes, matches, films or shows on the guide rather than channels.")
    var wantsProgrammes: Bool

    /// The plan, checked against the query: the small model sometimes copies parts of the examples of its
    /// instructions, so a "similar to" channel must appear in the query, and keywords that are only filler, kind,
    /// time or country words are dropped.
    func plan(query: String) -> SmartSearchPlan {
        var plan = SmartSearchPlan()
        plan.isFromModel = true
        let queryWords = Set(SmartSearchRules.words(query))
        let similar = similarTo.trimmingCharacters(in: .whitespacesAndNewlines)
        let similarWords = SmartSearchRules.words(similar)
        if !similarWords.isEmpty, similarWords.allSatisfy(queryWords.contains) {
            plan.similarTo = similar
        }
        let excluded = Set(plan.similarTo == nil ? [] : similarWords)
        var seen: Set<String> = []
        plan.keywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { keyword in
                let words = SmartSearchRules.words(keyword)
                // A competition named with a kind word ("Serie A") stays, though both its words are cue words.
                let isOnlyCues = words.allSatisfy { SmartSearchRules.isCueWord($0) || excluded.contains($0) }
                return !keyword.isEmpty && keyword.count <= 40 && !words.isEmpty
                    && (!isOnlyCues || !SmartSearchRules.contentPhrases(in: words).isEmpty)
                    && seen.insert(keyword.lowercased()).inserted
            }
        switch kind {
        case .anything:
            plan.kind = .any
        case .liveTV:
            plan.kind = .live
        case .movies:
            plan.kind = .movies
        case .series:
            plan.kind = .series
        }
        let code = countryCode.trimmingCharacters(in: .whitespaces).uppercased()
        plan.countryCode = code.count == 2 && code.allSatisfy(\.isLetter) ? code : nil
        switch time {
        case .anyTime:
            plan.time = .any
        case .now:
            plan.time = .now
        case .tonight:
            plan.time = .tonight
        case .today:
            plan.time = .today
        case .tomorrow:
            plan.time = .tomorrow
        }
        plan.wantsProgrammes = wantsProgrammes
        return plan
    }
}
#endif
