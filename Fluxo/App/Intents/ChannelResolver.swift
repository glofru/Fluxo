//
//  ChannelResolver.swift
//  Fluxo
//
//  Turns free words ("Sky Sport F1", "Rai Uno", "channel 5", "the Formula 1 race") into the channel to play, for
//  "Play … in Fluxo" (`PlayByNameIntent`) and anything else that gets a name rather than an entity. Shared with
//  the debug harness (`intent:` routes), so what is checked there is what Siri runs.
//

import Foundation
import SwiftData

/// What a spoken name resolved to.
struct ChannelResolution: Sendable {

    enum Reason: Sendable, Equatable {
        /// Every word of the term is in the channel's name.
        case name
        /// A programme on air with that title.
        case programme(GuideProgramme)
        /// "channel 5", "5": the position in the playlist.
        case number(Int)
        /// The best typo-tolerant match.
        case closest
    }

    let item: ChannelItem
    let reason: Reason
}

extension AppServices {

    /// The channel `term` names, or nil. In this order: a channel whose name has every word of the term (the
    /// user's favorites and recently watched channels first, since several playlists often carry the same channel),
    /// a programme on air with that title, a channel number, then the closest name. Spelled-out numbers count as
    /// digits ("Rai Uno" finds "Rai 1").
    func resolveChannel(_ rawTerm: String, kind: ChannelContentKind? = nil) async -> ChannelResolution? {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let importIDs = allImportIDs()
        guard !term.isEmpty, !importIDs.isEmpty else {
            return nil
        }
        let container = container
        var channels = await LibraryLookup.searchChannels(term, importIDs: importIDs, kind: kind, limit: 12, in: container)
        let digitTerm = ChannelResolver.digitsForNumberWords(term)
        if digitTerm != term {
            for item in await LibraryLookup.searchChannels(digitTerm, importIDs: importIDs, kind: kind, limit: 12, in: container)
            where !channels.contains(where: { $0.bookmarkKey == item.bookmarkKey }) {
                channels.append(item)
            }
        }

        let termKeys = [ChannelNameNormalizer.looseKey(term), ChannelNameNormalizer.looseKey(digitTerm)]
        let termTokenSets = [Set(ChannelNameNormalizer.tokens(term)), Set(ChannelNameNormalizer.tokens(digitTerm))].filter { !$0.isEmpty }
        let fullMatches = channels.filter { channel in
            let tokens = Set(ChannelNameNormalizer.tokens(channel.displayName))
            return termTokenSets.contains { $0.isSubset(of: tokens) } || termKeys.contains(ChannelNameNormalizer.looseKey(channel.displayName))
        }
        if !fullMatches.isEmpty {
            let known = ChannelResolver.knownKeys(in: container)
            // The same name in the user's favorites or history wins; then an exact name; then the search order.
            let exact = fullMatches.filter { termKeys.contains(ChannelNameNormalizer.looseKey($0.displayName)) }
            let pick = fullMatches.first { $0.bookmarkKey.map(known.contains) ?? false }
                ?? exact.first
                ?? fullMatches[0]
            return ChannelResolution(item: pick, reason: .name)
        }

        // A programme on air with that title ("Play the Formula 1 race"). Only titles count: a description that
        // mentions the term is no reason to switch to that channel.
        // The words as said and with digits ("Formula One" and "Formula 1" are both common titles).
        var titleVariants = [ChannelResolver.titleWords(term)]
        if digitTerm != term {
            titleVariants.append(ChannelResolver.titleWords(digitTerm))
        }
        if kind == nil || kind == .live, titleVariants.contains(where: { !$0.isEmpty }), await waitForGuide() {
            for termWords in titleVariants where !termWords.isEmpty {
                let results = await epg.searchProgrammes(termWords.joined(separator: " "), importIDs: importIDs, limit: 20)
                if let onAir = results.first(where: { result in
                    let titleWords = SmartSearchRules.words(result.programme.title)
                    return result.programme.isOnAir(at: .now) && termWords.allSatisfy { word in titleWords.contains { $0.hasPrefix(word) } }
                }) {
                    return ChannelResolution(item: onAir.channel, reason: .programme(onAir.programme))
                }
            }
        }

        if let number = ChannelResolver.channelNumber(in: digitTerm), let item = ChannelResolver.channel(number: number, in: container) {
            return ChannelResolution(item: item, reason: .number(number))
        }

        // A typo-tolerant match, but never one with other numbers: "Eurosport 7" is not "Eurosport 1", and a
        // channel that is not in the library is better reported than replaced.
        return channels
            .first { ChannelResolver.hasNumbers(of: digitTerm, inName: $0.displayName) }
            .map { ChannelResolution(item: $0, reason: .closest) }
    }
}

