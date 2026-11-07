//
//  MatureContent.swift
//  Fluxo
//
//  Adult ("particular") content in the user's playlists: a classifier for channel, movie, series and category
//  names, and the filter that keeps it out of what Fluxo puts forward on its own (Featured, For You, Because You
//  Watched, On Now, For You Tonight, the Apple TV Top Shelf) while Settings › Recommendations › "Hide adult content
//  from recommendations" is on (the default). Search, the categories and the user's own lists (Favorites, Continue
//  Watching, Recently Watched) still show everything: what the user looks for or keeps is never hidden.
//
//  A scope (the playlists Home shows) with nothing but adult content is not filtered: it would leave the screens
//  empty for a choice the user made by adding such a playlist (`MatureContentFilter.forScope`).
//
//  M3U has no standard adult flag. Some panels write attributes such as `adult="1"` or `censored="1"`, but they are
//  rare next to the names, which carry the information in practice ("XXX", "18+", "Adult", "For Adults", the brands
//  of adult networks), so the classifier reads names only. Storing the attributes would need a new version of the
//  library schema (see `FluxoSchema`) for a signal the names already give.
//

import Foundation
import os
import SwiftData

/// The classifier. Names are folded (case, diacritics, width, compatibility characters) and split into words, and
/// only whole words and word sequences match, so "Essex", "Sussex" or "Pornic" never do. Pure and thread-safe.
enum MatureContent {

    /// `UserDefaults.fluxo` key of the setting (on by default); synced with iCloud (`LibrarySyncStore`).
    static let hidesAdultContentKey = "recommendations.hidesAdultContent"
    static let hidesAdultContentByDefault = true

    /// The user's setting.
    static var hidesAdultContent: Bool {
        UserDefaults.fluxo.object(forKey: hidesAdultContentKey) as? Bool ?? hidesAdultContentByDefault
    }

    // MARK: - Classification

    /// Whether a category is for adults ("XXX", "Adult", "18+", "VOD | Adulti", "Erotik", "Для взрослых").
    static func isAdult(group: String) -> Bool {
        guard !group.isEmpty else {
            return false
        }
        let words = Words(group)
        return words.matchesAdultTerms(kind: nil) || words.isAdultCategoryOnlyName
    }

    /// Whether the name of a channel, movie or series says it is adult content. `kind` resolves a few names that are
    /// adult content as a channel but not as a film ("xXx", the 2002 film).
    static func isAdult(title: String, kind: ChannelContentKind? = nil) -> Bool {
        guard !title.isEmpty else {
            return false
        }
        return Words(title).matchesAdultTerms(kind: kind)
    }

    /// An entry of a playlist: its category, its name and, for an episode, its series' title.
    static func isAdult(_ item: ChannelItem) -> Bool {
        if isAdult(group: item.groupName) {
            return true
        }
        if let series = item.series, isAdult(title: series.seriesTitle, kind: .series) {
            return true
        }
        return isAdult(title: item.name ?? "", kind: item.kind)
    }

    static func isAdult(_ series: SeriesItem) -> Bool {
        isAdult(group: series.groupName) || isAdult(title: series.title, kind: .series)
    }

    /// A programme of the TV guide: its title and its categories (XMLTV `<category>`, "Adult", "Erotic").
    static func isAdult(programmeTitle: String, categories: [String]) -> Bool {
        isAdult(title: programmeTitle) || categories.contains { isAdult(group: $0) }
    }

    // MARK: - Terms

    /// Words that are adult content wherever they appear (folded: lowercase, no diacritics).
    private static let adultWords: Set<String> = [
        "porn", "porno", "pornos", "porns", "pornstar", "pornstars", "pornography", "pornographic", "pornografia",
        "pornografico", "pornographie", "pornografie", "pornografi", "pornhub", "youporn", "xvideos", "xhamster",
        "hentai", "nsfw", "milf", "milfs", "brazzers", "babestation", "redlight", "dorcel", "onlyfans", "r18",
        "erotic", "erotica", "erotico", "eroticos", "eroticas", "erotici", "erotique", "erotiques", "erotik", "erotika",
        "erotiek", "erotisch", "erotische", "erotyka", "erotyczne", "erotikus", "erotismo",
        // Cyrillic, Greek, Arabic, Hebrew (folded: "إباحي" → "اباحي").
        "порно", "порнуха", "эротика", "эротические", "эротическое", "эротик", "ερωτικα", "ερωτικο", "ερωτικες",
        "πορνο", "اباحي", "اباحية", "سكس", "פורנו",
    ]

