//
//  FeaturedPicker.swift
//  Fluxo
//
//  How the featured billboard (and the Apple TV hero) chooses its pages: a few different things, never a run of
//  similar ones.
//
//  - Categories, not a window of the playlist: providers list related entries together (a category of a dozen
//    "Fast & Furious" films, "Sky Sport 1…10"), so consecutive entries look alike. The picker takes at most one
//    entry per category, alternates movies, series and live channels, spreads the pages over the playlists and over
//    the provider sections of the category names ("IT | …", "UK | …"), and prefers entries with real artwork.
//  - One page per title and per franchise: the same film in another quality or language ("Avatar (2009) [ITA]",
//    "Avatar 4K"), the episodes of a series and the films of a franchise ("Toy Story", "Toy Story 3") count once
//    (`FeaturedTitle`).
//  - Personal but varied: the categories the viewer watches and the kinds they watch most weigh more in a weighted
//    random draw, so they come up more often without taking over; what Continue Watching already shows is left out.
//  - Seeded: the same seed gives the same pages, so the billboard does not change while it is on screen.
//    `FeaturedRotation` chooses a new seed every few hours, every day and on pull to refresh.
//  - Adult content is left out unless the scope has nothing else (`MatureContentFilter`).
//
//  Pure: the store is read through the `fetch` closure (`FeaturedLoader`), so Tools/FeaturedCheck runs it on
//  synthetic data.
//

import Foundation

/// A deterministic random generator (SplitMix64): the picks of a seed are the same on every launch and device.
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// A value in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// A stable 64-bit hash of a string (FNV-1a), the same in every process (unlike `Hasher`).
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// Comparison keys of a title, for telling apart things that are really different.
enum FeaturedTitle {

    struct Keys: Hashable, Sendable {
        /// The same title, whatever its quality, language, year or edition tags: "avatar".
        let duplicate: String
        /// The franchise or brand: the first two significant words without sequel numbers ("toy story",
        /// "harry potter", "sky sport"), or the network of numbered channels ("rai", "france").
        let franchise: String
    }

    static func keys(of item: ChannelItem) -> Keys {
        keys(title: item.series?.seriesTitle ?? item.name ?? "", kind: item.kind)
    }

    static func keys(title: String, kind: ChannelContentKind) -> Keys {
        let tokens = ChannelNameNormalizer.tokens(kind == .live ? title : keepingTitlePrefix(title))
        var base: [String] = []
        for (index, token) in tokens.enumerated() {
            // A language tag after the title ("ITA", "MULTI", "SUB ITA"); a first word is part of it ("It").
            if index > 0, languageTags.contains(token) {
                continue
            }
            if editionWords.contains(token) || (kind != .live && isYear(token)) {
                continue
            }
            base.append(token)
        }
        if base.isEmpty {
            base = tokens
        }
        // "The Matrix" and "Matrix" are one title.
        if base.count > 1, leadingArticles.contains(base[0]) {
            base.removeFirst()
        }
        let duplicate = base.joined(separator: " ")
        var significant = base.filter { !stopWords.contains($0) && !isSequelMarker($0) }
        if significant.isEmpty {
            significant = base
        }
        let franchise: [String]
        if kind == .live, significant.count >= 2, isNumberWord(significant[1]) {
            // "Rai 1", "Rai 2", "France 3", "BBC One": the same network.
            franchise = [significant[0]]
        } else {
            franchise = Array(significant.prefix(2))
        }
        return Keys(duplicate: duplicate.isEmpty ? title.lowercased() : duplicate, franchise: franchise.joined(separator: " "))
    }

    /// `ChannelNameNormalizer` drops a short word before a colon, a bar or a hyphen as a provider prefix ("IT: Rai 1").
    /// In a film's title it is often the title itself ("Dune: Part Two", "Thor: Ragnarok", "X-Men"): only language,
    /// country and provider codes are prefixes there.
    private static func keepingTitlePrefix(_ title: String) -> String {
        guard let separator = title.firstIndex(where: { $0 == ":" || $0 == "|" || $0 == "-" }) else {
            return title
        }
        let prefix = title[..<separator].trimmingCharacters(in: CharacterSet(charactersIn: " []()|")).lowercased()
        if languageTags.contains(prefix) || providerPrefixes.contains(prefix) {
            return title
        }
        var kept = title
        kept.replaceSubrange(separator...separator, with: " ")
        return kept
    }

