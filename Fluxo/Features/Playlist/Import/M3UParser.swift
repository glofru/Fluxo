//
//  M3UParser.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation

/// One playable entry of an M3U playlist.
struct M3UEntry: Sendable, Equatable {
    var title: String?
    var url: String
    var tvgID: String?
    var tvgName: String?
    var logo: String?
    var group: String?
    var duration: Int?

    /// Name to show to the user: the EXTINF title, falling back to tvg-name.
    var displayName: String? {
        if let title, !title.isEmpty {
            return title
        }
        return tvgName
    }
}

/// Incremental, allocation-light M3U / M3U8 parser.
///
/// Feed it chunks of bytes as they arrive from the network with `consume(_:emit:)` and call
/// `finish(emit:)` once at the end. Lines are split on `\n` and `\r` (so LF, CRLF and CR files work),
/// a leading UTF-8 BOM and a missing `#EXTM3U` header are tolerated, and only the attributes the app
/// uses are decoded into `String`s.
///
/// `#EXTINF` grammar handled: `#EXTINF:<duration> key="value with spaces" key=value ...,<title>`.
/// The title starts after the first comma that follows the attribute block, so titles may contain commas,
/// and quoted attribute values may contain spaces and commas.
struct M3UParser {

    private(set) var entryCount = 0
    private(set) var sawHeader = false
    /// XMLTV guide URLs announced by the `#EXTM3U` header (`url-tvg`, `x-tvg-url` or `tvg-url`; each may hold
    /// several comma-separated URLs), in order of appearance and without duplicates. Only http(s) URLs are kept.
    private(set) var guideURLs: [String] = []

    /// Bytes of a line that was split across two chunks.
    private var carry: [UInt8] = []
    private var isAtStartOfFile = true
    private var pendingInfo: Info?
    private var pendingGroup: String?

    private struct Info {
        var title: String?
        var tvgID: String?
        var tvgName: String?
        var logo: String?
        var group: String?
        var duration: Int?
    }

    init() {}

    // MARK: - Input

