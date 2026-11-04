//
//  EpisodeParser.swift
//  Fluxo
//
//  Reads the series, season and episode out of the name of an on-demand playlist entry. M3U has no field for
//  them: providers write them into the title in many ways ("Breaking Bad S01 E01", "Dark Staffel 1 Folge 2",
//  "Lupin 1x03", "IT: Gomorra S01E01 [MULTI] FHD", "Naruto Ep. 3"), so the parser looks for an episode marker,
//  then cleans the text before it into the series title and the text after it into the episode title.
//
//  It runs for every on-demand entry of an import (about 1 µs per name): the scan works on an array of
//  scalars with a lowercase, accent-free copy, without regular expressions or `String` slicing until a marker
//  is found. `Tools/SeriesCheck` checks it against a broad list of real-world names.
//

import Foundation

/// What the name of an on-demand entry says about the series it belongs to.
struct EpisodeInfo: Hashable, Sendable {

    /// How sure the parser is that the name is an episode.
    enum Strength: Int, Comparable, Sendable {
        /// An episode number only ("Ep. 3", "Episode 12", "Folge 5", "E05"): trusted only for entries that are
        /// already known to be series (their URL or their category says so), never to turn a movie into a series.
        case weak
        /// A season and an episode ("S01E02", "s1 e2", "1x02", "Season 1 Episode 2", "Stagione 1 Episodio 2").
        case strong

        static func < (lhs: Strength, rhs: Strength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The series title for display ("Breaking Bad"), without provider prefixes, quality tags or a year.
    var seriesTitle: String
    /// Identifies the series within a playlist: the folded title, plus the year when the name has one
    /// ("doctor who|2005"), so two series with the same title stay apart.
    var seriesKey: String
    var year: Int?
    /// nil when the name gives an episode number only.
    var season: Int?
    var episode: Int
    /// "Pilot", "Chapter Five"; nil when the name has nothing but tags after the marker.
    var episodeTitle: String?
    var strength: Strength

    /// The season used to sort and group episodes: names without a season are season 1.
    var seasonOrDefault: Int {
        season ?? 1
    }
}

enum EpisodeParser {

    /// Bumped whenever parsing changes in a way that matters for stored data: libraries indexed with an older
    /// version are indexed again at launch (`SeriesIndexer`).
    /// 2: split episodes ("S01E01a").
    static let version = 2

    /// Parses `name`. `groupName` is used as the series title when the name has none ("S01 E01 - Pilot" in a
    /// "Series | Breaking Bad" category). Weak markers ("Ep. 3") are only read when `allowsWeakMarkers`.
    static func parse(_ name: String?, groupName: String = "", allowsWeakMarkers: Bool = true) -> EpisodeInfo? {
        var session = Session()
        return session.parse(name, groupName: groupName, allowsWeakMarkers: allowsWeakMarkers)
    }

    /// Whether `name` has a season-and-episode marker (used to classify on-demand entries as series).
    static func hasStrongMarker(_ name: String) -> Bool {
        let text = ScannedText(name)
        return text.findMarker(allowsWeak: false) != nil
    }

    /// Parses many names (an import), caching the folded keys of the series titles it has already seen.
    struct Session {
        private var keyCache: [String: String] = [:]
        private var groupTitleCache: [String: String?] = [:]
        /// Episodes of a series share the text before their marker: it is cleaned once.
        private var titleCache: [String: (title: String, year: Int?)] = [:]

        init() {}

        mutating func parse(_ name: String?, groupName: String = "", allowsWeakMarkers: Bool = true) -> EpisodeInfo? {
            scan(name, groupName: groupName, allowsWeakMarkers: allowsWeakMarkers).episode
        }

        /// Like `parse`, and whether the name has a season-and-episode marker even when it names no series
        /// ("S01E01" alone): the import classifies and parses an entry with one scan of its name.
        mutating func scan(_ name: String?, groupName: String = "", allowsWeakMarkers: Bool = true) -> (hasStrongMarker: Bool, episode: EpisodeInfo?) {
            guard let name, !name.isEmpty else {
                return (false, nil)
            }
            let text = ScannedText(name)
            guard let marker = text.findMarker(allowsWeak: allowsWeakMarkers) else {
                return (false, nil)
            }
            return (marker.strength == .strong, episode(in: text, marker: marker, groupName: groupName))
        }

