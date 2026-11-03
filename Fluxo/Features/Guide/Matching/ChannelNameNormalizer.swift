//
//  ChannelNameNormalizer.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation

/// Turns channel names and XMLTV ids into comparison keys, so that "IT: Sky Sport F1 FHD", "Sky Sport F1 HD"
/// and "sky sport f1" all meet on "skysportf1".
///
/// - `key`: case, diacritics and width folded, compatibility characters mapped ("ᴴᴰ" → "HD"), provider prefixes
///   ("IT:", "|UK|", "[DE]"), bracketed notes, quality tags (HD, FHD, 4K, HEVC, 1080p, …) and a trailing country
///   code removed. "+" stays significant ("Canal+" is not "Canal"), "+1" timeshift channels stay distinct.
/// - `looseKey`: additionally maps number words to digits ("Rai Uno" → "rai1") and drops filler words
///   ("TV", "Channel", "Canale", …). Used only when the strict key finds nothing.
/// - `idKeys`: the XMLTV id lowercased, plus the id without a feed suffix ("BBCOne.uk@HD" → "bbcone.uk").
enum ChannelNameNormalizer {

    static func key(_ name: String) -> String {
        tokens(name).joined()
    }

    static func looseKey(_ name: String) -> String {
        tokens(name)
            .compactMap { token -> String? in
                if fillerWords.contains(token) {
                    return nil
                }
                return numberWords[token] ?? token
            }
            .joined()
    }

    /// Both keys at once (the tokenization is the expensive part).
    static func keys(_ name: String) -> (strict: String, loose: String) {
        let tokens = tokens(name)
        let loose = tokens.compactMap { fillerWords.contains($0) ? nil : (numberWords[$0] ?? $0) }
        return (tokens.joined(), loose.joined())
    }

    static func idKeys(_ id: String) -> [String] {
        let lowered = id.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lowered.isEmpty else {
            return []
        }
        if let at = lowered.firstIndex(of: "@"), at != lowered.startIndex {
            return [lowered, String(lowered[..<at])]
        }
        return [lowered]
    }

    /// A name hidden in an XMLTV id: "SkySportF1.it@HD" → "SkySportF1", "bbc-one-hd.uk" → "bbc one hd".
    static func nameFromID(_ id: String) -> String {
        var value = Substring(id)
        if let at = value.firstIndex(of: "@") {
            value = value[..<at]
        }
        // Drop a trailing ".cc" / ".ccc" country or domain part.
        if let dot = value.lastIndex(of: "."), value.distance(from: dot, to: value.endIndex) <= 4, dot != value.startIndex {
            value = value[..<dot]
        }
        return value.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    // MARK: - Tokens

    static func tokens(_ name: String) -> [String] {
        var text = name.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        text = strippingProviderPrefix(text)
        text = strippingBrackets(text)

        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "+" {
                // "Canal+", "Sky Sport+" and "+1" timeshift channels: keep the plus as its own token.
                flush()
                tokens.append("+")
            } else if character == "&" {
                flush()
                tokens.append("and")
            } else {
                flush()
            }
        }
        flush()

        tokens.removeAll { qualityTags.contains($0) || isResolutionTag($0) }
        if tokens.count > 1, let last = tokens.last, last.count == 2, countryCodes.contains(last) {
            tokens.removeLast()
        }
        return tokens
    }