    private static func isYear(_ token: String) -> Bool {
        token.count == 4 && token.allSatisfy(\.isNumber) && (token.hasPrefix("19") || token.hasPrefix("20"))
    }

    /// "2", "3", "II", "IV", "Part", "Chapter": what tells the films of a franchise apart.
    private static func isSequelMarker(_ token: String) -> Bool {
        if token.allSatisfy(\.isNumber) {
            return token.count <= 2
        }
        return romanNumerals.contains(token) || sequelWords.contains(token)
    }

    /// "Part Two", "Capitolo 2", "Teil drei": what follows a franchise's name.
    private static let sequelWords: Set<String> = [
        "part", "parte", "partie", "teil", "chapter", "capitolo", "capitulo", "chapitre", "kapitel", "vol", "volume", "episode",
        "two", "three", "four", "five", "due", "tre", "quattro", "dos", "tres", "deux", "trois", "zwei", "drei",
    ]

    private static let providerPrefixes: Set<String> = [
        "uk", "us", "ca", "au", "ie", "vod", "nf", "nfx", "amz", "dsnp", "hbo", "atv", "apl", "4k", "uhd", "fhd", "hd", "sd",
    ]

    private static func isNumberWord(_ token: String) -> Bool {
        token.allSatisfy(\.isNumber) || numberWords.contains(token)
    }

    private static let romanNumerals: Set<String> = ["ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"]
    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "uno", "due", "tre", "dos", "tres", "un", "deux", "trois", "eins", "zwei", "drei",
    ]

    /// Language and audio tags providers add to titles.
    private static let languageTags: Set<String> = [
        "ita", "eng", "esp", "spa", "fra", "fre", "ger", "deu", "rus", "por", "pol", "tur", "ara", "hin", "jpn", "kor",
        "chi", "lat", "latino", "castellano", "dual", "multi", "multisub", "sub", "subs", "subbed", "subita", "subeng",
        "vostfr", "vost", "vose", "vo", "vf", "vff", "truefrench", "french", "dubbed", "dub", "doppiato", "it", "en",
        "fr", "de", "es", "pt", "br", "nl", "pl", "tr", "ar", "ru",
    ]

    /// Edition and source tags ("Extended", "Director's Cut", "Remastered", "WEB-DL").
    private static let editionWords: Set<String> = [
        "extended", "directors", "director", "cut", "remastered", "remaster", "uncut", "unrated", "imax", "3d",
        "theatrical", "edition", "version", "special", "dolby", "vision", "dv", "atmos", "web", "webrip", "webdl",
        "dl", "bluray", "bdrip", "brrip", "dvdrip", "hdrip", "dvd", "cam", "hdtv", "proper", "repack",
    ]

    private static let leadingArticles: Set<String> = ["the", "a", "an", "il", "lo", "la", "le", "les", "l", "el", "los", "las", "der", "die", "das"]

    private static let stopWords: Set<String> = [
        "the", "a", "an", "of", "and", "in", "on", "at", "to", "for", "with", "from", "who", "il", "lo", "la", "le", "les",
        "l", "el", "los", "las", "der", "die", "das", "den", "dem", "des", "un", "une", "una", "de", "di", "da", "del",
        "della", "du", "o", "os", "e", "y", "et", "und",
    ]
}

/// Chooses the featured pages. Feed it the categories of the scope, then ask `pick`.
struct FeaturedPicker {

    /// A category of the scope.
    struct Category: Hashable, Sendable {
        let importID: UUID
        let playlistID: UUID
        let name: String
        let kind: ChannelContentKind
        /// Entries listed in it (a series counts once).
        let entryCount: Int

