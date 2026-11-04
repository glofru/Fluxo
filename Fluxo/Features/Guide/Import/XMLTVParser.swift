//
//  XMLTVParser.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation

/// A `<channel>` element.
struct XMLTVChannel: Sendable, Equatable {
    var id: String
    var displayNames: [String] = []
    var icon: String?
}

/// A `<programme>` element.
struct XMLTVProgramme: Sendable, Equatable {
    var channelID: String
    var start: Date
    var stop: Date
    var title: String = ""
    var subtitle: String = ""
    var summary: String = ""
    var categories: [String] = []
    var icon: String?
    var episode: String?
}

/// Streaming XMLTV reader on top of `XMLParser` (SAX): elements are delivered as they are read, so the size of
/// the guide does not matter for memory.
///
/// - Programmes outside `window` and programmes of channels `wantsChannel` rejects are skipped without
///   collecting their text.
/// - A programme without a `stop` ends where the next programme of the same channel starts (or after an hour if
///   it is the last one).
/// - Text is trimmed and long descriptions are capped at `maxSummaryLength` characters.
/// - External entities and the DTD are never loaded.
final class XMLTVParser: NSObject, XMLParserDelegate {

    static let maxSummaryLength = 1_500
    static let maxCategories = 4
    /// Length of a programme that has no stop time and no following programme.
    static let fallbackDuration: TimeInterval = 3_600

    struct Statistics: Sendable {
        var channels = 0
        var programmes = 0
        var keptProgrammes = 0
        var skippedOutsideWindow = 0
        var skippedUnwantedChannel = 0
        var invalidProgrammes = 0
    }

    private let window: DateInterval
    private let wantsChannel: (XMLTVChannel) -> Bool
    private let wantsChannelID: (String) -> Bool
    private let onChannel: (XMLTVChannel, Bool) -> Void
    private let onProgramme: (XMLTVProgramme) -> Void
    private let isCancelled: () -> Bool

    private(set) var statistics = Statistics()
    /// The XML ended with an error after channels or programmes were read: they were delivered, but the guide is
    /// incomplete.
    private(set) var endedEarly = false

    private enum Field {
        case displayName
        case title
        case subtitle
        case summary
        case category
        case episode(system: String)
    }

    private var channel: XMLTVChannel?
    private var programme: XMLTVProgramme?
    /// Whether the open `<programme>` lacks a stop attribute.
    private var programmeIsOpenEnded = false
    private var field: Field?
    private var text = ""
    private var hasOnscreenEpisode = false
    private var wantedChannelIDs: Set<String> = []
    private var rejectedChannelIDs: Set<String> = []
    /// Open-ended programmes waiting for the next programme of their channel.
    private var openEnded: [String: XMLTVProgramme] = [:]
    private var callbackCount = 0

    /// - Parameters:
    ///   - wantsChannel: whether to keep programmes of a `<channel>` (called once per channel).
    ///   - wantsChannelID: fallback for programmes whose channel was not declared before them.
    ///   - onChannel: every channel, with the `wantsChannel` decision.
    ///   - onProgramme: every kept programme.
    init(
        window: DateInterval,
        wantsChannel: @escaping (XMLTVChannel) -> Bool,
        wantsChannelID: @escaping (String) -> Bool,
        onChannel: @escaping (XMLTVChannel, Bool) -> Void,
        onProgramme: @escaping (XMLTVProgramme) -> Void,
        isCancelled: @escaping () -> Bool = { false }
    ) {
        self.window = window
        self.wantsChannel = wantsChannel
        self.wantsChannelID = wantsChannelID
        self.onChannel = onChannel
        self.onProgramme = onProgramme
        self.isCancelled = isCancelled
    }

