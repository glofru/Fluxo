//
//  CategoryChannelsModel.swift
//  Fluxo
//
//  The channels of one category for `CategoryDetailView`: fetched as values on a background context, a page
//  at a time, in the chosen order, optionally filtered by a search term. Also the letter index of the A–Z
//  order and the "Most Watched" channels of the category.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class CategoryChannelsModel {

    /// What is listed. A new request starts again from the first page.
    struct Request: Hashable, Sendable {
        let importID: UUID
        let playlistID: UUID
        let groupName: String
        let order: ChannelSortOrder
        let term: String
    }

    /// The first entry of a letter in the A–Z order.
    struct LetterOffset: Hashable, Sendable {
        let letter: String
        let offset: Int
    }

    nonisolated static let pageSize = 120
    /// Search results within a category are capped: typing more narrows them.
    nonisolated static let searchLimit = 500
    nonisolated static let mostWatchedLimit = 8

    private(set) var request: Request?
    private(set) var items: [ChannelItem] = []
    /// False until the first page of `request` is loaded (the list then shows a spinner, not "no channels").
    private(set) var isLoaded = false
    private(set) var reachedEnd = false
    /// A–Z order only: the letters of the index scroller.
    private(set) var letters: [LetterOffset] = []
    /// "Most Watched" order: the channels of the category watched most often (from the watch history).
    private(set) var mostWatched: [ChannelItem] = []

    @ObservationIgnored
    private var isLoadingPage = false

    /// Loads the first page of `request` (and the letters or the most watched channels it needs).
    func load(_ request: Request, container: ModelContainer) async {
        self.request = request
        isLoaded = false
        reachedEnd = false
        isLoadingPage = false
        let first = await Self.fetchPage(request, offset: 0, container: container)
        guard !Task.isCancelled, self.request == request else {
            return
        }
        items = first
        reachedEnd = !request.term.isEmpty || first.count < Self.pageSize
        isLoaded = true

        letters = request.order == .name && request.term.isEmpty ? await Self.fetchLetters(request, container: container) : []
        mostWatched = request.order == .mostWatched && request.term.isEmpty ? await Self.fetchMostWatched(request, container: container) : []
    }

    /// Loads the next page (when the last rows scroll in).
    func loadMore(container: ModelContainer) async {
        guard let request, isLoaded, !reachedEnd, !isLoadingPage else {
            return
        }
        isLoadingPage = true
        defer {
            isLoadingPage = false
        }
        let page = await Self.fetchPage(request, offset: items.count, container: container)
        guard self.request == request else {
            return
        }
        items.append(contentsOf: page)
        reachedEnd = page.count < Self.pageSize
    }

    /// Loads pages until the entry at `offset` is loaded (to jump to a letter or restore a position).
    func ensureLoaded(offset: Int, container: ModelContainer) async {
        while items.count <= offset, !reachedEnd, !Task.isCancelled {
            let before = items.count
            await loadMore(container: container)
            if items.count == before {
                return
            }
        }
    }

    // MARK: - Background fetches

    private nonisolated static func fetchPage(_ request: Request, offset: Int, container: ModelContainer) async -> [ChannelItem] {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let descriptor: FetchDescriptor<PlaylistChannel>
            if request.term.isEmpty {
                descriptor = HomeQueries.channels(importID: request.importID, groupName: request.groupName, order: request.order, offset: offset, limit: pageSize)
            } else {
                descriptor = HomeQueries.channels(importID: request.importID, groupName: request.groupName, matching: request.term, order: request.order, limit: searchLimit)
            }
            return ((try? context.fetch(descriptor)) ?? []).map(ChannelItem.init)
        }.value
    }

    /// Reads only the names of the whole category in A–Z order and notes where each letter starts.
    private nonisolated static func fetchLetters(_ request: Request, container: ModelContainer) async -> [LetterOffset] {
        await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            var descriptor = HomeQueries.channels(importID: request.importID, groupName: request.groupName, order: .name, limit: 0)
            descriptor.fetchLimit = nil
            descriptor.propertiesToFetch = [\.name]
            guard let names = try? context.fetch(descriptor).map(\.name) else {
                return []
            }
            return letterOffsets(of: names)
        }.value
    }

    private nonisolated static func fetchMostWatched(_ request: Request, container: ModelContainer) async -> [ChannelItem] {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let descriptor = HomeQueries.mostWatched(playlistID: request.playlistID, groupName: request.groupName, limit: mostWatchedLimit)
            return ((try? context.fetch(descriptor)) ?? []).map(ChannelItem.init)
        }.value
    }

    /// The first offset of each index letter, in list order. Letters are folded (É is E); names that start with
    /// a digit or a symbol are listed under "#". See `indexLetter(for:locale:)` for the scripts that have
    /// no small alphabet.
    nonisolated static func letterOffsets(of names: [String?], locale: Locale = .current) -> [LetterOffset] {
        var result: [LetterOffset] = []
        var seen: Set<String> = []
        // Most names share their first character with others: only a Japanese kanji needs the whole name.
        var letterOfFirstCharacter: [Character: String] = [:]
        for (offset, name) in names.enumerated() {
            let letter: String
            if let first = name?.first(where: { !$0.isWhitespace }), !(isHan(first) && isJapanese(locale)) {
                if let known = letterOfFirstCharacter[first] {
                    letter = known
                } else {
                    letter = indexLetter(for: name, locale: locale)
                    letterOfFirstCharacter[first] = letter
                }
            } else {
                letter = indexLetter(for: name, locale: locale)
            }
            if seen.insert(letter).inserted {
                result.append(LetterOffset(letter: letter, offset: offset))
            }
        }
        return result
    }

    /// The entry of the index scroller a name is listed under, as the system's indexed lists do it:
    /// - Latin, Cyrillic, Greek, Arabic, …: the first letter, without its accents and in upper case (in
    ///   Turkish, İ stays apart from I).
    /// - Korean: the first consonant of the syllable (간, 각 and 까 are all under ㄱ).
    /// - Japanese kana: the row of the kana table (か, が and カ are under か); a name that starts with a
    ///   kanji goes by the reading of its first word when the app is in Japanese.
    /// - Chinese characters (in any other language): the first letter of their pinyin (湖南 is under H).
    /// - Anything else (digits, symbols, emoji): "#".
    nonisolated static func indexLetter(for name: String?, locale: Locale = .current) -> String {
        guard let name, let first = name.first(where: { !$0.isWhitespace }) else {
            return "#"
        }
        // Full-width Latin and half-width katakana become their usual forms.
        let character = Character(String(first).folding(options: .widthInsensitive, locale: nil))
        if let scalar = character.unicodeScalars.first {
            if let consonant = hangulInitial(of: scalar) {
                return consonant
            }
            if let row = kanaRow(of: scalar) {
                return row
            }
        }
        if isHan(character) {
            if isJapanese(locale) {
                return japaneseReading(of: name).flatMap { $0.unicodeScalars.first }.flatMap(kanaRow(of:)) ?? "#"
            }
            return pinyinInitial(of: character) ?? "#"
        }
        guard character.isLetter else {
            return "#"
        }
        let upper = String(character).uppercased(with: locale)
        if upper == "İ" && ["tr", "az"].contains(locale.language.languageCode?.identifier) {
            return upper
        }
        // The base letter: without accents (É is E), and without the marks that folding keeps (أ is ا).
        let folded = upper.folding(options: .diacriticInsensitive, locale: nil).decomposedStringWithCanonicalMapping
        guard let base = folded.unicodeScalars.first, Character(base).isLetter else {
            return "#"
        }
        return String(base)
    }

    // MARK: Scripts without a small alphabet

    /// The 14 basic consonants of the Korean index; a tensed consonant (ㄲ, ㄸ, ㅃ, ㅆ, ㅉ) is under its base.
    private nonisolated static let hangulInitials: [String] = ["ㄱ", "ㄱ", "ㄴ", "ㄷ", "ㄷ", "ㄹ", "ㅁ", "ㅂ", "ㅂ", "ㅅ", "ㅅ", "ㅇ", "ㅈ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
    private nonisolated static let hangulCompatibilityInitials: [Unicode.Scalar: String] = [
        "ㄱ": "ㄱ", "ㄲ": "ㄱ", "ㄴ": "ㄴ", "ㄷ": "ㄷ", "ㄸ": "ㄷ", "ㄹ": "ㄹ", "ㅁ": "ㅁ", "ㅂ": "ㅂ", "ㅃ": "ㅂ",
        "ㅅ": "ㅅ", "ㅆ": "ㅅ", "ㅇ": "ㅇ", "ㅈ": "ㅈ", "ㅉ": "ㅈ", "ㅊ": "ㅊ", "ㅋ": "ㅋ", "ㅌ": "ㅌ", "ㅍ": "ㅍ", "ㅎ": "ㅎ",
    ]

    private nonisolated static func hangulInitial(of scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0xAC00...0xD7A3:
            // A precomposed syllable is 0xAC00 + (initial × 21 + vowel) × 28 + final.
            return hangulInitials[Int(scalar.value - 0xAC00) / 588]
        default:
            return hangulCompatibilityInitials[scalar]
        }
    }

    /// The rows of the kana table (あ, か, さ, …, わ), in hiragana, with their voiced and small kana.
    private nonisolated static let kanaRows: [(head: String, kana: String)] = [
        ("あ", "ぁあぃいぅうぇえぉおゔ"), ("か", "かがきぎくぐけげこごゕゖ"), ("さ", "さざしじすずせぜそぞ"),
        ("た", "ただちぢっつづてでとど"), ("な", "なにぬねの"), ("は", "はばぱひびぴふぶぷへべぺほぼぽ"),
        ("ま", "まみむめも"), ("や", "ゃやゅゆょよ"), ("ら", "らりるれろ"), ("わ", "ゎわゐゑをん"),
    ]

    private nonisolated static func kanaRow(of scalar: Unicode.Scalar) -> String? {
        var value = scalar.value
        // Katakana ァ…ヶ are the hiragana ぁ…ゖ moved by 0x60.
        if (0x30A1...0x30F6).contains(value) {
            value -= 0x60
        }
        guard (0x3041...0x3096).contains(value), let hiragana = Unicode.Scalar(value) else {
            return nil
        }
        let character = Character(hiragana)
        return kanaRows.first { $0.kana.contains(character) }?.head
    }

    private nonisolated static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.first?.properties.isIdeographic == true
    }

    private nonisolated static func isJapanese(_ locale: Locale) -> Bool {
        locale.language.languageCode == .japanese
    }

    /// "H" for 湖: the first letter of the Mandarin reading.
    private nonisolated static func pinyinInitial(of character: Character) -> String? {
        let latin = NSMutableString(string: String(character))
        guard CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false),
              CFStringTransform(latin, nil, kCFStringTransformStripDiacritics, false),
              let letter = (latin as String).first, letter.isASCII, letter.isLetter
        else {
            return nil
        }
        return letter.uppercased()
    }

    /// "にっぽん" for 日本テレビ: the reading of the first word of a Japanese name, in hiragana.
    private nonisolated static func japaneseReading(of name: String) -> String? {
        let range = CFRange(location: 0, length: (name as NSString).length)
        let tokenizer = CFStringTokenizerCreate(nil, name as CFString, range, kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        guard !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty,
              let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
        else {
            return nil
        }
        let reading = NSMutableString(string: latin)
        CFStringTransform(reading, nil, kCFStringTransformLatinHiragana, false)
        return reading as String
    }
}

