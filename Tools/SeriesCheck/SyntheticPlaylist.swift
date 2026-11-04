//
//  SyntheticPlaylist.swift
//  Fluxo
//
//  A large IPTV-like playlist with live channels, movies and series whose episodes are named in the styles
//  providers use (Tools/SeriesCheck). Plain Foundation: compiled with the current sources and with the sources of
//  the version before series grouping.
//

import Foundation

enum SyntheticPlaylist {

    /// 60 % live channels, 15 % movies, 25 % episodes of series of 2 to 4 seasons.
    struct Layout {
        let entries: Int
        /// Enough series for every episode slot (about 30 episodes each), so none repeats.
        var seriesCount: Int {
            max(1, entries / 4 / 20 + 1)
        }
    }

    static let styles = 6

    /// The name of an episode in one of the provider styles.
    static func episodeName(show: String, style: Int, season: Int, episode: Int) -> String {
        switch style {
        case 0:
            return String(format: "%@ S%02dE%02d", show, season, episode)
        case 1:
            return String(format: "IT: %@ S%02d E%02d [MULTI] FHD", show, season, episode)
        case 2:
            return String(format: "%@ %dx%02d - Chapter %d", show, season, episode, episode)
        case 3:
            return "\(show) Season \(season) Episode \(episode)"
        case 4:
            return "\(show) Stagione \(season) Episodio \(episode)"
        default:
            return String(format: "%@.S%02dE%02d.720p.WEB", show.replacingOccurrences(of: " ", with: "."), season, episode)
        }
    }

    static func showName(_ index: Int) -> String {
        let first = ["Harbor", "Night", "Paper", "Silent", "Golden", "Broken", "Hidden", "Last", "Velvet", "Iron", "Crimson", "Northern"]
        let second = ["Lights", "Desk", "Kings", "Signal", "Coast", "Protocol", "Garden", "Station", "Line", "Harbour", "Files", "Run"]
        return "\(first[index % first.count]) \(second[(index / first.count) % second.count]) \(index / (first.count * second.count) + 1)"
    }

    /// Writes the playlist; returns how many episodes and series it has.
    @discardableResult
    static func write(to url: URL, layout: Layout) throws -> (episodes: Int, series: Int) {
        var text = "#EXTM3U\n"
        text.reserveCapacity(layout.entries * 160)
        var index = 0
        var episodes = 0
        let seriesTotal = layout.seriesCount
        // The episodes in playlist order: series after series, season after season (providers list them so).
        var cursor = (series: 0, season: 1, episode: 1)
        var seriesSeen = 0
        while index < layout.entries {
            let slot = index % 20
            if slot < 12 {
                let name = "UK: Channel \(index) HD"
                text += "#EXTINF:-1 tvg-id=\"ch\(index).uk\" tvg-logo=\"https://logos.example.com/\(index).png\" group-title=\"UK | General \(index % 40)\",\(name)\nhttp://provider.example.com:8080/u/p/\(100_000 + index)\n"
                index += 1
            } else if slot < 15 {
                let name = "Movie Title \(index) (\(1970 + index % 55))"
                text += "#EXTINF:-1 tvg-logo=\"https://posters.example.com/m\(index).jpg\" group-title=\"Movies | Drama \(index % 12)\",\(name)\nhttp://provider.example.com:8080/movie/u/p/\(100_000 + index).mp4\n"
                index += 1
            } else {
                // The next episode: a few seasons of 10 episodes per series.
                let seriesIndex = cursor.series % seriesTotal
                if cursor.season == 1 && cursor.episode == 1 && cursor.series < seriesTotal {
                    seriesSeen += 1
                }
                let title = showName(seriesIndex)
                let name = episodeName(show: title, style: seriesIndex % styles, season: cursor.season, episode: cursor.episode)
                text += "#EXTINF:-1 tvg-logo=\"https://posters.example.com/s\(seriesIndex).jpg\" group-title=\"Series | Genre \(seriesIndex % 8)\",\(name)\nhttp://provider.example.com:8080/series/u/p/\(100_000 + index).mkv\n"
                index += 1
                episodes += 1
                cursor.episode += 1
                if cursor.episode > 10 {
                    cursor.episode = 1
                    cursor.season += 1
                    if cursor.season > 2 + seriesIndex % 3 {
                        cursor = (cursor.series + 1, 1, 1)
                    }
                }
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (episodes, seriesSeen)
    }
}