enum ChannelResolver {

    /// Bookmark keys of the favorites and of the recently watched channels.
    static func knownKeys(in container: ModelContainer) -> Set<String> {
        let bookmarks = LibraryLookup.bookmarks(playlistIDs: nil, historyLimit: 100, favoriteLimit: 200, in: container)
        return Set((bookmarks.favorites + bookmarks.history).compactMap(\.item.bookmarkKey))
    }

    /// The words of a programme title in `term`, without the articles and the words people add around a title
    /// ("the Grand Prix", "the match", "il film"): Siri hands over "the Formula 1 race" for "Play the Formula 1
    /// race in Fluxo". All the words when nothing else is left.
    static func titleWords(_ term: String) -> [String] {
        let words = SmartSearchRules.words(term)
        let significant = words.filter { !titleFillerWords.contains($0) }
        return significant.isEmpty ? words : significant
    }

    /// Articles of the app's languages that use them (not the ones that are also numbers, like "un" or "ein"), and
    /// the generic words said before or after a title.
    private static let titleFillerWords: Set<String> = [
        "the", "a", "an", "show", "programme", "program", "race", "match", "game", "film", "movie",
        "il", "lo", "la", "gli", "le", "l", "partita", "gara",
        "der", "die", "das", "spiel", "rennen",
        "el", "los", "las", "partido", "carrera", "pelicula",
        "les", "course",
        "het",
        "os", "jogo", "corrida",
    ]

    /// The number of "5", "#5", "channel 5", "canale 105", "number 7" or "5チャンネル": one number, alone or with
    /// words that only say "channel" or "number" (`channelNumberWords`). Nil otherwise: "BBC 9" or "Rai 4" name a
    /// channel (found before numbers are tried, or not in the library), not a position in the playlist.
    static func channelNumber(in term: String) -> Int? {
        let runs = numberRuns(term)
        let numbers = runs.filter(\.isNumber)
        let words = runs.filter { !$0.isNumber }
        guard numbers.count == 1, words.count <= 3, let number = Int(numbers[0].text), number > 0,
              words.allSatisfy({ channelNumberWords.contains($0.text) }) else {
            return nil
        }
        return number
    }