    mutating func consume(_ data: Data, emit: (M3UEntry) throws -> Void) rethrows {
        try data.withUnsafeBytes { raw in
            try consume(UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), count: raw.count), emit: emit)
        }
    }

    mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>, emit: (M3UEntry) throws -> Void) rethrows {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            return
        }
        let count = bytes.count
        var lineStart = 0
        var index = 0

        while index < count {
            let byte = base[index]
            if byte == Byte.lineFeed || byte == Byte.carriageReturn {
                if carry.isEmpty {
                    try handleLine(UnsafeBufferPointer(start: base + lineStart, count: index - lineStart), emit: emit)
                } else {
                    carry.append(contentsOf: UnsafeBufferPointer(start: base + lineStart, count: index - lineStart))
                    try flushCarry(emit: emit)
                }
                lineStart = index + 1
            }
            index += 1
        }

        if lineStart < count {
            carry.append(contentsOf: UnsafeBufferPointer(start: base + lineStart, count: count - lineStart))
        }
    }

    /// Processes the last line if the file does not end with a newline.
    mutating func finish(emit: (M3UEntry) throws -> Void) rethrows {
        try flushCarry(emit: emit)
        pendingInfo = nil
        pendingGroup = nil
    }

    /// Convenience for parsing a complete in-memory playlist.
    static func parse(_ data: Data) -> [M3UEntry] {
        var parser = M3UParser()
        var entries: [M3UEntry] = []
        parser.consume(data) { entries.append($0) }
        parser.finish { entries.append($0) }
        return entries
    }

    private mutating func flushCarry(emit: (M3UEntry) throws -> Void) rethrows {
        guard !carry.isEmpty else {
            return
        }
        let line = carry
        carry.removeAll(keepingCapacity: true)
        try line.withUnsafeBufferPointer { try handleLine($0, emit: emit) }
    }

    // MARK: - Lines

    private mutating func handleLine(_ rawLine: UnsafeBufferPointer<UInt8>, emit: (M3UEntry) throws -> Void) rethrows {
        guard let base = rawLine.baseAddress else {
            return
        }
        var start = 0
        var end = rawLine.count

        if isAtStartOfFile {
            isAtStartOfFile = false
            if end >= 3, base[0] == 0xEF, base[1] == 0xBB, base[2] == 0xBF {
                start = 3
            }
        }

        while start < end, Byte.isBlank(base[start]) {
            start += 1
        }
        while end > start, Byte.isBlank(base[end - 1]) {
            end -= 1
        }
        guard start < end else {
            return
        }

        let line = UnsafeBufferPointer(start: base + start, count: end - start)

        if line[0] == Byte.hash {
            if Self.hasPrefix(line, Tag.extinf) {
                pendingInfo = Self.parseInfo(UnsafeBufferPointer(rebasing: line[Tag.extinf.count...]))
            } else if Self.hasPrefix(line, Tag.extgrp) {
                let value = Self.trimmed(UnsafeBufferPointer(rebasing: line[Tag.extgrp.count...]))
                pendingGroup = value.isEmpty ? nil : Self.string(value)
            } else if Self.hasPrefix(line, Tag.extm3u) {
                sawHeader = true
                addGuideURLs(fromHeader: UnsafeBufferPointer(rebasing: line[Tag.extm3u.count...]))
            }
            return
        }

        // A URI line: with a preceding #EXTINF anything goes (relative paths included);
        // without one, only accept something that looks like an absolute URL so that HTML error pages
        // and other junk do not turn into channels.
        guard pendingInfo != nil || Self.looksLikeAbsoluteURL(line) else {
            return
        }

        let info = pendingInfo
        let entry = M3UEntry(
            title: info?.title,
            url: Self.string(line),
            tvgID: info?.tvgID,
            tvgName: info?.tvgName,
            logo: info?.logo,
            group: info?.group ?? pendingGroup,
            duration: info?.duration
        )
        pendingInfo = nil
        pendingGroup = nil
        entryCount += 1
        try emit(entry)
    }

    // MARK: - #EXTM3U

    /// Collects the guide URLs of a header such as `#EXTM3U url-tvg="https://a/epg.xml.gz,https://b/epg.xml"`.
    /// Unlike `#EXTINF`, the header has no title, so commas are part of an unquoted value.
    private mutating func addGuideURLs(fromHeader bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress else {
            return
        }
        let end = bytes.count
        var index = 0
        while index < end {
            while index < end, Byte.isBlank(base[index]) {
                index += 1
            }
            let keyStart = index
            while index < end, base[index] != Byte.equals, !Byte.isBlank(base[index]) {
                index += 1
            }
            let key = UnsafeBufferPointer(start: base + keyStart, count: index - keyStart)
            guard index < end, base[index] == Byte.equals else {
                continue
            }
            index += 1

            let valueStart: Int
            let valueEnd: Int
            if index < end, base[index] == Byte.doubleQuote || base[index] == Byte.singleQuote {
                let quote = base[index]
                index += 1
                valueStart = index
                while index < end, base[index] != quote {
                    index += 1
                }
                valueEnd = index
                index = min(end, index + 1)
            } else {
                valueStart = index
                while index < end, !Byte.isBlank(base[index]) {
                    index += 1
                }
                valueEnd = index
            }

            guard Self.equalsIgnoringCase(key, Key.urlTvg) || Self.equalsIgnoringCase(key, Key.xTvgURL) || Self.equalsIgnoringCase(key, Key.tvgURL) else {
                continue
            }
            let value = Self.string(UnsafeBufferPointer(start: base + valueStart, count: valueEnd - valueStart))
            for part in value.split(separator: ",") {
                let candidate = part.trimmingCharacters(in: .whitespaces)
                let lowercased = candidate.lowercased()
                guard lowercased.hasPrefix("https://") || lowercased.hasPrefix("http://"), !guideURLs.contains(candidate) else {
                    continue
                }
                guideURLs.append(candidate)
            }
        }
    }

    // MARK: - #EXTINF

    private static func parseInfo(_ bytes: UnsafeBufferPointer<UInt8>) -> Info {
        var info = Info()
        guard let base = bytes.baseAddress else {
            return info
        }
        let end = bytes.count
        var index = 0

        func skipBlanks() {
            while index < end, Byte.isBlank(base[index]) {
                index += 1
            }
        }

        // Duration: [+-]digits[.digits]
        skipBlanks()
        var negative = false
        if index < end, base[index] == Byte.minus || base[index] == Byte.plus {
            negative = base[index] == Byte.minus
            index += 1
        }
        var duration = 0
        var hasDigits = false
        while index < end, Byte.isDigit(base[index]) {
            if duration < 100_000_000 {
                duration = duration * 10 + Int(base[index] - Byte.zero)
            }
            hasDigits = true
            index += 1
        }
        if index < end, base[index] == Byte.dot {
            index += 1
            while index < end, Byte.isDigit(base[index]) {
                index += 1
            }
        }
        if hasDigits, !negative {
            info.duration = duration
        }

        // Attributes, then the title after the first comma outside of a quoted value.
        while true {
            skipBlanks()
            guard index < end else {
                break
            }
            if base[index] == Byte.comma {
                let title = trimmed(UnsafeBufferPointer(start: base + index + 1, count: end - index - 1))
                if !title.isEmpty {
                    info.title = string(title)
                }
                break
            }

            let keyStart = index
            while index < end, base[index] != Byte.equals, base[index] != Byte.comma, !Byte.isBlank(base[index]) {
                index += 1
            }
            let key = UnsafeBufferPointer(start: base + keyStart, count: index - keyStart)

            guard index < end, base[index] == Byte.equals else {
                // A bare token without a value: ignore it.
                continue
            }
            index += 1

            let valueStart: Int
            let valueEnd: Int
            if index < end, base[index] == Byte.doubleQuote || base[index] == Byte.singleQuote {
                let quote = base[index]
                index += 1
                valueStart = index
                while index < end, base[index] != quote {
                    index += 1
                }
                if index < end {
                    valueEnd = index
                    index += 1
                } else {
                    // Unterminated quote: the value runs to the next comma (or the end of the line).
                    index = valueStart
                    while index < end, base[index] != Byte.comma {
                        index += 1
                    }
                    valueEnd = index
                }
            } else {
                valueStart = index
                while index < end, base[index] != Byte.comma, !Byte.isBlank(base[index]) {
                    index += 1
                }
                valueEnd = index
            }

            let value = trimmed(UnsafeBufferPointer(start: base + valueStart, count: valueEnd - valueStart))
            guard !value.isEmpty else {
                continue
            }

            switch Attribute(key) {
            case .tvgID:
                info.tvgID = string(value)
            case .tvgName:
                info.tvgName = string(value)
            case .logo:
                if info.logo == nil {
                    info.logo = logoURL(value)
                }
            case .groupTitle:
                info.group = string(value)
            case .none:
                break
            }
        }

        return info
    }

    private enum Attribute {
        case tvgID
        case tvgName
        case logo
        case groupTitle

        init?(_ key: UnsafeBufferPointer<UInt8>) {
            if M3UParser.equalsIgnoringCase(key, Key.tvgID) {
                self = .tvgID
            } else if M3UParser.equalsIgnoringCase(key, Key.tvgName) {
                self = .tvgName
            } else if M3UParser.equalsIgnoringCase(key, Key.tvgLogo) || M3UParser.equalsIgnoringCase(key, Key.logo) {
                self = .logo
            } else if M3UParser.equalsIgnoringCase(key, Key.groupTitle) {
                self = .groupTitle
            } else {
                return nil
            }
        }
    }

    /// Only keep logos that can actually be loaded: absolute http(s) URLs, protocol-relative URLs and data URLs.
    private static func logoURL(_ value: UnsafeBufferPointer<UInt8>) -> String? {
        if hasPrefix(value, Key.https) || hasPrefix(value, Key.http) || hasPrefix(value, Key.data) {
            return string(value)
        }
        if value.count > 2, value[0] == Byte.slash, value[1] == Byte.slash {
            return "https:" + string(value)
        }
        return nil
    }

    // MARK: - Byte helpers

    private static func looksLikeAbsoluteURL(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        // scheme ":" "//" with an alphabetic first character and no blanks in the scheme.
        guard !line.isEmpty, Byte.isAlpha(line[0]) else {
            return false
        }
        var index = 1
        while index < line.count {
            let byte = line[index]
            if byte == Byte.colon {
                return index + 2 < line.count && line[index + 1] == Byte.slash && line[index + 2] == Byte.slash
            }
            guard Byte.isAlpha(byte) || Byte.isDigit(byte) || byte == Byte.plus || byte == Byte.minus || byte == Byte.dot else {
                return false
            }
            index += 1
        }
        return false
    }

    private static func trimmed(_ bytes: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        guard let base = bytes.baseAddress else {
            return bytes
        }
        var start = 0
        var end = bytes.count
        while start < end, Byte.isBlank(base[start]) {
            start += 1
        }
        while end > start, Byte.isBlank(base[end - 1]) {
            end -= 1
        }
        return UnsafeBufferPointer(start: base + start, count: end - start)
    }

    /// ASCII case-insensitive prefix check; `prefix` must be lowercase.
    private static func hasPrefix(_ bytes: UnsafeBufferPointer<UInt8>, _ prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else {
            return false
        }
        for index in 0..<prefix.count where Byte.lowercased(bytes[index]) != prefix[index] {
            return false
        }
        return true
    }

    /// ASCII case-insensitive equality; `other` must be lowercase.
    private static func equalsIgnoringCase(_ bytes: UnsafeBufferPointer<UInt8>, _ other: [UInt8]) -> Bool {
        bytes.count == other.count && hasPrefix(bytes, other)
    }

    /// Decodes UTF-8, falling back to Latin-1 for legacy playlists that are not valid UTF-8.
    private static func string(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        if let string = String(validating: bytes, as: UTF8.self) {
            return string
        }
        return String(bytes.lazy.map { Character(Unicode.Scalar($0)) })
    }

    private enum Tag {
        static let extinf = Array("#extinf:".utf8)
        static let extgrp = Array("#extgrp:".utf8)
        static let extm3u = Array("#extm3u".utf8)
    }

    private enum Key {
        static let tvgID = Array("tvg-id".utf8)
        static let tvgName = Array("tvg-name".utf8)
        static let tvgLogo = Array("tvg-logo".utf8)
        static let logo = Array("logo".utf8)
        static let groupTitle = Array("group-title".utf8)
        static let urlTvg = Array("url-tvg".utf8)
        static let xTvgURL = Array("x-tvg-url".utf8)
        static let tvgURL = Array("tvg-url".utf8)
        static let https = Array("https://".utf8)
        static let http = Array("http://".utf8)
        static let data = Array("data:".utf8)
    }

    private enum Byte {
        static let lineFeed = UInt8(ascii: "\n")
        static let carriageReturn = UInt8(ascii: "\r")
        static let space = UInt8(ascii: " ")
        static let tab = UInt8(ascii: "\t")
        static let hash = UInt8(ascii: "#")
        static let comma = UInt8(ascii: ",")
        static let equals = UInt8(ascii: "=")
        static let doubleQuote = UInt8(ascii: "\"")
        static let singleQuote = UInt8(ascii: "'")
        static let minus = UInt8(ascii: "-")
        static let plus = UInt8(ascii: "+")
        static let dot = UInt8(ascii: ".")
        static let colon = UInt8(ascii: ":")
        static let slash = UInt8(ascii: "/")
        static let zero = UInt8(ascii: "0")

        @inline(__always)
        static func isBlank(_ byte: UInt8) -> Bool {
            byte == space || byte == tab
        }

        @inline(__always)
        static func isDigit(_ byte: UInt8) -> Bool {
            byte >= zero && byte <= UInt8(ascii: "9")
        }

        @inline(__always)
        static func isAlpha(_ byte: UInt8) -> Bool {
            let lower = byte | 0x20
            return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z")
        }

        @inline(__always)
        static func lowercased(_ byte: UInt8) -> UInt8 {
            byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
        }
    }
}