    /// Parses the whole stream synchronously. Throws the parser error, or `CancellationError` when
    /// `isCancelled` became true.
    func parse(_ stream: InputStream) throws {
        let parser = XMLParser(stream: stream)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        let succeeded = parser.parse()
        flushOpenEnded()
        if isCancelled() {
            throw CancellationError()
        }
        if !succeeded, let error = parser.parserError {
            // A guide cut short after many programmes may still be useful (the caller decides); only fail if
            // nothing was read.
            if statistics.keptProgrammes == 0 && statistics.channels == 0 {
                throw error
            }
            endedEarly = true
        }
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        callbackCount &+= 1
        if callbackCount & 0x3FF == 0, isCancelled() {
            parser.abortParsing()
            return
        }

        switch elementName {
        case "programme":
            startProgramme(attributes)
        case "channel":
            if let id = attributes["id"], !id.isEmpty {
                channel = XMLTVChannel(id: id)
            }
        case "display-name" where channel != nil:
            beginText(.displayName)
        case "icon":
            if let source = attributes["src"], !source.isEmpty {
                if programme != nil {
                    if programme?.icon == nil {
                        programme?.icon = source
                    }
                } else if channel != nil, channel?.icon == nil {
                    channel?.icon = source
                }
            }
        case "title" where programme != nil:
            beginText(.title)
        case "sub-title" where programme != nil:
            beginText(.subtitle)
        case "desc" where programme != nil:
            beginText(.summary)
        case "category" where programme != nil:
            beginText(.category)
        case "episode-num" where programme != nil:
            beginText(.episode(system: attributes["system"] ?? ""))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard field != nil else {
            return
        }
        // utf8.count is O(1); a description is cut at maxSummaryLength characters in endText anyway.
        if case .summary = field, text.utf8.count > Self.maxSummaryLength * 4 {
            return
        }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard field != nil, let string = String(data: CDATABlock, encoding: .utf8) else {
            return
        }
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "programme":
            endProgramme()
        case "channel":
            if let channel {
                statistics.channels += 1
                let wanted = wantsChannel(channel)
                if wanted {
                    wantedChannelIDs.insert(channel.id)
                } else {
                    rejectedChannelIDs.insert(channel.id)
                }
                onChannel(channel, wanted)
            }
            channel = nil
        case "display-name", "title", "sub-title", "desc", "category", "episode-num":
            endText()
        default:
            break
        }
    }

    // MARK: - Programmes

    private func startProgramme(_ attributes: [String: String]) {
        statistics.programmes += 1
        guard let channelID = attributes["channel"], !channelID.isEmpty,
              let startValue = attributes["start"], let start = Self.date(fromXMLTV: startValue) else {
            statistics.invalidProgrammes += 1
            return
        }
        let stop = attributes["stop"].flatMap(Self.date(fromXMLTV:))

        let wanted: Bool
        if wantedChannelIDs.contains(channelID) {
            wanted = true
        } else if rejectedChannelIDs.contains(channelID) {
            wanted = false
        } else {
            wanted = wantsChannelID(channelID)
        }
        guard wanted else {
            statistics.skippedUnwantedChannel += 1
            return
        }

        // Close a pending open-ended programme of this channel.
        if var previous = openEnded.removeValue(forKey: channelID) {
            previous.stop = max(previous.start, start)
            emit(previous)
        }

        // Skip programmes that are entirely outside the window. Open-ended ones are decided when they end.
        if let stop {
            guard stop > window.start, start < window.end, stop > start else {
                statistics.skippedOutsideWindow += 1
                return
            }
        } else if start >= window.end {
            statistics.skippedOutsideWindow += 1
            return
        }
        programme = XMLTVProgramme(channelID: channelID, start: start, stop: stop ?? start)
        programmeIsOpenEnded = stop == nil
        hasOnscreenEpisode = false
    }

    private func endProgramme() {
        guard var programme else {
            return
        }
        self.programme = nil
        // A programme without a title keeps an empty one: the guide is stored, and "Untitled" is shown in the
        // language of the moment (`GuideProgramme.init(_:)`).
        if programme.title.isEmpty {
            programme.title = programme.subtitle
        }
        if programmeIsOpenEnded {
            openEnded[programme.channelID] = programme
        } else {
            emit(programme)
        }
    }

