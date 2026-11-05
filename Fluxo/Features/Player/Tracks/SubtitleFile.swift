//
//  SubtitleFile.swift
//  Fluxo
//
//  Reads an external subtitle file the user picks for a movie or an episode: SubRip (.srt) and WebVTT (.vtt).
//
//  - Encodings: UTF-8 (with or without a byte order mark), UTF-16 with a byte order mark, and, for the many
//    SubRip files that are not UTF-8, Windows-1252 (which also reads Latin-1).
//  - Times: `00:01:02,500` and `00:01:02.500`, hours optional (WebVTT `01:02.500`), extra cue settings ignored.
//  - Text: <i>, <b> and <u> become italic, bold and underlined runs; other tags (<font>, WebVTT classes and
//    voices, karaoke timestamps) and SubRip / ASS position codes ({\an8}) are dropped; entities are decoded.
//
//  Parsing is pure and runs off the main actor.
//

import Foundation

struct SubtitleCue: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: AttributedString
}

struct SubtitleFile: Sendable {

    enum Format: Sendable {
        case subRip
        case webVTT
    }

    enum ParseError: LocalizedError {
        case unreadable
        case noCues

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return String(localized: "The file isn't a text subtitle file.", comment: "Error when loading a subtitle file: its text cannot be read.")
            case .noCues:
                return String(localized: "The file has no subtitles Fluxo can read. Use a SubRip (.srt) or WebVTT (.vtt) file.", comment: "Error when loading a subtitle file that has no subtitle lines.")
            }
        }
    }

    /// The largest subtitle file read (a feature film is about 100 KB).
    static let maximumSize = 8 * 1024 * 1024
    static let fileExtensions = ["srt", "vtt"]

    let cues: [SubtitleCue]

    init(cues: [SubtitleCue]) {
        self.cues = cues
    }

    init(data: Data, fileExtension: String? = nil) throws {
        guard data.count <= Self.maximumSize, let text = Self.decode(data) else {
            throw ParseError.unreadable
        }
        let format: Format = text.hasPrefix("WEBVTT") || fileExtension?.lowercased() == "vtt" ? .webVTT : .subRip
        let cues = Self.parse(text, format: format)
        guard !cues.isEmpty else {
            throw ParseError.noCues
        }
        self.cues = cues
    }

    // MARK: - Decoding

    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        var text: String?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            text = String(data: data, encoding: .utf16LittleEndian).map { String($0.drop { $0 == "\u{FEFF}" }) }
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16BigEndian).map { String($0.drop { $0 == "\u{FEFF}" }) }
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
        }
        guard let text, !text.contains("\u{0}") else {
            return nil
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Parsing

    /// The cue blocks of `text`: its lines, trimmed, split at the lines that are empty once trimmed.
    static func blocks(of text: String) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty {
            blocks.append(current)
        }
        return blocks
    }

    static func parse(_ text: String, format: Format) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        // Cue blocks are separated by blank lines (which may hold spaces or tabs in files from the wild).
        for lines in blocks(of: text) {
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            if format == .webVTT, let first = lines.first, first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") {
                continue
            }
            guard let (start, end) = timing(lines[timingIndex]), end > start else {
                continue
            }
            let body = lines[(timingIndex + 1)...].filter { !$0.isEmpty }.joined(separator: "\n")
            let attributed = styledText(body)
            guard !attributed.characters.isEmpty else {
                continue
            }
            cues.append(SubtitleCue(start: start, end: end, text: attributed))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:00:01,000 --> 00:00:04,000 align:start" → (1, 4).
    static func timing(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = time(parts[0].trimmingCharacters(in: .whitespaces)),
              let endText = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
              let end = time(String(endText)) else {
            return nil
        }
        return (start, end)
    }

    /// "01:02:03,456", "01:02:03.456", "02:03.456", "01:02:03" → seconds.
    static func time(_ text: String) -> TimeInterval? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        let fields = normalized.split(separator: ":")
        guard (2...3).contains(fields.count) else {
            return nil
        }
        var seconds: TimeInterval = 0
        for (index, field) in fields.enumerated() {
            let isLast = index == fields.count - 1
            guard let value = isLast ? TimeInterval(field) : TimeInterval(Int(field) ?? -1), value >= 0 else {
                return nil
            }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// The cue text with <i>, <b> and <u> applied, other tags removed and entities decoded.
    static func styledText(_ text: String) -> AttributedString {
        var result = AttributedString()
        var italic = false
        var bold = false
        var underline = false
        var run = ""

        func flush() {
            guard !run.isEmpty else {
                return
            }
            var piece = AttributedString(decodeEntities(run))
            var intent: InlinePresentationIntent = []
            if italic {
                intent.insert(.emphasized)
            }
            if bold {
                intent.insert(.stronglyEmphasized)
            }
            if !intent.isEmpty {
                piece.inlinePresentationIntent = intent
            }
            if underline {
                piece.underlineStyle = .single
            }
            result += piece
            run = ""
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "<", let close = text[index...].firstIndex(of: ">") {
                let tag = text[text.index(after: index)..<close].lowercased()
                let closing = tag.hasPrefix("/")
                let name = closing ? String(tag.dropFirst()) : tag
                let base = name.split(whereSeparator: { $0 == " " || $0 == "." }).first.map(String.init) ?? name
                if ["i", "b", "u"].contains(base) {
                    flush()
                    switch base {
                    case "i": italic = !closing
                    case "b": bold = !closing
                    default: underline = !closing
                    }
                }
                index = text.index(after: close)
                continue
            }
            if character == "{", text[index...].dropFirst().first == "\\", let close = text[index...].firstIndex(of: "}") {
                index = text.index(after: close)
                continue
            }
            run.append(character)
            index = text.index(after: index)
        }
        flush()
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else {
            return text
        }
        // In a fixed order, "&amp;" last: "&amp;lt;" is the text "&lt;", not "<".
        let entities: KeyValuePairs = ["&lt;": "<", "&gt;": ">", "&nbsp;": "\u{00A0}", "&lrm;": "\u{200E}", "&rlm;": "\u{200F}", "&quot;": "\"", "&apos;": "'", "&amp;": "&"]
        var decoded = text
        for (entity, value) in entities {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }
        return decoded
    }

    // MARK: - Lookup

    /// The cues shown at `time` (several when they overlap), in start order.
    func cues(at time: TimeInterval) -> [SubtitleCue] {
        // Binary search for the first cue that starts after `time`; overlapping cues are a few before it.
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var active: [SubtitleCue] = []
        var index = low - 1
        // Cues are short: looking back 20 is plenty for overlaps.
        while index >= 0 && index >= low - 20 {
            let cue = cues[index]
            if cue.end > time {
                active.insert(cue, at: 0)
            }
            index -= 1
        }
        return active
    }

    /// Every time at which what shows changes (each start and end), sorted, for a boundary time observer.
    var changeTimes: [TimeInterval] {
        Array(Set(cues.flatMap { [$0.start, $0.end] })).sorted()
    }
}
