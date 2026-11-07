//
//  SearchRankingTests.swift
//  FluxoTests
//
//  Search: name normalization and matching (`SearchMatcher`) and ranking (`ChannelSearchIndex.rank`), on names as IPTV
//  playlists write them.
//

import Foundation
import Testing
@testable import Fluxo

@Suite("Search ranking")
struct SearchRankingTests {

    /// Ranks `names` (one import, in this playlist order) for `query`; returns the names of the hits, best first.
    private func rank(_ names: [String], _ query: String, kinds: [ChannelContentKind]? = nil, kind: ChannelContentKind? = nil, limit: Int = 50) -> [String] {
        let entries = names.enumerated().map { index, name in
            SearchIndexEntry(name: SearchName(name), sortIndex: index, kindRawValue: (kinds?[index] ?? .live).rawValue)
        }
        let hits = ChannelSearchIndex.rank([(UUID(), entries)], query: SearchQuery(query), kind: kind?.rawValue, limit: limit)
        return hits.map { names[$0.sortIndex] }
    }

    @Test("Case, diacritics, width and punctuation are folded the same way in names and queries")
    func normalization() {
        #expect(SearchName("Café").bytes == SearchName("cafe").bytes)
        #expect(SearchName("ＳＫＹ").bytes == SearchName("sky").bytes)
        #expect(String(decoding: SearchName("IT | Sky-Sport F1 (FHD)").bytes, as: UTF8.self) == "it sky sport f1 fhd")
        #expect(SearchQuery("  sky   SKY sport ").tokens.count == 2, "tokens are deduplicated")
        #expect(SearchQuery(" | - ").isEmpty)
    }

    @Test("The whole name equal to the query comes first, then names starting with it, then the shorter names")
    func exactBeforePrefixBeforeLonger() {
        let names = ["Sky Sport F1 FHD Backup", "IT | Sky Sport F1 HD", "Sky Sport F1", "Sky Sport F1 HD"]
        let ranked = rank(names, "sky sport f1")
        #expect(ranked.first == "Sky Sport F1")
        #expect(ranked.firstIndex(of: "Sky Sport F1 HD")! < ranked.firstIndex(of: "Sky Sport F1 FHD Backup")!)
        #expect(ranked.last == "IT | Sky Sport F1 HD", "a name that does not start with the query comes after those that do")
    }

    @Test("Every word of the query must match a word of the name, in any order")
    func wordsInAnyOrder() {
        let names = ["Sky Sport F1", "Sky Cinema", "Rai Sport", "F1 TV"]
        #expect(Set(rank(names, "f1 sky")) == ["Sky Sport F1"])
        #expect(Set(rank(names, "sport")) == ["Sky Sport F1", "Rai Sport"])
    }

    @Test("Words in the query's order rank before the same words in another order")
    func queryOrderBonus() {
        let ranked = rank(["F1 Sky Replay", "Sky F1 Replay"], "sky f1")
        #expect(ranked == ["Sky F1 Replay", "F1 Sky Replay"])
    }

    @Test("A word prefix, a word inside a word, and words joined across their breaks match")
    func partialMatches() {
        let names = ["Sky Sport", "Eurosport 1", "F-1 Racing", "Movies"]
        #expect(rank(names, "spo") == ["Sky Sport", "Eurosport 1"], "a word prefix before a match inside a word")
        #expect(Set(rank(names, "sport")) == ["Sky Sport", "Eurosport 1"])
        #expect(rank(names, "sport").first == "Sky Sport", "a whole word before a word inside another")
        #expect(rank(names, "skysport") == ["Sky Sport"])
        #expect(rank(names, "f1") == ["F-1 Racing"])
    }

    @Test("Typos are forgiven for words of four letters or more when the exact pass finds too little; digits never")
    func typos() {
        let names = ["Sky Sport 5", "Sky Sport 6", "Mediaset Extra", "BBC One"]
        #expect(Set(rank(names, "sprot")) == ["Sky Sport 5", "Sky Sport 6"])
        #expect(rank(names, "mediasett") == ["Mediaset Extra"])
        #expect(rank(names, "sport 5") == ["Sky Sport 5"], "Sport 5 never finds Sport 6")
        #expect(rank(names, "bbx").isEmpty, "no typos for words under four letters")
        #expect(SearchMatcher.typoBudget(forLength: 3) == 0)
        #expect(SearchMatcher.typoBudget(forLength: 5) == 1)
        #expect(SearchMatcher.typoBudget(forLength: 9) == 2)
    }

    @Test("Exact matches rank before typo matches")
    func exactBeforeTypo() {
        #expect(rank(["Sprot Channel", "Sport Extra"], "sport") == ["Sport Extra", "Sprot Channel"])
        #expect(rank(["Sprot Channel", "Sport Extra"], "sport", limit: 1) == ["Sport Extra"], "no typo pass once the exact pass fills the limit")
    }

    @Test("Ties keep the playlist order")
    func tiesKeepPlaylistOrder() {
        let names = ["Rai 1", "Rai 2", "Rai 3"]
        #expect(rank(names, "rai") == names)
    }

    @Test("A kind limits the results to entries of that kind")
    func kindFilter() {
        let names = ["Matrix (1999)", "Matrix Channel", "Matrix S01E01"]
        let kinds: [ChannelContentKind] = [.movie, .live, .series]
        #expect(rank(names, "matrix", kinds: kinds, kind: .movie) == ["Matrix (1999)"])
        #expect(rank(names, "matrix", kinds: kinds).count == 3)
    }

    @Test("The limit keeps the best hits")
    func limit() {
        let names = (1...30).map { "News \($0)" } + ["News"]
        #expect(rank(names, "news", limit: 3).first == "News")
        #expect(rank(names, "news", limit: 3).count == 3)
    }
}