        private mutating func episode(in text: ScannedText, marker: EpisodeMarker, groupName: String) -> EpisodeInfo? {
            // (Scene-style names are cleaned with dots read as spaces; they never share a cache entry with a
            // spaced name, since the raw prefix differs.)
            let prefix = text.string(in: 0..<marker.start)
            var title: String
            var year: Int?
            if let cached = titleCache[prefix] {
                (title, year) = cached
            } else {
                (title, year) = EpisodeParser.cleanSeriesTitle(prefix, sceneStyle: text.isSceneStyle)
                if titleCache.count < 50_000 {
                    titleCache[prefix] = (title, year)
                }
            }
            if title.isEmpty {
                // Nothing before the marker: the category names the series, unless it is a generic one.
                year = nil
                if let cached = groupTitleCache[groupName] {
                    title = cached ?? ""
                } else {
                    let fromGroup = EpisodeParser.seriesTitle(fromGroup: groupName)
                    groupTitleCache[groupName] = fromGroup
                    title = fromGroup ?? ""
                }
            }
            guard !title.isEmpty else {
                return nil
            }
            let keyBase: String
            if let cached = keyCache[title] {
                keyBase = cached
            } else {
                keyBase = EpisodeParser.foldedKey(title)
                keyCache[title] = keyBase
            }
            guard !keyBase.isEmpty else {
                return nil
            }
            let episodeTitle = EpisodeParser.cleanEpisodeTitle(text.string(in: marker.end..<text.count), sceneStyle: text.isSceneStyle, seriesTitle: title)
            return EpisodeInfo(
                seriesTitle: title,
                seriesKey: year.map { "\(keyBase)|\($0)" } ?? keyBase,
                year: year,
                season: marker.season,
                episode: marker.episode,
                episodeTitle: episodeTitle,
                strength: marker.strength
            )
        }
    }
}

// MARK: - Scanning

/// A marker found in a name: the scalar range it covers and what it says.
private struct EpisodeMarker {
    let start: Int
    let end: Int
    let season: Int?
    let episode: Int
    let strength: EpisodeInfo.Strength
}

/// A name as scalars, with a folded copy (lowercase, without accents) of the same length for matching.
private struct ScannedText {

    let scalars: [Unicode.Scalar]
    /// Lowercase base letters (é → e, Ö → o, С → с), digits and everything else unchanged.
    let folded: [UInt32]
    let isAlphanumeric: [Bool]
    /// "Breaking.Bad.S01E01.720p": words separated by dots or underscores instead of spaces.
    let isSceneStyle: Bool