        var key: String {
            "\(playlistID.uuidString)|\(name)"
        }

        /// The provider section of the name: "it" for "IT | Movies", "vod" for "VOD - Action"; the whole first
        /// word otherwise. Pages of different sections come first.
        var section: String {
            let separators = CharacterSet(charactersIn: "|:-»•/")
            let head = name.components(separatedBy: separators).first?.trimmingCharacters(in: .whitespaces) ?? name
            let word = head.split(separator: " ").first.map(String.init) ?? head
            return "\(playlistID.uuidString)|\(word.lowercased())"
        }
    }

    /// What the viewer watches.
    struct Taste: Sendable {
        /// Weight of each category the viewer watches (`Category.key`), relative to the heaviest (0...1).
        var categoryWeights: [String: Double] = [:]
        /// Share of each kind in what the viewer watches (0...1).
        var kindWeights: [ChannelContentKind: Double] = [:]
        /// Bookmark keys (entries and series) that Continue Watching shows: not featured.
        var excludedKeys: Set<String> = []

        static let none = Taste()

        init(categoryWeights: [String: Double] = [:], kindWeights: [ChannelContentKind: Double] = [:], excludedKeys: Set<String> = []) {
            self.categoryWeights = categoryWeights
            self.kindWeights = kindWeights
            self.excludedKeys = excludedKeys
        }

        init(_ profile: TasteProfile, continueWatching: Int) {
            let top = profile.groups.first?.weight ?? 0
            if top > 0 {
                for group in profile.groups {
                    categoryWeights["\(group.playlistID.uuidString)|\(group.groupName)"] = group.weight / top
                }
            }
            let total = profile.groups.reduce(0) { $0 + $1.weight }
            if total > 0 {
                for group in profile.groups {
                    kindWeights[group.kind, default: 0] += group.weight / total
                }
            }
            for entry in profile.history.prefix(continueWatching) {
                if let key = entry.item.bookmarkKey {
                    excludedKeys.insert(key)
                }
                if let key = entry.item.seriesBookmarkKey {
                    excludedKeys.insert(key)
                }
                // Its other copies too ("IT | Sky Sport F1 FHD" for "Sky Sport F1").
                excludedKeys.insert(FeaturedPicker.titleKey(of: entry.item))
            }
        }
    }

    /// Pages per kind for 8 pages, before the taste: posters first, as the billboard was designed for them.
    static let baseKindWeights: [ChannelContentKind: Double] = [.movie: 3, .series: 3, .live: 2]
    /// Entries read per category (a window at a seeded offset).
    static let window = 6
    /// Categories tried at most, so a scope of categories without artwork does not read the whole store.
    static let maximumAttempts = 48

    let count: Int
    let filter: MatureContentFilter
    let taste: Taste
    private var generator: SeededGenerator
    /// The categories of each kind, in the order they are tried.
    private var queues: [ChannelContentKind: [Category]] = [:]
    private var slots: [ChannelContentKind] = []

    private var picks: [ChannelItem] = []
    private var seenKeys: Set<String> = []
    private var usedSections: [String: Int] = [:]
    private var usedPlaylists: [UUID: Int] = [:]

    init(categories: [Category], count: Int, seed: UInt64, filter: MatureContentFilter, taste: Taste = .none) {
        self.count = count
        self.filter = filter
        self.taste = taste
        generator = SeededGenerator(seed: seed)
        let usable = categories.filter { $0.entryCount > 0 && filter.allows(group: $0.name) }
        for kind in ChannelContentKind.allCases {
            let ofKind = usable.filter { $0.kind == kind }
            guard !ofKind.isEmpty else {
                continue
            }
            queues[kind] = drawOrder(ofKind)
        }
        slots = Self.slots(kinds: Set(queues.keys), taste: taste, count: count, generator: &generator)
    }

