//
//  ChannelContentKind.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation

/// What a playlist entry is, for the Home sections (Live TV / Movies / Series).
///
/// M3U has no standard field for this, so the kind is guessed once at import time from the stream URL
/// (Xtream Codes style `/movie/` and `/series/` paths, file extensions) and from the group and entry names.
/// The raw values are stored in SwiftData: never renumber them.
enum ChannelContentKind: Int, CaseIterable, Identifiable, Sendable {
    case live = 0
    case movie = 1
    case series = 2

    var id: Int {
        rawValue
    }

    var title: String {
        switch self {
        case .live:
            return String(localized: "Live TV", comment: "Content type: live television channels. Used as a picker segment and a title.")
        case .movie:
            return String(localized: "Movies", comment: "Content type: on-demand movies. Used as a picker segment and a title.")
        case .series:
            return String(localized: "Series", comment: "Content type: on-demand TV series. Used as a picker segment and a title.")
        }
    }

    /// The kind in segmented controls (the search scopes, the Favorites filter, the Home picker). They give every
    /// segment the same share of the width, about 80 points each on a small iPhone, so translations may use a
    /// shorter word with the same meaning here ("Эфир" for "Прямой эфир"); `title` stays the full name.
    var segmentTitle: String {
        switch self {
        case .live:
            return String(localized: "Live TV (segment)", defaultValue: "Live TV", comment: "Content type: live television channels, as one of 3 or 4 equal segments of a picker (with All, Movies, Series). Keep it short, about 10 characters: a shorter word with the same meaning (such as Live) is fine.")
        case .movie, .series:
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .live:
            return "dot.radiowaves.left.and.right"
        case .movie:
            return "film"
        case .series:
            return "play.rectangle.on.rectangle"
        }
    }

    /// On-demand items are shown as posters, live channels as landscape logo cards.
    var usesPosterArtwork: Bool {
        self != .live
    }

    /// Containers of on-demand files. Anything else (no extension, `.ts`, `.m3u8`, ...) is treated as live.
    private static let onDemandExtensions: Set<String> = [
        "mp4", "m4v", "mkv", "mov", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "ogv", "divx", "xvid",
    ]

    private static let seriesGroupKeywords = ["series", "serie", "séries", "seriale", "tv show", "tv-show", "shows", "episod"]

    /// Classifies an entry. Cheap enough to run for every entry of a large playlist: the name scan only
    /// runs for on-demand URLs and the group keywords are matched once per call on a lowercased copy.
    static func classify(url: URL?, groupName: String, name: String?) -> ChannelContentKind {
        guard let url else {
            return .live
        }
        let path = url.path.lowercased()
        if path.contains("/series/") {
            return .series
        }
        if path.contains("/movie/") || path.contains("/movies/") || path.contains("/vod/") {
            return .movie
        }
        guard onDemandExtensions.contains(url.pathExtension.lowercased()) else {
            return .live
        }
        if let name, containsEpisodeMarker(name) {
            return .series
        }
        let group = groupName.lowercased()
        if seriesGroupKeywords.contains(where: { group.contains($0) }) {
            return .series
        }
        return .movie
    }

    /// Kind of a group: the most common kind of its channels (live wins ties, then movies).
    static func dominant(live: Int, movie: Int, series: Int) -> ChannelContentKind {
        if live >= movie && live >= series {
            return .live
        }
        return movie >= series ? .movie : .series
    }

    /// Finds an `S01E02` / `s1 e2` style episode marker without a regular expression.
    static func containsEpisodeMarker(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index] | 0x20 // ASCII lowercase
            guard byte == UInt8(ascii: "s"), index == 0 || !isLetter(bytes[index - 1]) else {
                index += 1
                continue
            }
            var cursor = index + 1
            let seasonStart = cursor
            while cursor < bytes.count, isDigit(bytes[cursor]) {
                cursor += 1
            }
            guard cursor > seasonStart, cursor - seasonStart <= 2 else {
                index += 1
                continue
            }
            while cursor < bytes.count, bytes[cursor] == UInt8(ascii: " ") || bytes[cursor] == UInt8(ascii: ".") {
                cursor += 1
            }
            guard cursor < bytes.count, bytes[cursor] | 0x20 == UInt8(ascii: "e") else {
                index += 1
                continue
            }
            cursor += 1
            if cursor < bytes.count, isDigit(bytes[cursor]) {
                return true
            }
            index += 1
        }
        return false
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        let lower = byte | 0x20
        return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z")
    }
}