    init(_ name: String) {
        let scalars = Array(name.unicodeScalars)
        self.scalars = scalars
        var folded: [UInt32] = []
        var isAlphanumeric: [Bool] = []
        folded.reserveCapacity(scalars.count)
        isAlphanumeric.reserveCapacity(scalars.count)
        var spaces = 0
        var dots = 0
        for scalar in scalars {
            let value = scalar.value
            switch value {
            case 0x30...0x39:
                folded.append(value)
                isAlphanumeric.append(true)
            case 0x41...0x5A:
                folded.append(value + 0x20)
                isAlphanumeric.append(true)
            case 0x61...0x7A:
                folded.append(value)
                isAlphanumeric.append(true)
            case 0x00...0x7F:
                if value == 0x20 {
                    spaces += 1
                } else if value == 0x2E || value == 0x5F {
                    dots += 1
                }
                folded.append(value)
                isAlphanumeric.append(false)
            default:
                folded.append(Self.fold(scalar))
                isAlphanumeric.append(scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
            }
        }
        self.folded = folded
        self.isAlphanumeric = isAlphanumeric
        isSceneStyle = spaces == 0 && dots >= 2
    }

    var count: Int {
        scalars.count
    }

    func string(in range: Range<Int>) -> String {
        guard !range.isEmpty else {
            return ""
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[range])
        return String(view)
    }

    /// Lowercase without diacritics, for the letters of the words the parser looks for.
    private static func fold(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        switch value {
        case 0x0410...0x042F:
            // Cyrillic capitals.
            return value + 0x20
        case 0x0430...0x044F:
            return value
        case 0xFF10...0xFF19:
            // Full-width digits.
            return value - 0xFF10 + 0x30
        case 0xFF21...0xFF3A:
            return value - 0xFF21 + 0x61
        case 0xFF41...0xFF5A:
            return value - 0xFF41 + 0x61
        case 0xD7:
            // ×, as in "1×05".
            return 0x78
        default:
            break
        }
        let lowered = String(scalar).lowercased().folding(options: .diacriticInsensitive, locale: nil)
        return lowered.unicodeScalars.first?.value ?? value
    }

    // MARK: Markers

    /// The first strong marker, or else (when allowed) the first weak one.
    func findMarker(allowsWeak: Bool) -> EpisodeMarker? {
        var weak: EpisodeMarker?
        var index = 0
        while index < count {
            defer {
                index += 1
            }
            guard isAlphanumeric[index], index == 0 || !isAlphanumeric[index - 1] else {
                continue
            }
            if let marker = seasonEpisodeCode(at: index) ?? crossCode(at: index) ?? seasonWord(at: index) ?? numberedSeasonWord(at: index) {
                return marker
            }
            if allowsWeak, weak == nil {
                weak = episodeWord(at: index) ?? numberedEpisodeWord(at: index) ?? episodeCode(at: index)
            }
        }
        return weak
    }

    /// "S01E02", "s1 e2", "S01.E02", "S01 - E02", "S01xE02", "S01 Ep. 02", "S01 Episode 2", "T01E02" (Spanish
    /// temporada), "S01E01E02" / "S01E01-E02" (the first episode counts).
    private func seasonEpisodeCode(at start: Int) -> EpisodeMarker? {
        let first = folded[start]
        guard first == ascii("s") || first == ascii("t") else {
            return nil
        }
        guard let season = number(at: start + 1, maxDigits: 4) else {
            return nil
        }
        var cursor = skipping(Self.codeSeparators, from: season.end, max: 3)
        if cursor < count, folded[cursor] == ascii("x") {
            cursor = skipping(Self.codeSeparators, from: cursor + 1, max: 2)
        }
        guard let episodeStart = episodePrefix(at: cursor, allowsWords: first == ascii("s")) else {
            return nil
        }
        guard let episode = number(at: episodeStart, maxDigits: 4) else {
            return nil
        }
        let end = skippingPartLetter(from: skippingExtraEpisodes(from: episode.end))
        guard isBoundary(end) else {
            return nil
        }
        return EpisodeMarker(start: start, end: end, season: season.value, episode: episode.value, strength: .strong)
    }

    /// Skips the part letter of a split episode ("S01E01a", "S01E01b": two halves of episode 1).
    private func skippingPartLetter(from start: Int) -> Int {
        guard start < count, (ascii("a")...ascii("d")).contains(folded[start]), isBoundary(start + 1) else {
            return start
        }
        return start + 1
    }

    /// "1x02", "01x02", "1×02" (the episode has two or three digits, so "16x9" or "1920x1080" are not episodes).
    private func crossCode(at start: Int) -> EpisodeMarker? {
        guard let season = number(at: start, maxDigits: 2), season.end < count, folded[season.end] == ascii("x") else {
            return nil
        }
        guard let episode = number(at: season.end + 1, maxDigits: 3), episode.end - season.end - 1 >= 2, isBoundary(episode.end) else {
            return nil
        }
        return EpisodeMarker(start: start, end: episode.end, season: season.value, episode: episode.value, strength: .strong)
    }

    /// "Season 1 Episode 2", "Season 1, Ep. 2", "Season 1 E02", "Stagione 1 Episodio 2", "Staffel 1 Folge 2",
    /// "Temporada 1 Capítulo 2", "Saison 1 Épisode 2", "Sezon 1 Bölüm 2", "Series 2 Episode 3" (British).
    private func seasonWord(at start: Int) -> EpisodeMarker? {
        guard let wordEnd = word(at: start, in: Self.seasonWords) else {
            return nil
        }
        let numberStart = skipping(Self.wordSeparators, from: wordEnd, max: 3)
        guard numberStart > wordEnd || (numberStart < count && isDigit(numberStart)), let season = number(at: numberStart, maxDigits: 4) else {
            return nil
        }
        let next = skipping(Self.listSeparators, from: season.end, max: 4)
        guard next > season.end, let episode = episodeAfterSeason(at: next) else {
            return nil
        }
        return EpisodeMarker(start: start, end: episode.end, season: season.value, episode: episode.value, strength: .strong)
    }

    /// "2. Staffel, Folge 3", "1 сезон 2 серия", "1 сезон серия 2".
    private func numberedSeasonWord(at start: Int) -> EpisodeMarker? {
        guard let season = number(at: start, maxDigits: 3) else {
            return nil
        }
        var cursor = season.end
        if cursor < count, folded[cursor] == ascii(".") {
            cursor += 1
        }
        let wordStart = skipping(Self.spaces, from: cursor, max: 2)
        guard wordStart > cursor, let wordEnd = word(at: wordStart, in: Self.seasonWords) else {
            return nil
        }
        // "Show 2 Season 1 Episode 1": the number belongs to the title, the season word starts the marker.
        if seasonWord(at: wordStart) != nil {
            return nil
        }
        let next = skipping(Self.listSeparators, from: wordEnd, max: 4)
        guard next > wordEnd else {
            return nil
        }
        if let episode = episodeAfterSeason(at: next) {
            return EpisodeMarker(start: start, end: episode.end, season: season.value, episode: episode.value, strength: .strong)
        }
        // "1 сезон 2 серия": the number before the word.
        if let episode = number(at: next, maxDigits: 4) {
            var cursor = episode.end
            if cursor < count, folded[cursor] == ascii(".") {
                cursor += 1
            }
            let episodeWordStart = skipping(Self.spaces, from: cursor, max: 2)
            if episodeWordStart > cursor, let end = word(at: episodeWordStart, in: Self.episodeWords) {
                return EpisodeMarker(start: start, end: end, season: season.value, episode: episode.value, strength: .strong)
            }
        }
        return nil
    }

    /// "Episode 12", "Ep. 3", "Episodio 4", "Folge 5", "Odcinek 6", "Серия 7" (weak).
    private func episodeWord(at start: Int) -> EpisodeMarker? {
        guard let wordEnd = word(at: start, in: Self.episodeWords) else {
            return nil
        }
        let numberStart = skipping(Self.wordSeparators, from: wordEnd, max: 3)
        guard numberStart > wordEnd, let episode = number(at: numberStart, maxDigits: 4), isBoundary(episode.end) else {
            return nil
        }
        return EpisodeMarker(start: start, end: episode.end, season: nil, episode: episode.value, strength: .weak)
    }

    /// "5. Folge", "12 серия" (weak).
    private func numberedEpisodeWord(at start: Int) -> EpisodeMarker? {
        guard let episode = number(at: start, maxDigits: 4) else {
            return nil
        }
        var cursor = episode.end
        if cursor < count, folded[cursor] == ascii(".") {
            cursor += 1
        }
        let wordStart = skipping(Self.spaces, from: cursor, max: 2)
        guard wordStart > cursor, let end = word(at: wordStart, in: Self.episodeWords) else {
            return nil
        }
        return EpisodeMarker(start: start, end: end, season: nil, episode: episode.value, strength: .weak)
    }

    /// "E05", "Ep05", "EP 5", "Ep.5" (weak).
    private func episodeCode(at start: Int) -> EpisodeMarker? {
        guard folded[start] == ascii("e") else {
            return nil
        }
        var cursor = start + 1
        if cursor < count, folded[cursor] == ascii("p") {
            cursor += 1
        }
        cursor = skipping([ascii("."), ascii(" ")], from: cursor, max: 2)
        guard let episode = number(at: cursor, maxDigits: 4), isBoundary(episode.end) else {
            return nil
        }
        return EpisodeMarker(start: start, end: episode.end, season: nil, episode: episode.value, strength: .weak)
    }

    /// After a season: "Episode 2", "Ep. 2", "E02", "e2".
    private func episodeAfterSeason(at cursor: Int) -> (value: Int, end: Int)? {
        guard let numberStart = episodePrefix(at: cursor, allowsWords: true), let episode = number(at: numberStart, maxDigits: 4) else {
            return nil
        }
        let end = skippingExtraEpisodes(from: episode.end)
        guard isBoundary(end) else {
            return nil
        }
        return (episode.value, end)
    }

    /// Where the episode number starts after "E", "Ep", "Ep." or an episode word; nil when there is none.
    private func episodePrefix(at cursor: Int, allowsWords: Bool) -> Int? {
        guard cursor < count else {
            return nil
        }
        if allowsWords, let end = word(at: cursor, in: Self.episodeWords) {
            let next = skipping(Self.wordSeparators, from: end, max: 3)
            if next < count, isDigit(next) {
                return next
            }
        }
        guard folded[cursor] == ascii("e") else {
            return nil
        }
        var next = cursor + 1
        if next < count, folded[next] == ascii("p") {
            next += 1
        }
        next = skipping([ascii("."), ascii(" ")], from: next, max: 2)
        return next < count && isDigit(next) ? next : nil
    }

    /// Skips "E02", "-E02" and "-02" after a first episode number (double episodes).
    private func skippingExtraEpisodes(from start: Int) -> Int {
        var cursor = start
        while cursor < count {
            var next = cursor
            if folded[next] == ascii("-") {
                next += 1
            }
            if next < count, folded[next] == ascii("e") {
                next += 1
            }
            guard next > cursor, let extra = number(at: next, maxDigits: 4) else {
                break
            }
            cursor = extra.end
        }
        return cursor
    }

    // MARK: Primitives

    private func ascii(_ character: Unicode.Scalar) -> UInt32 {
        character.value
    }

    private func isDigit(_ index: Int) -> Bool {
        folded[index] >= 0x30 && folded[index] <= 0x39
    }

    /// The end of the text, or anything that is neither a letter nor a digit.
    private func isBoundary(_ index: Int) -> Bool {
        index >= count || !isAlphanumeric[index]
    }

    private func number(at start: Int, maxDigits: Int) -> (value: Int, end: Int)? {
        var cursor = start
        var value = 0
        while cursor < count, isDigit(cursor) {
            value = value * 10 + Int(folded[cursor] - 0x30)
            cursor += 1
            if cursor - start > maxDigits {
                return nil
            }
        }
        guard cursor > start else {
            return nil
        }
        // "S01E01x264" is fine, "S01E012345" is not: a number must not run on into more digits.
        return (value, cursor)
    }

    private func skipping(_ separators: [UInt32], from start: Int, max: Int) -> Int {
        var cursor = start
        while cursor < count, cursor - start < max, separators.contains(folded[cursor]) {
            cursor += 1
        }
        return cursor
    }

    /// The end of one of `words` starting at `start`, followed by a non-letter.
    private func word(at start: Int, in words: [[UInt32]]) -> Int? {
        for candidate in words where start + candidate.count <= count {
            var matches = true
            for (offset, value) in candidate.enumerated() where folded[start + offset] != value {
                matches = false
                break
            }
            guard matches else {
                continue
            }
            let end = start + candidate.count
            if end >= count || !(isAlphanumeric[end] && !isDigit(end)) {
                return end
            }
        }
        return nil
    }

    private static func folded(_ words: [String]) -> [[UInt32]] {
        // Longest first, so "episodio" is tried before "ep".
        words.sorted { $0.count > $1.count }.map { $0.unicodeScalars.map(\.value) }
    }

    private static let spaces: [UInt32] = [0x20]
    /// Between the season and the episode of a code ("S01 E02", "S01.E02", "S01_E02", "S01 - E02").
    private static let codeSeparators: [UInt32] = [0x20, 0x2E, 0x5F, 0x2D, 0x2C, 0x3A, 0x2013, 0x2014]
    /// Between a word and its number ("Season 1", "Ep. 3", "Episode: 4", "Folge #5", "Nº 6").
    private static let wordSeparators: [UInt32] = [0x20, 0x2E, 0x3A, 0x23, 0x2D, 0x5F, 0xBA, 0xB0]
    /// Between "Season 1" and "Episode 2" ("Season 1, Episode 2", "Season 1 - Episode 2", "Season 1 | Ep 2").
    private static let listSeparators: [UInt32] = [0x20, 0x2C, 0x2D, 0x3A, 0x7C, 0x2F, 0x2E, 0x5F, 0x2013, 0x2014]

    private static let seasonWords = folded([
        "season", "series", "stagione", "staffel", "temporada", "saison", "seizoen", "sezon", "sezona", "sezonul",
        "sesong", "sasong", "kausi", "сезон",
    ])

    private static let episodeWords = folded([
        "episode", "episodes", "episodio", "episodi", "epizod", "epizoda", "folge", "aflevering", "afl", "odcinek",
        "odc", "bolum", "capitulo", "cap", "puntata", "jakso", "avsnitt", "серия", "эпизод", "ep",
    ])
}

// MARK: - Cleaning

extension EpisodeParser {