    /// The pages: one entry per category, `fetch(category, offset, limit)` reading the entries of a category with
    /// artwork (or a series) from the store, in playlist order. Entries it returns without artwork are skipped.
    mutating func pick(fetch: (Category, Int, Int) -> [ChannelItem]) -> [ChannelItem] {
        var attempts = 0
        var slotIndex = 0
        while picks.count < count, attempts < Self.maximumAttempts, !queues.values.allSatisfy(\.isEmpty) {
            // The kind of this page; a kind whose categories ran out passes its pages on.
            let wanted = slotIndex < slots.count ? slots[slotIndex] : nil
            let kind = wanted.flatMap { queues[$0]?.isEmpty == false ? $0 : nil } ?? nextKindWithCategories()
            guard let kind, let category = nextCategory(of: kind) else {
                break
            }
            attempts += 1
            let offset = category.entryCount > Self.window ? Int(generator.next() % UInt64(category.entryCount - Self.window + 1)) : 0
            var entries = fetch(category, offset, Self.window)
            if entries.isEmpty, offset > 0 {
                entries = fetch(category, 0, Self.window)
            }
            if let entry = best(of: entries) {
                accept(entry, from: category)
                slotIndex += 1
            }
        }
        return picks
    }

    /// Whether an entry may be featured next to the picks so far.
    func isAcceptable(_ item: ChannelItem) -> Bool {
        guard item.url != nil, item.logo != nil, filter.allows(item) else {
            return false
        }
        if let key = item.bookmarkKey, taste.excludedKeys.contains(key) {
            return false
        }
        if let key = item.seriesBookmarkKey, taste.excludedKeys.contains(key) {
            return false
        }
        if taste.excludedKeys.contains(Self.titleKey(of: item)) {
            return false
        }
        return !Self.identityKeys(of: item).contains { seenKeys.contains($0) }
    }

    /// What makes two pages the same: the series, the title in any quality or language, the franchise.
    static func identityKeys(of item: ChannelItem) -> [String] {
        let keys = FeaturedTitle.keys(of: item)
        var result = ["title|\(keys.duplicate)", "franchise|\(item.kind == .live ? "live" : "vod")|\(keys.franchise)"]
        if let series = item.seriesBookmarkKey {
            result.append("series|\(series)")
        }
        return result
    }

    /// The title in any quality, language or playlist (the first of `identityKeys`).
    static func titleKey(of item: ChannelItem) -> String {
        "title|\(FeaturedTitle.keys(of: item).duplicate)"
    }

    /// Entries that are taken anyway, to fill the pages the categories did not (`FeaturedLoader`'s fallback).
    mutating func fill(with entries: [ChannelItem]) -> [ChannelItem] {
        for entry in entries where picks.count < count && isAcceptable(entry) {
            accept(entry, from: nil)
        }
        return picks
    }

    // MARK: - Private

    private mutating func accept(_ entry: ChannelItem, from category: Category?) {
        picks.append(entry)
        seenKeys.formUnion(Self.identityKeys(of: entry))
        if let category {
            usedSections[category.section, default: 0] += 1
            usedPlaylists[category.playlistID, default: 0] += 1
        }
    }

