//
//  SmartSearchRules.swift
//  Fluxo
//
//  The rule-based query parser of smart search, used without Apple Intelligence (and to back up the model's
//  plan): time words, content kinds, countries and languages, "like …", and a few synonyms, in English and the
//  languages IPTV playlists use most. Words it does not know become keywords.
//

import Foundation

enum SmartSearchRules {

    /// Lowercased words without accents or punctuation.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber && $0 != "+" }
            .map(String.init)
    }

    static func plan(for query: String) -> SmartSearchPlan {
        var plan = SmartSearchPlan()
        var words = words(query)

        // "something like Sky Sport F1", "similar to Rai 1", "come Rai 1".
        for marker in [["similar", "to"], ["like"], ["simile", "a"], ["come"], ["wie"], ["comme"], ["como"]] {
            if let range = words.firstRange(of: marker), range.upperBound < words.count {
                let original = query.split(separator: " ").map(String.init)
                // Keep the reference's original spelling when the word counts line up.
                let tail = original.count == words.count ? original[range.upperBound...] : words[range.upperBound...]
                plan.similarTo = tail.joined(separator: " ")
                words.removeSubrange(range.lowerBound...)
                break
            }
        }

        var remaining: [String] = []
        var phrases: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let pair = index + 1 < words.count ? "\(word) \(words[index + 1])" : nil
            if let pair, let time = timeWords[pair] {
                plan.time = time
                index += 2
                continue
            }
            // "Serie A" is a football league, not a series: a keyword, never a kind.
            if let phrase = contentPhrase(at: index, in: words) {
                remaining.append(phrase)
                phrases.append(phrase)
                index += 2
                continue
            }
            if let pair, let kind = kindPairs[pair] {
                plan.kind = kind
                index += 2
                continue
            }
            if let time = timeWords[word] {
                plan.time = time
            } else if let kind = kindWords[word] {
                plan.kind = kind
            } else if let code = countryWords[word] {
                plan.countryCode = code
            } else if !stopWords.contains(word) {
                remaining.append(word)
            }
            index += 1
        }

        var keywords: [String] = []
        if !remaining.isEmpty {
            // The words together first ("formula 1"), then their synonyms.
            keywords.append(remaining.joined(separator: " "))
            // A competition on its own too ("serie a" of "inter serie a"), as the guide matches it as a phrase.
            keywords.append(contentsOf: phrases)
            for word in remaining {
                keywords.append(contentsOf: synonyms[word] ?? [])
            }
        }
        var seen: Set<String> = []
        plan.keywords = keywords.filter { seen.insert($0).inserted }
        plan.wantsProgrammes = plan.time != .any || remaining.contains { programmeWords.contains($0) }
        return plan
    }

    /// The competition that starts at `index` when its name begins with a kind word: "serie" followed by one
    /// letter ("Serie A", "Série B"), which the guide and channel names use for football leagues.
    static func contentPhrase(at index: Int, in words: [String]) -> String? {
        guard index + 1 < words.count, words[index] == "serie" else {
            return nil
        }
        let next = words[index + 1]
        guard next.count == 1, next.allSatisfy(\.isLetter) else {
            return nil
        }
        return "serie \(next)"
    }

    /// The competitions of `words` whose name begins with a kind word (see `contentPhrase(at:in:)`).
    static func contentPhrases(in words: [String]) -> [String] {
        words.indices.compactMap { contentPhrase(at: $0, in: words) }
    }

    /// A time, kind, country or filler word: something the plain name search cannot use.
    static func isCueWord(_ word: String) -> Bool {
        timeWords[word] != nil || kindWords[word] != nil || countryWords[word] != nil || stopWords.contains(word)
    }

    /// Whether a query has a cue word, or a two-word time ("this evening"), or "like".
    static func hasCue(_ query: String) -> Bool {
        let words = words(query)
        if words.contains(where: isCueWord) {
            return true
        }
        let pairs = zip(words, words.dropFirst()).map { "\($0) \($1)" }
        return pairs.contains { timeWords[$0] != nil } || words.contains("like") || words.contains("similar")
    }

    /// Words that name a country in group or channel names ("IT", "Italy", "Italia").
    static func countryTerms(for code: String) -> Set<String> {
        var terms: Set<String> = [code.lowercased()]
        for (word, wordCode) in countryWords where wordCode == code {
            terms.insert(word)
        }
        if let alpha3 = alpha3[code] {
            terms.insert(alpha3)
        }
        if let name = Locale(identifier: "en").localizedString(forRegionCode: code) {
            terms.formUnion(words(name))
        }
        if let name = Locale.current.localizedString(forRegionCode: code) {
            terms.formUnion(words(name))
        }
        return terms
    }

    // MARK: - Vocabulary

    static let timeWords: [String: SmartSearchPlan.Time] = [
        "now": .now, "right now": .now, "on now": .now, "live now": .now, "adesso": .now, "ora": .now, "jetzt": .now,
        "maintenant": .now, "ahora": .now,
        "tonight": .tonight, "this evening": .tonight, "stasera": .tonight, "heute abend": .tonight, "ce soir": .tonight,
        "esta noche": .tonight, "evening": .tonight,
        "today": .today, "oggi": .today, "heute": .today, "hoy": .today,
        "tomorrow": .tomorrow, "domani": .tomorrow, "morgen": .tomorrow, "demain": .tomorrow, "manana": .tomorrow,
    ]

    static let kindWords: [String: SmartSearchPlan.Kind] = [
        "channel": .live, "channels": .live, "canale": .live, "canali": .live, "sender": .live, "chaine": .live,
        "chaines": .live, "canal": .live, "canales": .live, "live": .live, "tv": .live,
        "movie": .movies, "movies": .movies, "film": .movies, "films": .movies, "pelicula": .movies, "peliculas": .movies,
        "series": .series, "serie": .series, "serien": .series, "telefilm": .series,
    ]

    /// Two-word kinds, read before the single words ("serie tv" is Italian for TV series, not live TV).
    static let kindPairs: [String: SmartSearchPlan.Kind] = [
        "serie tv": .series, "series tv": .series, "tv series": .series,
        "tv movie": .movies, "tv movies": .movies, "film tv": .movies,
    ]

    static let countryWords: [String: String] = [
        "italian": "IT", "italy": "IT", "italia": "IT", "italiano": "IT", "italiani": "IT", "italiane": "IT", "ita": "IT",
        "english": "GB", "british": "GB", "uk": "GB", "england": "GB",
        "american": "US", "usa": "US",
        "french": "FR", "france": "FR", "francais": "FR", "fra": "FR",
        "german": "DE", "germany": "DE", "deutsch": "DE", "deutschland": "DE", "ger": "DE",
        "spanish": "ES", "spain": "ES", "espana": "ES", "espanol": "ES", "esp": "ES",
        "portuguese": "PT", "portugal": "PT", "brazilian": "BR", "brazil": "BR", "brasil": "BR",
        "dutch": "NL", "netherlands": "NL", "turkish": "TR", "turkey": "TR", "turkiye": "TR",
        "greek": "GR", "greece": "GR", "arabic": "SA", "japanese": "JP", "japan": "JP",
        "polish": "PL", "poland": "PL", "romanian": "RO", "romania": "RO", "albanian": "AL", "albania": "AL",
        "indian": "IN", "india": "IN", "canadian": "CA", "canada": "CA", "swiss": "CH", "switzerland": "CH",
        "belgian": "BE", "belgium": "BE", "swedish": "SE", "sweden": "SE", "irish": "IE", "ireland": "IE",
    ]

    static let alpha3: [String: String] = [
        "IT": "ita", "GB": "gbr", "US": "usa", "FR": "fra", "DE": "ger", "ES": "esp", "PT": "por", "BR": "bra",
        "NL": "ned", "TR": "tur", "GR": "gre", "PL": "pol", "RO": "rou", "AL": "alb", "IN": "ind", "CA": "can",
        "CH": "sui", "BE": "bel", "SE": "swe", "IE": "irl", "JP": "jpn", "SA": "ara",
    ]

    static let stopWords: Set<String> = [
        "a", "an", "the", "some", "something", "anything", "any", "on", "in", "at", "for", "to", "of", "with", "and",
        "i", "me", "my", "want", "wanna", "watch", "watching", "find", "search", "look", "looking", "is", "are",
        "what", "whats", "s", "please", "good", "best", "new", "about",
        "qualcosa", "da", "di", "il", "la", "lo", "le", "gli", "un", "una", "per", "su", "vedere", "guardare",
        "etwas", "der", "die", "das", "mit", "quelque", "chose", "les", "des", "algo", "el", "los", "las",
    ]

    /// Words that ask for programmes rather than channels.
    static let programmeWords: Set<String> = [
        "match", "matches", "game", "games", "partita", "partite", "race", "gara", "gp", "grand", "prix", "final",
        "documentary", "documentaries", "documentario", "documentari", "episode", "episodes", "concert", "derby",
        "serie a", "serie b", "serie c",
    ]

    static let synonyms: [String: [String]] = [
        "football": ["soccer", "calcio", "serie a", "premier league"],
        "soccer": ["football", "calcio"],
        "calcio": ["football", "serie a"],
        "serie a": ["calcio", "football", "soccer"],
        "serie b": ["calcio", "football"],
        "serie c": ["calcio", "football"],
        "f1": ["formula 1", "formula one", "grand prix"],
        "motogp": ["moto gp"],
        "tennis": ["atp", "wta"],
        "basketball": ["nba", "basket"],
        "news": ["tg", "notizie", "telegiornale", "nachrichten", "info"],
        "notizie": ["news", "tg"],
        "kids": ["cartoons", "bambini", "junior", "kinder", "boing"],
        "cartoons": ["kids", "cartoni", "animation"],
        "cartoni": ["cartoons", "kids"],
        "music": ["musica", "musik", "mtv", "hits"],
        "musica": ["music", "hits"],
        "documentary": ["documentario", "doku", "discovery", "history"],
        "documentaries": ["documentary", "documentario", "discovery"],
        "cooking": ["cucina", "food", "chef"],
        "cinema": ["film", "movies"],
        "comedy": ["commedia", "comedia"],
        "horror": ["thriller"],
        "sport": ["sports", "sky sport", "eurosport"],
        "sports": ["sport", "eurosport"],
    ]
}
