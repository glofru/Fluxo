//
//  ParserChecks.swift
//  Fluxo
//
//  `EpisodeParser` against `parserCases`, the series keys, the classification of on-demand entries, and the
//  parse time of 100k names (Tools/SeriesCheck).
//

import Foundation

enum ParserChecks {
    static func runParserCases() {
        var failures = 0
        for testCase in parserCases {
            let info = EpisodeParser.parse(testCase.name, groupName: testCase.group, allowsWeakMarkers: testCase.weak)
            let problem: String?
            switch (testCase.expected, info) {
            case (nil, nil):
                problem = nil
            case (nil, let info?):
                problem = "expected no episode, got \(describe(info))"
            case (let expected?, nil):
                problem = "expected \(expected.title) S\(expected.season.map(String.init) ?? "-")E\(expected.episode), got nothing"
            case (let expected?, let info?):
                var issues: [String] = []
                if info.seriesTitle != expected.title { issues.append("title “\(info.seriesTitle)” ≠ “\(expected.title)”") }
                if info.season != expected.season { issues.append("season \(String(describing: info.season)) ≠ \(String(describing: expected.season))") }
                if info.episode != expected.episode { issues.append("episode \(info.episode) ≠ \(expected.episode)") }
                if info.episodeTitle != expected.episodeTitle { issues.append("episode title “\(info.episodeTitle ?? "nil")” ≠ “\(expected.episodeTitle ?? "nil")”") }
                if info.year != expected.year { issues.append("year \(String(describing: info.year)) ≠ \(String(describing: expected.year))") }
                if (info.strength == .strong) != expected.strong { issues.append("strength \(info.strength)") }
                problem = issues.isEmpty ? nil : issues.joined(separator: ", ")
            }
            if let problem {
                failures += 1
                print("FAIL \(testCase.name) [\(testCase.group)]: \(problem)")
            }
        }
        // Episodes of one series meet on one key, whatever the spelling; two series with the same title and
        // different years stay apart.
        let sameSeries = ["Breaking Bad S01E01", "|EN| Breaking Bad S01 E02", "Breaking.Bad.S02E01.720p", "BREAKING BAD - 3x01", "Breaking Bad Season 4 Episode 1"]
        let keys = Set(sameSeries.compactMap { EpisodeParser.parse($0)?.seriesKey })
        if keys.count != 1 {
            failures += 1
            print("FAIL one series, several keys: \(keys.sorted())")
        }
        let whoKeys = Set(["Doctor Who (2005) S01E01", "Doctor Who (1963) S01E01"].compactMap { EpisodeParser.parse($0)?.seriesKey })
        if whoKeys.count != 2 {
            failures += 1
            print("FAIL Doctor Who (1963) and (2005) share a key")
        }
        if ChannelContentKind.classify(url: URL(string: "http://host/a/b.mkv"), groupName: "Films", name: "Dark Staffel 1 Folge 2") != .series
            || ChannelContentKind.classify(url: URL(string: "http://host/a/b.mkv"), groupName: "Films", name: "Naruto Episode 3") != .movie
            || ChannelContentKind.classify(url: URL(string: "http://host/a/b"), groupName: "Series", name: "Friends S01E01") != .live {
            failures += 1
            print("FAIL classification of on-demand entries")
        }
        // The import's single-scan classification gives the same kinds as `classify` (plus episodes at movie
        // URLs), for every case in every kind of location.
        let locations = [
            ("http://host/series/1/2.mkv", "Films"), ("http://host/movie/1/2.mkv", "Films"), ("http://host/a/b.mkv", "Films"),
            ("http://host/a/b.mp4", "Serie TV"), ("http://host/a/b", "Series"), ("http://host/a/b.m3u8", "Films"),
        ]
        var mismatches = 0
        for testCase in parserCases {
            for (url, group) in locations {
                var session = EpisodeParser.Session()
                let entry = ChannelContentKind.classifyEntry(url: URL(string: url), groupName: group, name: testCase.name, session: &session)
                var kind = ChannelContentKind.classify(url: URL(string: url), groupName: group, name: testCase.name)
                if kind == .movie, entry.episode != nil {
                    // A movie URL ("/movie/…") named with a strong marker is an episode all the same.
                    kind = .series
                }
                if entry.kind != kind || (entry.episode != nil && entry.kind != .series) {
                    mismatches += 1
                    print("FAIL classifyEntry \(entry.kind) ≠ classify \(kind): \(testCase.name) at \(url) in \(group)")
                }
            }
        }
        if mismatches > 0 {
            failures += 1
        }
        print("parser: \(parserCases.count - failures)/\(parserCases.count) cases pass")
        if failures > 0 {
            exit(1)
        }
    }