    /// Tags that describe a file rather than the series: quality, codecs, sources, audio and subtitle languages.
    static let fileTags: Set<String> = [
        "hd", "fhd", "uhd", "sd", "hq", "lq", "4k", "8k", "2k", "hdr", "hdr10", "dv", "dolby", "atmos", "hevc", "h264",
        "h265", "x264", "x265", "avc", "av1", "1080p", "1080i", "720p", "2160p", "480p", "576p", "360p", "multi",
        "multisub", "multi sub", "multi-sub", "multiaudio", "dual", "dual audio", "sub", "subs", "subbed", "sub ita",
        "sub eng", "sub esp", "dub", "dubbed", "vost", "vostfr", "vosten", "vose", "vo", "vf", "vff", "vfq", "truefrench",
        "ita", "eng", "esp", "spa", "fre", "fra", "ger", "deu", "lat", "latino", "castellano", "web", "webrip", "web-dl",
        "webdl", "bluray", "bdrip", "brrip", "dvdrip", "hdtv", "hdrip", "nf", "amzn", "dsnp", "hmax", "atvp", "aac", "ac3",
        "eac3", "dd5.1", "5.1", "7.1", "10bit", "8bit", "repack", "proper", "complete",
    ]

    /// Language codes that are only a tag when written in capitals ("Show ITA", not "Bella Vita").
    private static let capitalOnlyTags: Set<String> = ["ita", "eng", "esp", "spa", "fre", "fra", "ger", "deu", "lat", "sub", "dub", "vo", "vf", "dual", "web"]

