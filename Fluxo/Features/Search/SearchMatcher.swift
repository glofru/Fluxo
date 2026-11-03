//
//  SearchMatcher.swift
//  Fluxo
//
//  Token-based name matching and ranking for Search (channels and groups).
//
//  Names and queries are normalized the same way: case, diacritics and width folded ("Café" = "cafe",
//  "ＳＫＹ" = "sky"), and every character that is not a letter or a digit becomes a word break ("IT | Sky-Sport
//  F1 (FHD)" = "it sky sport f1 fhd"). The query is split into tokens and every token must match a word of the
//  name, in any order:
//
//  - exact word ("f1" = "f1"), then word prefix ("spo" → "sport"), then inside a word ("sport" in "skysport"),
//  - then inside the name with the word breaks removed, so "skysport" finds "Sky Sport" and "f1" finds "F-1",
//  - then, for alphabetic tokens of 4+ letters, with typos: 1 edit (insertion, deletion, substitution or
//    transposition) for 4 to 7 letters, 2 from 8 letters ("sprot" → "sport", "mediaset" ← "mediasett").
//    Digits are never fuzzy ("Sport 5" must not find "Sport 6").
//
//  Ranking: the whole name equal to the query, then the name starting with the query, then the sum of the token
//  matches (exact > prefix > inside > joined > typo), tokens in the query's order, and shorter names (fewer
//  words that the query did not ask for). Ties keep the playlist order.
//
//  Everything works on the UTF-8 bytes of the normalized strings, so a 100k-channel scan is a tight loop over
//  small byte arrays (see Tools/HomeQueriesCheck for the benchmark).
//

import Foundation

/// A normalized name: its UTF-8 bytes, words separated by single spaces (0x20), no leading or trailing space.
struct SearchName: Sendable, Hashable {
    let bytes: [UInt8]

    init(_ string: String) {
        bytes = SearchMatcher.normalizedBytes(string)
    }

    var isEmpty: Bool {
        bytes.isEmpty
    }
}

/// A parsed query: normalized tokens (deduplicated, in query order) plus the whole normalized query.
struct SearchQuery: Sendable {
    let tokens: [[UInt8]]
    let whole: [UInt8]

    init(_ text: String) {
        let whole = SearchMatcher.normalizedBytes(text)
        var tokens: [[UInt8]] = []
        for token in whole.split(separator: SearchMatcher.space) where !tokens.contains(where: { $0.elementsEqual(token) }) {
            tokens.append(Array(token))
        }
        self.whole = whole
        self.tokens = tokens
    }

    var isEmpty: Bool {
        tokens.isEmpty
    }
}

enum SearchMatcher {

    static let space: UInt8 = 0x20

    /// How a query token matched a name, best first. The raw value is the token's share of the score.
    enum MatchKind: Int, Comparable {
        case typo = 12
        case joined = 30
        case infix = 45
        case prefix = 75
        case exact = 100

        static func < (lhs: MatchKind, rhs: MatchKind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: Normalization

    static func normalizedBytes(_ string: String) -> [UInt8] {
        // Most playlist names are ASCII: lowercase them byte by byte, without the cost of Unicode folding.
        if string.utf8.allSatisfy({ $0 < 0x80 }) {
            return normalizedASCII(string.utf8)
        }
        let folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var output: [UInt8] = []
        output.reserveCapacity(folded.utf8.count)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if isWordCharacter(scalar) {
                if pendingSpace && !output.isEmpty {
                    output.append(space)
                }
                pendingSpace = false
                // Folding leaves some capitals outside ASCII alone only in odd cases; ASCII ones are lowered.
                let lowered = scalar.isASCII ? Unicode.Scalar(UInt8(scalar.value) | (isUppercaseASCII(UInt8(scalar.value)) ? 0x20 : 0)) : scalar
                UTF8.encode(lowered) { output.append($0) }
            } else {
                pendingSpace = true
            }
        }
        return output
    }