    /// The best acceptable entry of a window: real artwork first, then a seeded choice.
    private mutating func best(of entries: [ChannelItem]) -> ChannelItem? {
        let acceptable = entries.filter(isAcceptable)
        guard !acceptable.isEmpty else {
            return nil
        }
        let scored = acceptable.map { ($0, Self.artworkScore($0.logo) + generator.unit() * 0.5) }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// Artwork that is likely a real image scores higher than a placeholder or an inline image.
    static func artworkScore(_ logo: String?) -> Double {
        guard let logo else {
            return 0
        }
        let lowered = logo.lowercased()
        if lowered.hasPrefix("data:") {
            return lowered.count > 512 ? 1 : 0.2
        }
        let placeholders = ["noimage", "no_image", "no-image", "placeholder", "default.", "blank.", "nopicture", "no_poster", "noposter"]
        if placeholders.contains(where: lowered.contains) {
            return 0.2
        }
        return 1
    }

    /// The next category of a kind: one of a playlist and a provider section not used yet when there is one, among
    /// the next few of the draw.
    private mutating func nextCategory(of kind: ChannelContentKind) -> Category? {
        guard var queue = queues[kind], !queue.isEmpty else {
            return nil
        }
        let lookahead = queue.prefix(12)
        let fresh = lookahead.firstIndex { usedSections[$0.section] == nil && usedPlaylists[$0.playlistID] == nil }
            ?? lookahead.firstIndex { usedSections[$0.section] == nil }
            ?? lookahead.indices.min { (usedPlaylists[queue[$0].playlistID] ?? 0) < (usedPlaylists[queue[$1].playlistID] ?? 0) }
            ?? queue.startIndex
        let category = queue.remove(at: fresh)
        queues[kind] = queue
        return category
    }

    private func nextKindWithCategories() -> ChannelContentKind? {
        // The kind with the most categories left.
        queues.filter { !$0.value.isEmpty }.max { lhs, rhs in
            lhs.value.count == rhs.value.count ? lhs.key.rawValue > rhs.key.rawValue : lhs.value.count < rhs.value.count
        }?.key
    }

    /// A weighted random order (Efraimidis–Spirakis): heavier categories tend to come first.
    private mutating func drawOrder(_ categories: [Category]) -> [Category] {
        let keyed = categories.map { category -> (Category, Double) in
            let taste = taste.categoryWeights[category.key] ?? 0
            // Larger categories weigh a little more (more to discover), watched ones a lot more.
            let weight = 1 + 3 * taste + 0.15 * log(Double(max(1, category.entryCount)))
            let draw = max(generator.unit(), 1e-12)
            return (category, pow(draw, 1 / weight))
        }
        return keyed.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The kind of each page, interleaved ("movie, series, live, movie, …"), from the base weights and the taste.
    static func slots(kinds: Set<ChannelContentKind>, taste: Taste, count: Int, generator: inout SeededGenerator) -> [ChannelContentKind] {
        guard !kinds.isEmpty else {
            return []
        }
        var weights: [ChannelContentKind: Double] = [:]
        for kind in kinds {
            weights[kind] = (baseKindWeights[kind] ?? 1) * (1 + 1.5 * (taste.kindWeights[kind] ?? 0))
        }
        // Largest remainder: every kind gets a page when there are enough pages.
        let total = weights.values.reduce(0, +)
        var quotas: [ChannelContentKind: Int] = [:]
        for kind in kinds {
            quotas[kind] = count >= kinds.count ? 1 : 0
        }
        var remaining = count - quotas.values.reduce(0, +)
        let shares = kinds.map { kind in (kind, Double(remaining) * (weights[kind] ?? 0) / total) }
        for (kind, share) in shares {
            quotas[kind, default: 0] += Int(share)
        }
        remaining = count - quotas.values.reduce(0, +)
        for (kind, _) in shares.sorted(by: { ($0.1 - Double(Int($0.1))) > ($1.1 - Double(Int($1.1))) }).prefix(remaining) {
            quotas[kind, default: 0] += 1
        }
        // Interleave: each page goes to the kind furthest behind its share; the first kind is drawn by weight.
        var placed: [ChannelContentKind: Int] = [:]
        var result: [ChannelContentKind] = []
        let order = ChannelContentKind.allCases.filter(kinds.contains)
        var first: ChannelContentKind?
        var draw = generator.unit() * total
        for kind in order {
            draw -= weights[kind] ?? 0
            if draw <= 0 {
                first = kind
                break
            }
        }
        if let first {
            result.append(first)
            placed[first] = 1
        }
        while result.count < count {
            let next = order
                .filter { (placed[$0] ?? 0) < (quotas[$0] ?? 0) }
                .min { lhs, rhs in
                    let left = Double(placed[lhs] ?? 0) / Double(max(1, quotas[lhs] ?? 0))
                    let right = Double(placed[rhs] ?? 0) / Double(max(1, quotas[rhs] ?? 0))
                    return left == right ? (result.last == rhs) : left < right
                }
            guard let next else {
                break
            }
            result.append(next)
            placed[next, default: 0] += 1
        }
        return result
    }
}