    /// Category names that say "series" without naming one.
    private static let genericGroupNames: Set<String> = [
        "series", "serie", "serie tv", "series tv", "tv series", "tv serie", "tv shows", "tv show", "shows", "show",
        "serien", "series de tv", "seriale", "seriali", "episodes", "episodi", "vod", "all", "other", "new", "latest",
        "anime", "kids", "documentaries", "documentary", "netflix", "amazon", "disney", "hbo", "apple tv",
    ]

    /// The text before the marker as a series title, and the year it gives ("Doctor Who (2005)").
    static func cleanSeriesTitle(_ raw: String, sceneStyle: Bool) -> (title: String, year: Int?) {
        var text = sceneStyle ? raw.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") : raw
        text = strippingProviderPrefix(text)
        var year: Int?
        var changed = true
        while changed {
            changed = false
            text = trimmingSeparators(text)
            if let (inner, rest) = trailingBracket(text) {
                if let value = Self.year(inner), year == nil {
                    year = value
                    text = rest
                    changed = true
                } else if isTagList(inner) {
                    text = rest
                    changed = true
                }
            } else if let (token, rest) = trailingToken(text), !trimmingSeparators(rest).isEmpty, isTag(token) {
                // A bare year stays: "Yellowstone 1923" and "Show 2019" are titles as the provider wrote them.
                text = rest
                changed = true
            }
        }
        return (collapsingSpaces(text), year)
    }