    /// "IT: Rai 1", "IT | Rai 1", "|IT| Rai 1", "[IT] Rai 1", "(IT) Rai 1", "IT - Rai 1", "VIP UK: BBC One" → the name.
    /// Only short codes count as a prefix, so "Rai 1: Live" or "BBC One - HD" are left alone.
    private static func strippingProviderPrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else {
            return trimmed
        }
        if first == "|" || first == "[" || first == "(" {
            let closer: Character = first == "[" ? "]" : (first == "(" ? ")" : "|")
            let afterOpen = trimmed.index(after: trimmed.startIndex)
            if let close = trimmed[afterOpen...].firstIndex(of: closer) {
                let inner = trimmed[afterOpen..<close].trimmingCharacters(in: .whitespaces)
                let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: prefixSeparators)
                if isPrefixCode(inner), !rest.isEmpty {
                    return rest
                }
            }
            return trimmed
        }
        if let index = trimmed.firstIndex(where: { $0 == ":" || $0 == "|" || $0 == "-" }) {
            let prefix = trimmed[..<index].trimmingCharacters(in: .whitespaces)
            let rest = trimmed[trimmed.index(after: index)...].trimmingCharacters(in: prefixSeparators)
            // A hyphen is common inside names ("Canal-Plus"): only a country code before it is a prefix.
            let isPrefix = trimmed[index] == "-" ? countryCodes.contains(prefix) : isPrefixCode(prefix)
            if isPrefix, !rest.isEmpty {
                return rest
            }
        }
        return trimmed
    }

    /// One word of 2 to 4 letters ("it", "uk", "ppv"), or two words with a country code ("vip uk").
    private static func isPrefixCode(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        let isShortWord: (Substring) -> Bool = { (2...4).contains($0.count) && $0.allSatisfy(\.isLetter) }
        switch words.count {
        case 1:
            return isShortWord(words[0])
        case 2:
            return words.allSatisfy(isShortWord) && words.contains { countryCodes.contains(String($0)) }
        default:
            return false
        }
    }

    private static let prefixSeparators = CharacterSet(charactersIn: " |:-»•")

    /// Removes "(...)", "[...]" and "{...}" notes, e.g. "Rai 1 (backup)" or "BBC One [Multi-Audio]".
    private static func strippingBrackets(_ text: String) -> String {
        guard text.contains(where: { $0 == "(" || $0 == "[" || $0 == "{" }) else {
            return text
        }
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "[", "{":
                depth += 1
                result.append(" ")
            case ")", "]", "}":
                depth = max(0, depth - 1)
            default:
                if depth == 0 {
                    result.append(character)
                }
            }
        }
        // A name made only of a bracketed part: keep the original.
        return result.contains(where: { $0.isLetter || $0.isNumber }) ? result : text
    }

    private static func isResolutionTag(_ token: String) -> Bool {
        // 720p, 1080i, 2160p, 50fps, 60fps
        if token.hasSuffix("fps") {
            return token.dropLast(3).allSatisfy(\.isNumber) && token.count > 3
        }
        if let last = token.last, last == "p" || last == "i", token.count >= 4 {
            return token.dropLast().allSatisfy(\.isNumber)
        }
        return false
    }

    private static let qualityTags: Set<String> = [
        "hd", "fhd", "uhd", "sd", "hq", "lq", "4k", "8k", "hevc", "h264", "h265", "x264", "x265", "avc",
        "hdr", "hdr10", "sdr", "backup", "bkp", "raw", "mono", "stereo", "multi", "multiaudio",
    ]

    private static let fillerWords: Set<String> = [
        "tv", "channel", "ch", "canal", "canale", "kanal", "chaine", "the", "television", "televisione", "network",
    ]

    private static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "uno": "1", "due": "2", "tre": "3", "quattro": "4", "cinque": "5", "sei": "6", "sette": "7", "otto": "8", "nove": "9", "dieci": "10",
        "dos": "2", "tres": "3", "cuatro": "4", "cinco": "5", "seis": "6", "siete": "7", "ocho": "8", "nueve": "9", "diez": "10",
        "un": "1", "deux": "2", "trois": "3", "quatre": "4", "cinq": "5", "sept": "7", "huit": "8", "neuf": "9", "dix": "10",
        "eins": "1", "zwei": "2", "drei": "3", "vier": "4", "funf": "5", "sechs": "6", "sieben": "7", "acht": "8", "neun": "9", "zehn": "10",
    ]

    /// ISO 3166-1 alpha-2 codes (plus "uk"), lowercased: a trailing one is a country tag, not part of the name.
    /// Codes that are also common words of channel names ("tv", "me", "to", "do", "so", "as") are left out.
    private static let countryCodes: Set<String> = Set("""
    ad ae af ag ai al am ao aq ar  at au aw ax az ba bb bd be bf bg bh bi bj bl bm bn bo bq br bs bt bv bw by bz \
    ca cc cd cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz de dj dk dm  dz ec ee eg eh er es et fi fj fk fm fo fr \
    ga gb gd ge gf gg gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im in io iq ir is it je jm jo jp \
    ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md  mf mg mh mk ml mm mn mo mp mq mr ms mt \
    mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu nz om pa pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw \
    sa sb sc sd se sg sh si sj sk sl sm sn  sr ss st sv sx sy sz tc td tf tg th tj tk tl tm tn  tr tt  tw tz ua ug \
    um us uy uz va vc ve vg vi vn vu wf ws ye yt za zm zw uk
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
}
