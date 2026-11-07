//
//  EpisodeParserTests.swift
//  FluxoTests
//
//  Series and episode parsing (`EpisodeParser`) on the shared case table (Fixtures/EpisodeParserCases.swift), the
//  series keys episodes meet on, and how on-demand entries are classified (`ChannelContentKind`).
//

import Foundation
import Testing
@testable import Fluxo

extension ParserCase: CustomTestStringConvertible {
    var testDescription: String {
        group.isEmpty ? name : "\(name) [\(group)]"
    }
}

@Suite("Series and episode parsing")
struct EpisodeParserTests {

    @Test("Each name gives its series, season, episode and title, or no episode", arguments: parserCases)
    func parses(_ testCase: ParserCase) {
        let info = EpisodeParser.parse(testCase.name, groupName: testCase.group, allowsWeakMarkers: testCase.weak)
        guard let expected = testCase.expected else {
            #expect(info == nil, "not an episode")
            return
        }
        guard let info else {
            Issue.record("expected \(expected.title) S\(expected.season.map(String.init) ?? "-")E\(expected.episode), got no episode")
            return
        }
        #expect(info.seriesTitle == expected.title)
        #expect(info.season == expected.season)
        #expect(info.episode == expected.episode)
        #expect(info.episodeTitle == expected.episodeTitle)
        #expect(info.year == expected.year)
        #expect((info.strength == .strong) == expected.strong, "strength \(info.strength)")
    }

    @Test("Episodes of one series meet on one key, whatever the spelling")
    func oneSeriesOneKey() {
        let names = ["Breaking Bad S01E01", "|EN| Breaking Bad S01 E02", "Breaking.Bad.S02E01.720p", "BREAKING BAD - 3x01", "Breaking Bad Season 4 Episode 1"]
        let keys = Set(names.compactMap { EpisodeParser.parse($0)?.seriesKey })
        #expect(keys.count == 1, "keys: \(keys.sorted())")
    }

    @Test("Two series with the same title and different years stay apart")
    func yearsSeparateSeries() {
        let keys = Set(["Doctor Who (2005) S01E01", "Doctor Who (1963) S01E01"].compactMap { EpisodeParser.parse($0)?.seriesKey })
        #expect(keys.count == 2)
    }

    @Test("On-demand entries: an episode name in a movie category is a series, weak markers are not")
    func classification() {
        #expect(ChannelContentKind.classify(url: URL(string: "http://host/a/b.mkv"), groupName: "Films", name: "Dark Staffel 1 Folge 2") == .series)
        #expect(ChannelContentKind.classify(url: URL(string: "http://host/a/b.mkv"), groupName: "Films", name: "Naruto Episode 3") == .movie)
        #expect(ChannelContentKind.classify(url: URL(string: "http://host/a/b"), groupName: "Series", name: "Friends S01E01") == .live)
    }

    /// The import's single-scan classification gives the kinds `classify` gives (plus episodes at movie URLs).
    @Test("The import's classification agrees with classify for every case and location", arguments: [
        ("http://host/series/1/2.mkv", "Films"), ("http://host/movie/1/2.mkv", "Films"), ("http://host/a/b.mkv", "Films"),
        ("http://host/a/b.mp4", "Serie TV"), ("http://host/a/b", "Series"), ("http://host/a/b.m3u8", "Films"),
    ])
    func importClassificationAgrees(url: String, group: String) {
        for testCase in parserCases {
            var session = EpisodeParser.Session()
            let entry = ChannelContentKind.classifyEntry(url: URL(string: url), groupName: group, name: testCase.name, session: &session)
            var kind = ChannelContentKind.classify(url: URL(string: url), groupName: group, name: testCase.name)
            if kind == .movie, entry.episode != nil {
                // A movie URL ("/movie/…") named with a strong marker is an episode all the same.
                kind = .series
            }
            #expect(entry.kind == kind, "\(testCase.name)")
            #expect(entry.episode == nil || entry.kind == .series, "\(testCase.name): an episode is a series")
        }
    }
}