    /// The text after the marker as an episode title; nil when it is only tags, a year or the series title.
    static func cleanEpisodeTitle(_ raw: String, sceneStyle: Bool, seriesTitle: String) -> String? {
        var text = sceneStyle ? raw.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") : raw
        var changed = true
        while changed {
            changed = false
            text = trimmingSeparators(text)
            if let (inner, rest) = trailingBracket(text), Self.year(inner) != nil || isTagList(inner) || trimmingSeparators(rest).isEmpty {
                // Tags and years go; a title that is wholly in brackets ("(The Pilot)") is unwrapped.
                text = trimmingSeparators(rest).isEmpty && Self.year(inner) == nil && !isTagList(inner) ? inner : rest
                changed = true
            } else if let (token, rest) = trailingToken(text), isTag(token) || (Self.year(token) != nil && !trimmingSeparators(rest).isEmpty) {
                text = rest
                changed = true
            } else if isTag(text) || Self.year(text) != nil {
                text = ""
            }
        }
        // Leading tags too ("[MULTI] Pilot").
        while let (inner, rest) = leadingBracket(text), isTagList(inner) || Self.year(inner) != nil {
            text = trimmingSeparators(rest)
        }
        let title = collapsingSpaces(text)
        guard !title.isEmpty, foldedKey(title) != foldedKey(seriesTitle) else {
            return nil
        }
        return title
    }