    static func describe(_ info: EpisodeInfo) -> String {
        "“\(info.seriesTitle)” S\(info.season.map(String.init) ?? "-")E\(info.episode) “\(info.episodeTitle ?? "")” key=\(info.seriesKey) \(info.strength)"
    }

    static func benchmarkParser() {
        var names: [String] = []
        let shows = ["Breaking Bad", "IT: Gomorra - La serie", "Dark", "La Casa de Papel", "Il commissario Montalbano", "Doctor Who (2005)", "The Office (US)", "Шерлок"]
        for index in 0..<100_000 {
            let show = shows[index % shows.count]
            switch index % 5 {
            case 0: names.append("\(show) S\(String(format: "%02d", index % 9 + 1))E\(String(format: "%02d", index % 24 + 1)) FHD")
            case 1: names.append("\(show) Season \(index % 9 + 1) Episode \(index % 24 + 1) - Title \(index)")
            case 2: names.append("Movie Title \(index) (2019) 1080p")
            case 3: names.append("UK: Channel \(index) HD")
            default: names.append("\(show) \(index % 9 + 1)x\(String(format: "%02d", index % 24 + 1))")
            }
        }
        var timings: [Double] = []
        var episodes = 0
        for _ in 0..<5 {
            var session = EpisodeParser.Session()
            let start = DispatchTime.now().uptimeNanoseconds
            episodes = 0
            for name in names where session.parse(name, groupName: "Series") != nil {
                episodes += 1
            }
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        timings.sort()
        print(String(format: "parser: 100,000 names (%d episodes) median %.0f ms (%.2f µs per name)", episodes, timings[2], timings[2] * 1000 / 100_000))

        // The import's classification: one scan of each on-demand name (`classifyEntry`), against the classify
        // then parse it replaced (two scans).
        let urls = (0..<100_000).map { URL(string: "http://host/a/\($0).\($0 % 5 == 3 ? "m3u8" : "mkv")")! }
        func median(_ body: () -> Int) -> (Double, Int) {
            var timings: [Double] = []
            var result = 0
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                result = body()
                timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            return (timings.sorted()[2], result)
        }
        let (single, singleEpisodes) = median {
            var session = EpisodeParser.Session()
            var count = 0
            for (index, name) in names.enumerated() where ChannelContentKind.classifyEntry(url: urls[index], groupName: "VOD", name: name, session: &session).episode != nil {
                count += 1
            }
            return count
        }
        let (double, doubleEpisodes) = median {
            var session = EpisodeParser.Session()
            var count = 0
            for (index, name) in names.enumerated() {
                let kind = ChannelContentKind.classify(url: urls[index], groupName: "VOD", name: name)
                if kind != .live, session.parse(name, groupName: "VOD", allowsWeakMarkers: kind == .series) != nil {
                    count += 1
                }
            }
            return count
        }
        print(String(format: "classification: 100,000 entries in %.0f ms with one scan (%d episodes), %.0f ms with two (%d episodes)", single, singleEpisodes, double, doubleEpisodes))
        if singleEpisodes != doubleEpisodes {
            print("FAIL the single scan finds other episodes")
            exit(1)
        }
    }
}
