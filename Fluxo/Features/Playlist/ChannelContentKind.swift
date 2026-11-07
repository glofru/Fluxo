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

    /// A category name without the kind the page already shows: providers often start the names of their on-demand
    /// categories with it ("Serie TV | Drama", "SERIES: Sci-Fi", "Film - Azione"), and next to "Series" or "Movie"
    /// that prefix says nothing ("Drama"). Only a prefix that is the kind's name and nothing else goes (from a short
    /// list in the languages providers use), before the first separator; anything else is left as it is ("Talk Shows
    /// | US", "IT | Rai 1"), and so are live channels' categories, whose prefixes are countries or providers.
    func category(fromGroupName groupName: String) -> String {
        let prefixes: Set<String>
        switch self {
        case .live:
            return groupName
        case .movie:
            prefixes = Self.movieGroupPrefixes
        case .series:
            prefixes = Self.seriesGroupPrefixes
        }
        guard let separator = groupName.range(of: Self.groupPrefixSeparator, options: .regularExpression) else {
            return groupName
        }
        let prefix = groupName[..<separator.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
        let rest = groupName[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, prefixes.contains(prefix) else {
            return groupName
        }
        return rest
    }

    /// The first separator of a category name: a bar, a colon, a bullet or a guillemet (with or without spaces), or a
    /// dash between spaces (not the hyphen of "Sci-Fi").
    private static let groupPrefixSeparator = #"\s*[|\u00A6\u2502:\u2022\u00B7\u00BB\u203A]\s*|\s+[-\u2013\u2014]\s+"#

    private static let seriesGroupPrefixes: Set<String> = [
        "series", "serie", "serie tv", "series tv", "tv series", "tv serie", "tv-series", "séries", "séries tv", "séries télé",
        "seriale", "seriale tv", "serien", "tv-serien", "tv shows", "tv show", "shows", "dizi", "diziler", "series de tv",
    ]

    private static let movieGroupPrefixes: Set<String> = [
        "movies", "movie", "film", "films", "filme", "filmes", "filmy", "vod", "películas", "peliculas", "filmler",
    ]

    /// Classifies an entry. Cheap enough to run for every entry of a large playlist: the name scan only
    /// runs for on-demand URLs and the group keywords are matched once per call on a lowercased copy.
    static func classify(url: URL?, groupName: String, name: String?) -> ChannelContentKind {
        switch classifyByLocation(url: url, groupName: groupName) {
        case .known(let kind):
            return kind
        case .onDemandFile(let inSeriesGroup):
            // A season and an episode in the name ("S01E02", "1x02", "Staffel 1 Folge 2"); an episode number
            // alone ("Ep. 3") is not enough to make a movie a series.
            if let name, EpisodeParser.hasStrongMarker(name) {
                return .series
            }
            return inSeriesGroup ? .series : .movie
        }
    }

    /// The kind of an entry and, for on-demand entries named like episodes, the series it belongs to. Weak
    /// markers ("Ep. 3") only count for entries that are series by their URL or category. `session` caches the
    /// keys of the series titles of an import. Same kinds as `classify`, with one scan of the name.
    static func classifyEntry(url: URL?, groupName: String, name: String?, session: inout EpisodeParser.Session) -> (kind: ChannelContentKind, episode: EpisodeInfo?) {
        switch classifyByLocation(url: url, groupName: groupName) {
        case .known(.live):
            return (.live, nil)
        case .known(.series):
            return (.series, session.parse(name, groupName: groupName, allowsWeakMarkers: true))
        case .known(let kind):
            // A movie URL ("/movie/…") named like an episode is a series only for a strong marker.
            guard let episode = session.parse(name, groupName: groupName, allowsWeakMarkers: false) else {
                return (kind, nil)
            }
            return (.series, episode)
        case .onDemandFile(let inSeriesGroup):
            let scan = session.scan(name, groupName: groupName, allowsWeakMarkers: inSeriesGroup)
            return scan.hasStrongMarker || inSeriesGroup ? (.series, scan.episode) : (.movie, nil)
        }
    }

    private enum Location {
        /// The URL alone decides.
        case known(ChannelContentKind)
        /// A movie or an episode file: the name decides, then the category.
        case onDemandFile(inSeriesGroup: Bool)
    }

    private static func classifyByLocation(url: URL?, groupName: String) -> Location {
        guard let url else {
            return .known(.live)
        }
        let path = url.path.lowercased()
        if path.contains("/series/") {
            return .known(.series)
        }
        if path.contains("/movie/") || path.contains("/movies/") || path.contains("/vod/") {
            return .known(.movie)
        }
        guard onDemandExtensions.contains(url.pathExtension.lowercased()) else {
            return .known(.live)
        }
        let group = groupName.lowercased()
        return .onDemandFile(inSeriesGroup: seriesGroupKeywords.contains(where: { group.contains($0) }))
    }

    /// Kind of a group: the most common kind of its channels (live wins ties, then movies).
    static func dominant(live: Int, movie: Int, series: Int) -> ChannelContentKind {
        if live >= movie && live >= series {
            return .live
        }
        return movie >= series ? .movie : .series
    }
}