    /// A series title from a category name: its last part ("Series | Breaking Bad" → "Breaking Bad"), unless
    /// that only says "series".
    static func seriesTitle(fromGroup groupName: String) -> String? {
        var text = strippingProviderPrefix(groupName)
        for separator in [" | ", "|", " : ", ": ", " - ", " – ", " / ", " » ", " > "] {
            if let range = text.range(of: separator, options: .backwards) {
                let last = String(text[range.upperBound...])
                if !trimmingSeparators(last).isEmpty {
                    text = last
                }
            }
        }
        let (title, _) = cleanSeriesTitle(text, sceneStyle: false)
        let folded = foldedKey(title)
        guard !folded.isEmpty, !genericGroupNames.contains(folded) else {
            return nil
        }
        return title
    }

    /// Case, diacritics and width folded; letters, digits and "+" kept, "&" read as "and", everything else a
    /// single space: "Love, Death & Robots" → "love death and robots".
    static func foldedKey(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "+" {
                if pendingSpace, !result.isEmpty {
                    result.append(" ")
                }
                pendingSpace = false
                result.append(scalar)
            } else if scalar == "&" {
                if !result.isEmpty {
                    result.append(contentsOf: " and".unicodeScalars)
                }
                pendingSpace = true
            } else {
                pendingSpace = true
            }
        }
        return String(result)
    }

    // MARK: Helpers

    private static let separatorCharacters = CharacterSet(charactersIn: " \t-–—:|.,_/•·~+*").union(.whitespaces)

    private static func trimmingSeparators(_ text: String) -> String {
        var result = text.trimmingCharacters(in: separatorCharacters)
        // A bracket left open by the marker ("Show (S01E01)").
        while let last = result.last, "([{【".contains(last) {
            result.removeLast()
            result = result.trimmingCharacters(in: separatorCharacters)
        }
        while let first = result.first, ")]}】".contains(first) {
            result.removeFirst()
            result = result.trimmingCharacters(in: separatorCharacters)
        }
        return result
    }