    /// "Adult" and its translations: adult content, except in the names listed in `adultExceptions` ("Adult Swim").
    private static let adultMarkers: Set<String> = [
        "adult", "adults", "adulti", "adulto", "adultos", "adulta", "adultas", "adulte", "adultes", "erwachsene",
        "erwachsenen", "volwassenen", "voksne", "vuxen", "vuxna", "aikuisille", "aikuisviihde", "dorosłych", "dorosli", "doroslych",
        "yetiskin", "yetiskinler", "yetiskinlere", "felnott", "felnotteknek", "dospele", "dospelych", "ενηλικων",
        "ενηλικες", "взрослых", "взрослые", "للكبار", "למבוגרים",
    ]

    /// Words next to "adult" that make it something else: Adult Swim (cartoons), Adult Contemporary, Adult Hits and
    /// Adult Standards (radio formats), Adult Education, Adult Animation, Young Adult and New Adult (book genres),
    /// "adultos mayores" (seniors), "adulto joven" (young adult).
    private static let adultFollowingExceptions: Set<String> = [
        "swim", "contemporary", "hits", "standards", "alternative", "education", "learning", "literacy", "animation",
        "animated", "cartoon", "cartoons", "animazione", "animacion", "fiction", "ed", "mayores", "mayor", "joven",
        "jovenes", "jovem", "giovane", "giovani",
    ]
    private static let adultPrecedingExceptions: Set<String> = ["young", "new", "giovani", "jovenes"]

    /// Word sequences: brands of adult networks whose words alone are ordinary ("The Hustler", "The Penthouse").
    private static let adultPhrases: [[String]] = [
        ["x", "rated"], ["luci", "rosse"], ["nguoi", "lon"], ["playboy", "tv"], ["playboy", "+"],
        ["playboy", "plus"], ["hustler", "tv"], ["blue", "hustler"], ["penthouse", "tv"], ["penthouse", "gold"],
        ["penthouse", "passion"], ["penthouse", "quickies"], ["penthouse", "black"], ["private", "tv"],
        ["private", "spice"], ["vivid", "tv"], ["vivid", "red"], ["dusk", "tv"], ["hot", "xxl"],
    ]