    private static func normalizedASCII(_ bytes: String.UTF8View) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var pendingSpace = false
        for byte in bytes {
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isLower = byte >= 0x61 && byte <= 0x7A
            if isDigit || isLower || isUppercaseASCII(byte) {
                if pendingSpace && !output.isEmpty {
                    output.append(space)
                }
                pendingSpace = false
                output.append(isUppercaseASCII(byte) ? byte | 0x20 : byte)
            } else {
                pendingSpace = true
            }
        }
        return output
    }

    private static func isUppercaseASCII(_ byte: UInt8) -> Bool {
        byte >= 0x41 && byte <= 0x5A
    }

    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let value = scalar.value
            return (0x30...0x39).contains(value) || (0x61...0x7A).contains(value) || (0x41...0x5A).contains(value)
        }
        let properties = scalar.properties
        // Letters of every script (CJK, Arabic, Greek…), digits, and the combining marks folding keeps.
        return properties.isAlphabetic || properties.numericType != nil || properties.generalCategory == .nonspacingMark
    }

    // MARK: Scoring

    /// The score of `name` for `query`, or nil when a token matches no word. `allowTypos` enables the fuzzy step
    /// (Search runs it only when the exact steps found too few results).
    static func score(_ name: SearchName, query: SearchQuery, allowTypos: Bool) -> Int? {
        let bytes = name.bytes
        guard !bytes.isEmpty, !query.tokens.isEmpty else {
            return nil
        }
        var total = 0
        var previousWord = -1
        var inOrder = true
        for token in query.tokens {
            guard let (kind, word) = bestMatch(of: token, in: bytes, allowTypos: allowTypos) else {
                return nil
            }
            total += kind.rawValue
            if word <= previousWord {
                inOrder = false
            }
            previousWord = word
        }
        if query.tokens.count > 1 && inOrder {
            total += 20
        }
        if bytes == query.whole {
            total += 400
        } else if bytes.starts(with: query.whole) {
            total += 120
        }
        // Prefer names with fewer words the query did not ask for ("Sky Sport F1" before "Sky Sport F1 FHD Backup").
        let words = bytes.reduce(1) { $1 == space ? $0 + 1 : $0 }
        total -= 3 * max(0, words - query.tokens.count)
        return total
    }

    /// The best match of one token in a normalized name, with the index of the word it matched (-1 for a
    /// match across words).
    static func bestMatch(of token: [UInt8], in name: [UInt8], allowTypos: Bool) -> (MatchKind, Int)? {
        var best: (MatchKind, Int)?
        var wordIndex = 0
        var start = 0
        let count = name.count
        while start < count {
            var end = start
            while end < count && name[end] != space {
                end += 1
            }
            let length = end - start
            if length >= token.count {
                if hasPrefix(name, start: start, token) {
                    if length == token.count {
                        return (.exact, wordIndex)
                    }
                    if best == nil || best!.0 < .prefix {
                        best = (.prefix, wordIndex)
                    }
                } else if token.count >= 2 && (best == nil || best!.0 < .infix) && contains(name, start: start + 1, end: end, token) {
                    best = (.infix, wordIndex)
                }
            }
            wordIndex += 1
            start = end + 1
        }
        if let best {
            return best
        }
        if token.count >= 2 && containsIgnoringSpaces(name, token) {
            return (.joined, -1)
        }
        if allowTypos, let word = typoMatch(of: token, in: name) {
            return (.typo, word)
        }
        return nil
    }

    // MARK: Byte helpers

    private static func hasPrefix(_ name: [UInt8], start: Int, _ token: [UInt8]) -> Bool {
        var index = 0
        while index < token.count {
            if name[start + index] != token[index] {
                return false
            }
            index += 1
        }
        return true
    }

    /// `token` occurs in `name[start..<end]`.
    private static func contains(_ name: [UInt8], start: Int, end: Int, _ token: [UInt8]) -> Bool {
        let last = end - token.count
        guard start <= last else {
            return false
        }
        let first = token[0]
        var position = start
        while position <= last {
            if name[position] == first {
                var index = 1
                while index < token.count && name[position + index] == token[index] {
                    index += 1
                }
                if index == token.count {
                    return true
                }
            }
            position += 1
        }
        return false
    }

    /// `token` occurs in `name` with its spaces removed.
    private static func containsIgnoringSpaces(_ name: [UInt8], _ token: [UInt8]) -> Bool {
        guard name.contains(space) else {
            return false
        }
        var position = 0
        while position < name.count {
            if name[position] != space {
                var cursor = position
                var index = 0
                while index < token.count && cursor < name.count {
                    if name[cursor] == space {
                        cursor += 1
                        continue
                    }
                    if name[cursor] != token[index] {
                        break
                    }
                    cursor += 1
                    index += 1
                }
                if index == token.count {
                    return true
                }
            }
            position += 1
        }
        return false
    }

    // MARK: Typos

    /// Most edits a token of `length` letters may have.
    static func typoBudget(forLength length: Int) -> Int {
        switch length {
        case ..<4:
            return 0
        case 4..<8:
            return 1
        default:
            return 2
        }
    }

    /// The index of the first word that is within the typo budget of `token`, either whole or as a prefix
    /// (the token is still being typed). Only ASCII-letter tokens are fuzzy.
    private static func typoMatch(of token: [UInt8], in name: [UInt8]) -> Int? {
        let budget = typoBudget(forLength: token.count)
        guard budget > 0, token.allSatisfy({ (0x61...0x7A).contains($0) }) else {
            return nil
        }
        var wordIndex = 0
        var start = 0
        while start < name.count {
            var end = start
            while end < name.count && name[end] != space {
                end += 1
            }
            let length = end - start
            if length + budget >= token.count {
                // Compare with the word cut to the token's length (+ budget), so "champ" matches "champions".
                let cut = min(length, token.count + budget)
                if let distance = boundedDistance(token, name, start: start, length: cut, budget: budget), distance <= budget {
                    return wordIndex
                }
            }
            wordIndex += 1
            start = end + 1
        }
        return nil
    }

    /// Optimal-string-alignment distance between `token` and the prefix of `name[start..<start+length]` that
    /// fits it best (the word may continue after the token), or nil once it exceeds `budget`.
    static func boundedDistance(_ token: [UInt8], _ name: [UInt8], start: Int, length: Int, budget: Int) -> Int? {
        let rows = token.count
        let columns = length
        // The caller cuts the word to at most `rows + budget` bytes; shorter than `rows - budget` cannot match.
        guard rows > 0, columns >= max(1, rows - budget) else {
            return nil
        }
        // Three rolling rows of the dynamic programming table (OSA needs the row before the previous one).
        var previous2 = [Int](repeating: 0, count: columns + 1)
        var previous = [Int](0...columns)
        var current = [Int](repeating: 0, count: columns + 1)
        for row in 1...rows {
            current[0] = row
            var rowMinimum = current[0]
            let tokenByte = token[row - 1]
            for column in 1...columns {
                let nameByte = name[start + column - 1]
                let cost = tokenByte == nameByte ? 0 : 1
                var value = min(previous[column] + 1, current[column - 1] + 1, previous[column - 1] + cost)
                if row > 1 && column > 1 && tokenByte == name[start + column - 2] && token[row - 2] == nameByte {
                    value = min(value, previous2[column - 2] + 1)
                }
                current[column] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > budget {
                return nil
            }
            swap(&previous2, &previous)
            swap(&previous, &current)
        }
        // `previous` is the last row: the best alignment of the whole token with any prefix of the word that
        // is at least as long as the token minus the budget.
        let best = previous[max(0, rows - budget)...columns].min() ?? Int.max
        return best <= budget ? best : nil
    }
}