    private static func collapsingSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// "Show [MULTI]" → ("MULTI", "Show ").
    private static func trailingBracket(_ text: String) -> (inner: String, rest: String)? {
        guard let last = text.last, let opener = bracketPairs[last], let open = text.lastIndex(of: opener) else {
            return nil
        }
        let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)]).trimmingCharacters(in: .whitespaces)
        return (inner, String(text[..<open]))
    }

    private static func leadingBracket(_ text: String) -> (inner: String, rest: String)? {
        guard let first = text.first, let closer = bracketPairs.first(where: { $0.value == first })?.key,
              let close = text.dropFirst().firstIndex(of: closer) else {
            return nil
        }
        let inner = String(text[text.index(after: text.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        return (inner, String(text[text.index(after: close)...]))
    }

    private static let bracketPairs: [Character: Character] = [")": "(", "]": "[", "}": "{", "】": "【"]

    /// The last word and what is before it.
    private static func trailingToken(_ text: String) -> (token: String, rest: String)? {
        guard let space = text.lastIndex(where: { $0 == " " || $0 == "\t" }) else {
            return nil
        }
        let token = String(text[text.index(after: space)...])
        return token.isEmpty ? nil : (token, String(text[..<space]))
    }

    private static func isTag(_ token: String) -> Bool {
        let lowered = token.lowercased()
        guard fileTags.contains(lowered) else {
            return false
        }
        if capitalOnlyTags.contains(lowered) {
            return token == token.uppercased()
        }
        return true
    }

    /// "MULTI", "SUB ITA", "FHD, MULTI", "ITA-ENG": every part is a tag.
    private static func isTagList(_ text: String) -> Bool {
        if fileTags.contains(text.lowercased()) {
            return true
        }
        let parts = text.split(whereSeparator: { " ,;/+-|".contains($0) })
        return !parts.isEmpty && parts.allSatisfy { fileTags.contains($0.lowercased()) }
    }

    private static func year(_ text: String) -> Int? {
        guard text.count == 4, let value = Int(text), (1900...2099).contains(value) else {
            return nil
        }
        return value
    }

    /// "IT: Show", "|EN| Show", "[IT] Show", "EN - Show", "4K-IT: Show", "NF: Show" → "Show". Only short codes
    /// in capitals (or in brackets) count, so "Up: The Series" keeps its title.
    static func strippingProviderPrefix(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        for _ in 0..<2 {
            if let (inner, rest) = leadingBracket(result) ?? leadingPipeCode(result), isPrefixCode(inner, bracketed: true), !trimmingSeparators(rest).isEmpty {
                result = rest.trimmingCharacters(in: separatorCharacters)
                continue
            }
            // "IT: Show", "IT | Show", then "IT - Show" (a dash needs spaces: "IT-Show" is more likely a title).
            let separator = result.firstIndex { $0 == ":" || $0 == "|" } ?? result.range(of: " - ")?.lowerBound ?? result.range(of: " – ")?.lowerBound
            if let separator {
                let code = result[..<separator].trimmingCharacters(in: .whitespaces)
                let rest = String(result[result.index(after: separator)...])
                if isPrefixCode(code, bracketed: false), !trimmingSeparators(rest).isEmpty {
                    result = rest.trimmingCharacters(in: separatorCharacters)
                    continue
                }
            }
            break
        }
        return result
    }

    private static func leadingPipeCode(_ text: String) -> (inner: String, rest: String)? {
        guard text.first == "|", let close = text.dropFirst().firstIndex(of: "|") else {
            return nil
        }
        return (String(text[text.index(after: text.startIndex)..<close]).trimmingCharacters(in: .whitespaces), String(text[text.index(after: close)...]))
    }

    private static func isPrefixCode(_ code: String, bracketed: Bool) -> Bool {
        guard (2...6).contains(code.count) || (bracketed && isTagList(code)) else {
            return false
        }
        if bracketed && isTagList(code) {
            return true
        }
        let letters = code.filter { $0.isLetter }
        guard !letters.isEmpty, code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " }) else {
            return false
        }
        if bracketed {
            // Any short code: "[IT]", "(EN)", "[VOD]".
            return code.count <= 5 && !code.contains(" ")
        }
        // Otherwise a code in capitals that is a known prefix: two letters ("IT:", "NF:"), a known longer code
        // ("ITA:", "VIP:"), or a combination ("4K-IT:", "EN-US:"). "CSI: Miami" and "NCIS: Hawai'i" keep theirs.
        guard letters == letters.uppercased(), !code.contains(" ") else {
            return false
        }
        let parts = code.split(separator: "-")
        return parts.allSatisfy { part in
            part.count == 2 || longPrefixCodes.contains(String(part)) || isTagList(String(part))
        }
    }

    private static let longPrefixCodes: Set<String> = [
        "ITA", "ENG", "ESP", "SPA", "FRA", "FRE", "GER", "DEU", "POR", "PT-BR", "BRA", "NLD", "POL", "TUR", "RUS", "ARA",
        "ALB", "ROM", "HUN", "GRE", "SWE", "NOR", "DAN", "FIN", "CZE", "SRB", "CRO", "BUL", "UKR", "HIN", "JPN", "KOR",
        "CHN", "LAT", "LATAM", "VIP", "VOD", "SVOD", "EXYU", "MULTI",
    ]
}