    /// Channel and category names that are adult networks when they are the whole name ("Playboy HD", "Hustler TV");
    /// never a film or a series ("The Hustler", 1961).
    private static let adultWholeNames: Set<String> = ["playboy", "hustler", "penthouse"]
    /// What may come with a whole name: quality and channel words.
    private static let channelNameWords: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "tv", "channel", "live", "24", "+", "plus"]

    /// Substrings for scripts written without spaces (Japanese, Chinese, Korean, Thai).
    private static let adultFragments: [String] = [
        "アダルト", "成人向け", "成人频道", "成人頻道", "成人影片", "成人电影", "成人電影", "成人視頻", "成人视频", "色情", "情色",
        "18禁", "成人片", "성인방송", "성인영화", "성인채널", "19금", "หนังผู้ใหญ่", "หนังโป๊",
    ]

    /// Words that precede "XXX" as a Roman numeral (Super Bowl XXX, WrestleMania XXX) and follow it in the film's
    /// titles (xXx: Return of Xander Cage, xXx: State of the Union).
    private static let romanNumeralContext: Set<String> = [
        "bowl", "wrestlemania", "olympiad", "olympics", "games", "part", "chapter", "vol", "volume", "edition",
        "edizione", "episode", "giochi", "festival", "anniversary", "century", "secolo", "siglo",
    ]
    private static let xxxFilmFollowers: Set<String> = ["return", "state", "xander", "reactivated"]
    /// What may follow "xxx" in one word ("XXXHD", "xxx24"): a quality or a number, not a name ("XXXTentacion").
    private static let xxxSuffixes: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "tv", "plus", "vod", "live", "channel", "movies"]

    /// Categories named only "Sex", "Sexy" or "Sexo" (with generic words such as Movies or TV) are adult; a title with
    /// the word is not ("Sex Education", "Sex and the City").
    private static let categoryOnlyWords: Set<String> = ["sex", "sexy", "sexo", "секс", "seks", "sesso"]
    private static let genericCategoryWords: Set<String> = [
        "movies", "movie", "films", "film", "videos", "video", "channels", "channel", "tv", "live", "vod", "clips",
        "cams", "cam", "hot", "and", "the", "24", "7", "hd", "4k", "+", "canali", "canales", "peliculas", "filme", "filmes",
    ]

    // MARK: - Words

    /// A name folded and split into words: letters and digits, with "+" as a word of its own ("18+", "+18").
    private struct Words {
        let folded: String
        let words: [String]

        init(_ text: String) {
            folded = text.precomposedStringWithCompatibilityMapping
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            var words: [String] = []
            var current = ""
            for character in folded {
                if character.isLetter || character.isNumber {
                    current.append(character)
                } else {
                    if !current.isEmpty {
                        words.append(current)
                        current = ""
                    }
                    if character == "+" {
                        words.append("+")
                    }
                }
            }
            if !current.isEmpty {
                words.append(current)
            }
            self.words = words
        }

        func matchesAdultTerms(kind: ChannelContentKind?) -> Bool {
            for (index, word) in words.enumerated() {
                if MatureContent.adultWords.contains(word) {
                    return true
                }
                if MatureContent.adultMarkers.contains(word), !isAdultException(at: index) {
                    return true
                }
                if isXXX(word), !isXXXException(at: index, kind: kind) {
                    return true
                }
            }
            if containsPhrase() || (words.contains("+") && hasAgeMarker()) {
                return true
            }
            if kind == nil || kind == .live {
                let significant = words.filter { !MatureContent.channelNameWords.contains($0) && $0.count > 2 }
                if significant.count == 1, MatureContent.adultWholeNames.contains(significant[0]) {
                    return true
                }
            }
            // Scripts without spaces only (Thai, Japanese, Chinese, Korean: U+0E00 and up).
            guard folded.unicodeScalars.contains(where: { $0.value >= 0x0E00 }) else {
                return false
            }
            return MatureContent.adultFragments.contains { folded.contains($0) }
        }

        /// A category named only "Sex" (and generic words, or a two-letter provider prefix such as "IT").
        var isAdultCategoryOnlyName: Bool {
            guard words.contains(where: MatureContent.categoryOnlyWords.contains) else {
                return false
            }
            return words.allSatisfy { word in
                MatureContent.categoryOnlyWords.contains(word) || MatureContent.genericCategoryWords.contains(word) || word.count <= 2
            }
        }

        private func isAdultException(at index: Int) -> Bool {
            if index + 1 < words.count, MatureContent.adultFollowingExceptions.contains(words[index + 1]) {
                return true
            }
            return index > 0 && MatureContent.adultPrecedingExceptions.contains(words[index - 1])
        }

        private func isXXX(_ word: String) -> Bool {
            guard word.hasPrefix("xxx") else {
                return false
            }
            let rest = word.dropFirst(3)
            return rest.isEmpty || rest.allSatisfy(\.isNumber) || MatureContent.xxxSuffixes.contains(String(rest))
        }

        private func isXXXException(at index: Int, kind: ChannelContentKind?) -> Bool {
            if index > 0, MatureContent.romanNumeralContext.contains(words[index - 1]) {
                return true
            }
            if index + 1 < words.count, MatureContent.xxxFilmFollowers.contains(words[index + 1]) {
                return true
            }
            // "xXx (2002)" in a movie category is the film.
            if kind == .movie {
                let rest = words.enumerated().filter { $0.offset != index && !Self.isYear($0.element) }
                return rest.isEmpty
            }
            return false
        }

        /// "18+", "18 +", "+18", "(+18)", "21+", but not "Canal+ 18" (a plus that ends a word) or "118+".
        private func hasAgeMarker() -> Bool {
            let characters = Array(folded)
            func isAgeNumber(_ digits: [Character]) -> Bool {
                digits == ["1", "8"] || digits == ["2", "1"]
            }
            for index in characters.indices where characters[index] == "+" {
                // A number before the plus: "18+", "18 +".
                var end = index
                while end > 0, characters[end - 1] == " " {
                    end -= 1
                }
                var start = end
                while start > 0, characters[start - 1].isNumber {
                    start -= 1
                }
                if isAgeNumber(Array(characters[start..<end])), start == 0 || !characters[start - 1].isLetter {
                    return true
                }
                // A number after a plus that starts a word: "+18", "(+18)".
                if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber || characters[index - 1] == "+" {
                    continue
                }
                var digitsStart = index + 1
                while digitsStart < characters.count, characters[digitsStart] == " " {
                    digitsStart += 1
                }
                var digitsEnd = digitsStart
                while digitsEnd < characters.count, characters[digitsEnd].isNumber {
                    digitsEnd += 1
                }
                if isAgeNumber(Array(characters[digitsStart..<digitsEnd])) {
                    return true
                }
            }
            return false
        }

        private func containsPhrase() -> Bool {
            for phrase in MatureContent.adultPhrases where phrase.count <= words.count {
                for start in 0...(words.count - phrase.count) where words[start] == phrase[0] {
                    if Array(words[start..<(start + phrase.count)]) == phrase {
                        return true
                    }
                }
            }
            return false
        }

        static func isYear(_ word: String) -> Bool {
            word.count == 4 && word.allSatisfy(\.isNumber) && (word.hasPrefix("19") || word.hasPrefix("20"))
        }
    }
}