    /// Whether every number said in `term` is a number of `name` ("Eurosport 2" has the 2 of "eurosport 2", not
    /// the 7 of "eurosport 7"; "Sky Sport F1" has the 1 of "sky sport f 1"). Spelled-out numbers of the name count.
    static func hasNumbers(of term: String, inName name: String) -> Bool {
        let termNumbers = Set(ChannelNameNormalizer.tokens(term).filter { $0.allSatisfy(isASCIIDigit) }.map(trimmingLeadingZeros))
        guard !termNumbers.isEmpty else {
            return true
        }
        let nameNumbers = Set(ChannelNameNormalizer.tokens(digitsForNumberWords(name)).compactMap { token -> String? in
            let digits = token.reversed().prefix(while: isASCIIDigit)
            return digits.isEmpty ? nil : trimmingLeadingZeros(String(digits.reversed()))
        })
        return termNumbers.isSubset(of: nameNumbers)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func trimmingLeadingZeros(_ digits: String) -> String {
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    /// The term in runs of decimal digits (in any script, as ASCII digits) and runs of other characters, folded;
    /// spaces and "#", ".", ":", "°", "º" separate runs ("n°5", "No.5", "#5", "第5频道", "5번 채널").
    private static func numberRuns(_ term: String) -> [(text: String, isNumber: Bool)] {
        let folded = term.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var runs: [(text: String, isNumber: Bool)] = []
        var current = ""
        var currentIsNumber = false
        func flush() {
            if !current.isEmpty {
                runs.append((current, currentIsNumber))
                current = ""
            }
        }
        for character in folded {
            if character.isWhitespace || "#.:,;-°º'’".contains(character) {
                flush()
                continue
            }
            let digit = character.unicodeScalars.count == 1 && character.unicodeScalars.first?.properties.numericType == .decimal
                ? character.wholeNumberValue : nil
            if !current.isEmpty, (digit != nil) != currentIsNumber {
                flush()
            }
            currentIsNumber = digit != nil
            if let digit {
                current.append(String(digit))
            } else {
                current.append(character)
            }
        }
        flush()
        return runs
    }

    /// The words that only say "channel" or "number" around a channel number, in the app's languages, folded like
    /// `numberRuns` (Siri's language may not be the app's, so they all count). Matching words, not interface text.
    private static let channelNumberWords: Set<String> = [
        // English
        "channel", "chan", "ch", "number", "num", "no", "nr", "station",
        // Italian, Spanish, Portuguese, French
        "canale", "canal", "numero", "n", "chaine",
        // German, Dutch, Polish, Turkish, Indonesian
        "kanal", "sender", "nummer", "kanaal", "zender", "kanał", "numer", "numara", "numarali", "numaralı",
        "saluran", "nomor",
        // Russian, Arabic, Hindi
        "канал", "телеканал", "номер", "№", "قناة", "القناة", "قناه", "رقم", "الرقم", "चैनल", "नंबर", "नम्बर", "संख्या",
        // Japanese, Korean, Chinese
        "チャンネル", "ちゃんねる", "番", "채널", "번", "频道", "頻道", "台", "号", "號", "第",
    ]

    /// The channel at a position (from 1) of the playlist selected on Home, or else of the first playlist.
    static func channel(number: Int, in container: ModelContainer) -> ChannelItem? {
        let playlists = LibraryLookup.visiblePlaylists(in: container)
        let selection = PlaylistSelection(rawValue: UserDefaults.fluxo.string(forKey: PlaylistSelection.storageKey) ?? "")
        var ordered = playlists
        if case .playlist(let uuid) = selection, let index = playlists.firstIndex(where: { $0.playlistID == uuid }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        let context = LibraryLookup.makeContext(container)
        let sortIndex = number - 1
        for playlist in ordered {
            let importID = playlist.importID
            var descriptor = FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.importID == importID && $0.sortIndex == sortIndex })
            descriptor.fetchLimit = 1
            if let channel = try? context.fetch(descriptor).first {
                return ChannelItem(channel)
            }
        }
        return nil
    }

    /// "Rai Uno" → "Rai 1", "canale cinque" → "canale 5": spelled-out numbers from one to twenty, in every language
    /// of the app, as digits. Siri writes small numbers in words in many languages, and its language may not be the
    /// app's.
    static func digitsForNumberWords(_ term: String) -> String {
        let words = term.split(separator: " ", omittingEmptySubsequences: true)
        var changed = false
        let mapped = words.map { word -> String in
            let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if let value = numberWords[folded] {
                changed = true
                return String(value)
            }
            return String(word)
        }
        return changed ? mapped.joined(separator: " ") : term
    }

    /// Spelled-out numbers (1–20) of the app's languages, folded; the interface language wins a word that two
    /// languages use for different numbers.
    private static let numberWords: [String: Int] = {
        var words: [String: Int] = [:]
        let locales = [ChannelSpokenNames.interfaceLocale] + Bundle.main.localizations.filter { $0 != "Base" }.map(Locale.init(identifier:))
        for locale in locales {
            let formatter = NumberFormatter()
            formatter.numberStyle = .spellOut
            formatter.locale = locale
            for value in 1...20 {
                if let word = formatter.string(from: NSNumber(value: value))?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil),
                   !word.contains(" "), words[word] == nil {
                    words[word] = value
                }
            }
        }
        return words
    }()
}