/// Remembers, per category and order, the first row the user saw, so coming back to a category scrolls to
/// where they left it. Kept in the app's defaults (row offsets and group names only, at most `capacity`).
@MainActor
enum CategoryPositionMemory {

    private static let storageKey = "browse.categoryPositions"
    private static let capacity = 60

    static func key(for request: CategoryChannelsModel.Request) -> String {
        "\(request.importID.uuidString)|\(request.groupName)|\(request.order.rawValue)"
    }

    static func offset(for request: CategoryChannelsModel.Request) -> Int? {
        let stored = UserDefaults.fluxo.dictionary(forKey: storageKey) as? [String: Int]
        return stored?[key(for: request)]
    }

    static func save(_ offset: Int, for request: CategoryChannelsModel.Request) {
        let defaults = UserDefaults.fluxo
        var stored = (defaults.dictionary(forKey: storageKey) as? [String: Int]) ?? [:]
        let key = key(for: request)
        guard stored[key] != offset else {
            return
        }
        if offset <= 0 {
            stored[key] = nil
        } else {
            if stored.count >= capacity, stored[key] == nil, let evicted = stored.keys.sorted().first {
                stored[evicted] = nil
            }
            stored[key] = offset
        }
        defaults.set(stored, forKey: storageKey)
    }
}