    private func emit(_ programme: XMLTVProgramme) {
        guard programme.stop > window.start, programme.start < window.end, programme.stop > programme.start else {
            statistics.skippedOutsideWindow += 1
            return
        }
        statistics.keptProgrammes += 1
        onProgramme(programme)
    }

    private func flushOpenEnded() {
        for var programme in openEnded.values {
            programme.stop = programme.start.addingTimeInterval(Self.fallbackDuration)
            emit(programme)
        }
        openEnded.removeAll()
    }

    // MARK: - Text

    private func beginText(_ field: Field) {
        self.field = field
        text.removeAll(keepingCapacity: true)
    }

    private func endText() {
        guard let field else {
            return
        }
        self.field = nil
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }
        switch field {
        case .displayName:
            channel?.displayNames.append(value)
        case .title:
            if programme?.title.isEmpty == true {
                programme?.title = value
            }
        case .subtitle:
            if programme?.subtitle.isEmpty == true {
                programme?.subtitle = value
            }
        case .summary:
            if programme?.summary.isEmpty == true {
                programme?.summary = value.count > Self.maxSummaryLength ? String(value.prefix(Self.maxSummaryLength)) + "…" : value
            }
        case .category:
            if let count = programme?.categories.count, count < Self.maxCategories, programme?.categories.contains(value) == false {
                programme?.categories.append(value)
            }
        case .episode(let system):
            if system == "onscreen" {
                programme?.episode = value
                hasOnscreenEpisode = true
            } else if !hasOnscreenEpisode, system == "xmltv_ns", let readable = Self.episode(fromXMLTVNS: value) {
                programme?.episode = readable
            }
        }
    }

    // MARK: - Values

    /// "0.4.0/1" (zero-based season . episode . part) → "S1 E5", "E5" or "S1".
    ///
    /// This form is stored, so it is the same in every language; `GuideFormat.episode(_:)` localizes it when it
    /// is shown.
    static func episode(fromXMLTVNS value: String) -> String? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        func number(_ index: Int) -> Int? {
            guard index < parts.count, let first = parts[index].split(separator: "/").first, let value = Int(first.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return value + 1
        }
        switch (number(0), number(1)) {
        case let (season?, episode?):
            return "S\(season) E\(episode)"
        case (nil, let episode?):
            return "E\(episode)"
        case (let season?, nil):
            return "S\(season)"
        default:
            return nil
        }
    }

    /// XMLTV date: `YYYYMMDDhhmmss ±hhmm`. Seconds, minutes and hours may be missing, and so may the zone
    /// (the XMLTV DTD defines UTC then). Parsed by hand: this runs for every programme.
    static func date(fromXMLTV value: String) -> Date? {
        var utf8 = Array(value.utf8)
        // Drop trailing blanks.
        while let last = utf8.last, last == 0x20 || last == 0x09 {
            utf8.removeLast()
        }
        var index = 0
        func digits(_ count: Int) -> Int? {
            guard index + count <= utf8.count else {
                return nil
            }
            var result = 0
            for offset in 0..<count {
                let byte = utf8[index + offset]
                guard byte >= 0x30 && byte <= 0x39 else {
                    return nil
                }
                result = result * 10 + Int(byte - 0x30)
            }
            index += count
            return result
        }
        guard let year = digits(4), let month = digits(2), let day = digits(2), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        let hour = digits(2) ?? 0
        let minute = digits(2) ?? 0
        let second = digits(2) ?? 0
        guard hour < 24, minute < 60, second < 61 else {
            return nil
        }

        var offsetSeconds = 0
        while index < utf8.count, utf8[index] == 0x20 {
            index += 1
        }
        if index < utf8.count, utf8[index] == 0x2B || utf8[index] == 0x2D {
            let sign = utf8[index] == 0x2D ? -1 : 1
            index += 1
            if let zoneHours = digits(2) {
                if index < utf8.count, utf8[index] == 0x3A {
                    index += 1
                }
                let zoneMinutes = digits(2) ?? 0
                offsetSeconds = sign * (zoneHours * 3_600 + zoneMinutes * 60)
            }
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
