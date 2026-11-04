//
//  ChannelSpokenNames.swift
//  Fluxo
//
//  The names people say for a playlist entry, for Siri. Playlist names are written for set-top boxes
//  ("IT: Sky Sport F1 FHD", "|UK| BBC One HD", "Rai 1 (backup)"), but people say "Sky Sport F1", "BBC One" or
//  "Rai Uno". Siri matches the spoken words of a phrase like "Play … in Fluxo" against the title and the
//  synonyms of each entity it knows, so `ChannelEntity` lists these variants as synonyms.
//

import Foundation

enum ChannelSpokenNames {

    /// At most this many synonyms per channel.
    static let limit = 4

    /// The language of the interface (and so, normally, of Siri), for spelled-out numbers.
    static let interfaceLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    /// Spoken variants of `name`, without the name itself: the name without provider prefix, quality tags and
    /// notes ("sky sport f1"), without filler words ("rai 1" for "Rai 1 TV"), with small numbers spelled out
    /// in the interface language ("rai uno") and "+" read as "plus" ("canal plus").
    static func variants(of name: String, locale: Locale = interfaceLocale) -> [String] {
        let tokens = ChannelNameNormalizer.tokens(name)
        guard !tokens.isEmpty else {
            return []
        }
        var candidates: [[String]] = [tokens]
        let withoutFiller = tokens.filter { !fillerWords.contains($0) }
        if !withoutFiller.isEmpty, withoutFiller.count < tokens.count {
            candidates.append(withoutFiller)
        }
        for base in candidates where base.contains(where: isSmallNumber) {
            candidates.append(base.map { isSmallNumber($0) ? spelledOut($0, locale: locale) : $0 })
        }
        for base in candidates where base.contains("+") {
            candidates.append(base.map { $0 == "+" ? "plus" : $0 })
        }

        let folded = fold(name)
        var seen: Set<String> = [folded]
        var variants: [String] = []
        for candidate in candidates {
            let text = joined(candidate)
            // Not a bare number or a very short word: "4" for "Channel 4" would catch any phrase with a four.
            guard isDistinctive(candidate), seen.insert(fold(text)).inserted else {
                continue
            }
            variants.append(text)
            if variants.count == limit {
                break
            }
        }
        return variants
    }

    /// Joins tokens with spaces; a plus goes with the number after it ("rai 1 +1") or else with the word before
    /// it ("canal+").
    private static func joined(_ tokens: [String]) -> String {
        var words: [String] = []
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index]
            let next = tokens.index(after: index)
            if token == "+" {
                if next < tokens.endIndex, Int(tokens[next]) != nil {
                    words.append("+" + tokens[next])
                    index = tokens.index(after: next)
                    continue
                }
                if let last = words.popLast() {
                    words.append(last + "+")
                } else {
                    words.append("+")
                }
            } else {
                words.append(token)
            }
            index = next
        }
        return words.joined(separator: " ")
    }

    /// At least one word of letters with two or more of them, three characters in all, and at most six words
    /// (nobody says a long event title as a channel name).
    private static func isDistinctive(_ tokens: [String]) -> Bool {
        guard tokens.count <= 6 else {
            return false
        }
        let letterWords = tokens.filter { $0.count >= 2 && $0.contains(where: \.isLetter) && Int($0) == nil }
        return !letterWords.isEmpty && tokens.joined().count >= 3 && !(tokens.count == 1 && spokenNumbers.contains(tokens[0]))
    }

    /// Single spelled-out numbers, which are no name on their own ("four" for "Channel 4").
    private static let spokenNumbers: Set<String> = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = interfaceLocale
        return Set((1...20).compactMap { formatter.string(from: NSNumber(value: $0)) })
    }()

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    private static func isSmallNumber(_ token: String) -> Bool {
        guard let value = Int(token) else {
            return false
        }
        return (1...20).contains(value) && token.first != "0"
    }

    private static func spelledOut(_ token: String, locale: Locale) -> String {
        guard let value = Int(token) else {
            return token
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? token
    }

    /// Words a channel name often has that people leave out when they say it.
    private static let fillerWords: Set<String> = [
        "tv", "channel", "television", "televisione", "network", "live",
    ]
}