/// Whether the surfaces that put content forward leave adult content out, for one scope. A value: compute it once
/// for a load and pass it along.
struct MatureContentFilter: Hashable, Sendable {

    /// False: everything is allowed (the setting is off, or the scope has nothing else).
    let isActive: Bool

    static let inactive = MatureContentFilter(isActive: false)

    func allows(_ item: ChannelItem) -> Bool {
        !isActive || !MatureContent.isAdult(item)
    }

    func allows(_ series: SeriesItem) -> Bool {
        !isActive || !MatureContent.isAdult(series)
    }

    func allows(group: String) -> Bool {
        !isActive || !MatureContent.isAdult(group: group)
    }

    func allows(programme: GuideProgramme, on channel: ChannelItem) -> Bool {
        !isActive || !(MatureContent.isAdult(channel) || MatureContent.isAdult(programmeTitle: programme.title, categories: programme.categories))
    }

    /// The filter for the playlists of `importIDs`: active when the setting is on, unless every category of the scope
    /// is for adults (then there is nothing else to show). Reads the store on the caller's thread (a few rows: it stops
    /// at the first category that is not for adults) and remembers the answer per scope, so it is cheap to call often.
    static func forScope(importIDs: [UUID], container: ModelContainer, hidesAdultContent: Bool = MatureContent.hidesAdultContent) -> MatureContentFilter {
        guard hidesAdultContent, !importIDs.isEmpty else {
            return .inactive
        }
        return MatureContentFilter(isActive: !scopeHasOnlyAdultContent(importIDs: importIDs, container: container))
    }

    /// Imports are immutable (a refresh writes a new import), so the answer for a set of imports never changes.
    private static let onlyAdultByScope = OSAllocatedUnfairLock(initialState: [Set<UUID>: Bool]())

    static func scopeHasOnlyAdultContent(importIDs: [UUID], container: ModelContainer) -> Bool {
        let key = Set(importIDs)
        if let known = onlyAdultByScope.withLock({ $0[key] }) {
            return known
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<PlaylistChannelGroup>(
            predicate: #Predicate { importIDs.contains($0.importID) },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.propertiesToFetch = [\.name]
        descriptor.fetchLimit = 64
        var sawGroup = false
        var onlyAdult = true
        var offset = 0
        while onlyAdult {
            descriptor.fetchOffset = offset
            guard let groups = try? context.fetch(descriptor), !groups.isEmpty else {
                break
            }
            sawGroup = true
            if groups.contains(where: { !MatureContent.isAdult(group: $0.name) }) {
                onlyAdult = false
            }
            offset += groups.count
        }
        let answer = sawGroup && onlyAdult
        onlyAdultByScope.withLock { cache in
            if cache.count > 32 {
                cache.removeAll()
            }
            cache[key] = answer
        }
        return answer
    }
}
