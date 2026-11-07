//
//  EPGMatchingTests.swift
//  FluxoTests
//
//  The TV guide: how playlist channels are matched to XMLTV channels (`ChannelNameNormalizer`, `EPGChannelMatcher`,
//  `EPGWantedChannels`) and how XMLTV is read (`XMLTVParser`: dates, episode numbers, a whole guide).
//

import Foundation
import Testing
@testable import Fluxo

@Suite("TV guide matching")
struct EPGMatchingTests {

    @Test("Decorated IPTV names have the key of the guide's name", arguments: [
        ("IT: Sky Sport F1 FHD", "Sky Sport F1"),
        ("Sky Sport F1 HD", "sky sport f1"),
        ("|UK| BBC One ᴴᴰ", "BBC One"),
        ("[DE] Das Erste HD", "Das Erste"),
        ("UK | ITV1 1080p", "ITV1"),
        ("IT - Rai 1", "Rai 1"),
        ("VIP UK: Sky Sports Main Event", "Sky Sports Main Event"),
        ("Rai 1 (backup)", "Rai 1"),
        ("Télé Bleue", "tele bleue"),
        ("Canal+ FR", "Canal+"),
        ("TF1 HEVC 50fps", "TF1"),
        ("ＢＢＣ　Ｏｎｅ", "BBC One"),
    ])
    func sameKey(_ decorated: String, _ plain: String) {
        let key = ChannelNameNormalizer.key(decorated)
        #expect(!key.isEmpty)
        #expect(key == ChannelNameNormalizer.key(plain))
    }

    @Test("Different channels keep different keys", arguments: [
        ("Sky Sport F1", "Sky Sport F1 +1"),
        ("Canal+", "Canal"),
        ("Rai 1", "Rai 2"),
        ("BBC One - HD", "HD"),
        ("Rai 1: Live", "Live"),
        ("Sky TV", "Sky"),
    ])
    func differentKeys(_ lhs: String, _ rhs: String) {
        #expect(ChannelNameNormalizer.key(lhs) != ChannelNameNormalizer.key(rhs))
    }

    @Test("Loose keys, id keys and names read from ids")
    func looseAndIDKeys() {
        #expect(ChannelNameNormalizer.looseKey("Rai Uno") == ChannelNameNormalizer.looseKey("Rai 1"))
        #expect(ChannelNameNormalizer.looseKey("Canale 5") == ChannelNameNormalizer.looseKey("5"))
        #expect(ChannelNameNormalizer.idKeys("BBCOne.uk@HD") == ["bbcone.uk@hd", "bbcone.uk"])
        #expect(ChannelNameNormalizer.key(ChannelNameNormalizer.nameFromID("SkySportF1.it")) == ChannelNameNormalizer.key("SkySport F1"))
    }

    // MARK: - Matcher

    private let playlistID: UUID
    /// A guide of the channel's own playlist, one the user added, and one of another playlist.
    private let ownSource: EPGChannelMatcher.Source
    private let userSource = EPGChannelMatcher.Source(sourceID: UUID(), importID: UUID(), playlistID: nil)
    private let otherSource = EPGChannelMatcher.Source(sourceID: UUID(), importID: UUID(), playlistID: UUID())

    init() {
        let playlistID = UUID()
        self.playlistID = playlistID
        ownSource = EPGChannelMatcher.Source(sourceID: UUID(), importID: UUID(), playlistID: playlistID)
    }

    /// The three guides, the lowest-ranked first: the matcher puts them in order itself.
    private func makeMatcher(overrides: [String: EPGChannelMatcher.Override] = [:]) -> EPGChannelMatcher {
        EPGChannelMatcher(sources: [
            (otherSource, [.init(channelID: "Rai1.it", names: ["Rai 1"])]),
            (userSource, [.init(channelID: "SkySportF1.it", names: ["Sky Sport F1"]), .init(channelID: "Rai1.it", names: ["Rai 1"])]),
            (ownSource, [.init(channelID: "raiuno.it", names: ["Rai Uno"]), .init(channelID: "bbc1.uk", names: ["BBC One"])]),
        ], overrides: overrides)
    }

    private func channel(_ name: String, tvgID: String? = nil) -> ChannelItem {
        ChannelItem(id: UUID(), playlistID: playlistID, name: name, logo: nil, url: URL(string: "https://example.com/\(UUID().uuidString)"), groupName: "", kind: .live, tvgID: tvgID)
    }

    @Test("A tvg-id matches case-insensitively, with or without a feed suffix")
    func matchesByID() {
        let matcher = makeMatcher()
        #expect(matcher.match(channel("whatever", tvgID: "SKYSPORTF1.IT"))?.channelID == "SkySportF1.it")
        #expect(matcher.match(channel("BBC One HD", tvgID: "bbc1.uk@SD"))?.channelID == "bbc1.uk")
        #expect(matcher.match(channel("x", tvgID: "bbc1.uk"))?.sourceID == ownSource.sourceID, "the playlist's own guide first")
    }

    @Test("A decorated name matches the guide's name; a strict name wins over the loose key of the own guide")
    func matchesByName() {
        let matcher = makeMatcher()
        #expect(matcher.match(channel("IT: Sky Sport F1 FHD"))?.channelID == "SkySportF1.it")
        #expect(matcher.match(channel("Rai 1 HD"))?.sourceID == userSource.sourceID)
        #expect(matcher.match(channel("Unknown Channel")) == nil)
    }

    @Test("The loose key matches when nothing stricter does")
    func matchesByLooseKey() {
        let matcher = makeMatcher()
        let ref = matcher.match(channel("Rai Uno HD"))
        #expect(ref?.channelID == "raiuno.it")
        #expect(ref?.sourceID == ownSource.sourceID)
    }

    @Test("A manual choice wins: another channel, or no guide at all")
    func overrides() throws {
        let pinned = channel("Rai 1")
        let none = channel("Sky Sport F1")
        let pinnedKey = try #require(pinned.bookmarkKey)
        let noneKey = try #require(none.bookmarkKey)
        let matcher = makeMatcher(overrides: [
            pinnedKey: .channel(GuideChannelRef(sourceID: userSource.sourceID, importID: UUID(), channelID: "SkySportF1.it")),
            noneKey: .none,
        ])
        let ref = matcher.match(pinned)
        #expect(ref?.channelID == "SkySportF1.it")
        #expect(ref?.importID == userSource.importID, "a manual choice follows its source to the current import")
        #expect(matcher.match(none) == nil)
    }

    @Test("The channels a refresh keeps: by id and by any of their names")
    func wantedChannels() {
        var wanted = EPGWantedChannels()
        wanted.add(tvgID: "SkySportF1.it", name: "IT: Sky Sport F1 FHD")
        wanted.add(tvgID: nil, name: "|UK| BBC One HD")
        #expect(wanted.containsID("skysportf1.it"))
        #expect(wanted.contains(channelID: "other.id", names: ["BBC One"]))
        #expect(wanted.contains(channelID: "sky.id", names: ["Sky Sport F1"]))
        #expect(!wanted.contains(channelID: "rai1.it", names: ["Rai 1"]))
    }

    // MARK: - XMLTV

    @Test("XMLTV dates: offsets, a missing zone or seconds, leap days, invalid values")
    func dates() {
        let utc = XMLTVParser.date(fromXMLTV: "20261102050000 +0000")
        #expect(utc == Date(timeIntervalSince1970: 1_793_595_600))
        #expect(XMLTVParser.date(fromXMLTV: "20261102070000 +0200") == utc)
        #expect(XMLTVParser.date(fromXMLTV: "20261102000000 -0500") == utc)
        #expect(XMLTVParser.date(fromXMLTV: "202611020500") == utc)
        #expect(XMLTVParser.date(fromXMLTV: "20240229120000 +0000") == Date(timeIntervalSince1970: 1_709_208_000))
        #expect(XMLTVParser.date(fromXMLTV: "2026110") == nil)
        #expect(XMLTVParser.date(fromXMLTV: "20261340000000 +0000") == nil)
    }

    @Test("xmltv_ns episode numbers count from zero", arguments: [
        ("0.4.0/1", "S1 E5"), ("2 . 9 . ", "S3 E10"), (".11.", "E12"),
    ])
    func episodeNumbers(_ value: String, _ expected: String) {
        #expect(XMLTVParser.episode(fromXMLTVNS: value) == expected)
    }

    @Test("An empty xmltv_ns value is no episode")
    func emptyEpisodeNumber() {
        #expect(XMLTVParser.episode(fromXMLTVNS: "..") == nil)
    }

    @Test("A guide: wanted channels only, in order, entities, CDATA, categories, open-ended programmes, the window")
    func parsesAGuide() throws {
        let xml = """
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <!DOCTYPE tv SYSTEM "xmltv.dtd">
        <tv>
          <channel id="a.it"><display-name>Canale A</display-name><icon src="https://example.com/a.png"/></channel>
          <channel id="b.it"><display-name>Canale B</display-name></channel>
          <programme start="20300101100000 +0000" stop="20300101110000 +0000" channel="a.it">
            <title>Caff\u{E8} &amp; Notizie</title><desc><![CDATA[News <live>]]></desc><category>News</category><category>News</category>
            <episode-num system="xmltv_ns">0.1.</episode-num><icon src="https://example.com/p.jpg"/>
          </programme>
          <programme start="20300101110000 +0000" channel="a.it"><title>Open ended</title></programme>
          <programme start="20300101120000 +0000" stop="20300101130000 +0000" channel="a.it"><title>Noon</title></programme>
          <programme start="20300101100000 +0000" stop="20300101110000 +0000" channel="b.it"><title>Unwanted</title></programme>
          <programme start="20200101100000 +0000" stop="20200101110000 +0000" channel="a.it"><title>Too old</title></programme>
        </tv>
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fluxo-tests-guide-\(UUID().uuidString).xml")
        try #require(xml.data(using: .isoLatin1)).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
        }
        let collected = Collected()
        let window = DateInterval(start: Date(timeIntervalSince1970: 1_893_456_000 - 86_400), duration: 7 * 86_400)
        let parser = XMLTVParser(
            window: window,
            wantsChannel: { $0.id == "a.it" },
            wantsChannelID: { _ in false },
            onChannel: { channel, _ in collected.channels.append(channel) },
            onProgramme: { collected.programmes.append($0) }
        )
        let stream = try #require(InflatingInputStream(fileURL: file))
        stream.open()
        defer {
            stream.close()
        }
        try parser.parse(stream)

        #expect(collected.channels.map(\.id) == ["a.it", "b.it"])
        #expect(collected.channels.first?.displayNames == ["Canale A"])
        #expect(collected.channels.first?.icon == "https://example.com/a.png")
        #expect(collected.programmes.map(\.title) == ["Caffè & Notizie", "Open ended", "Noon"])
        let first = try #require(collected.programmes.first)
        #expect(first.summary == "News <live>")
        #expect(first.categories == ["News"], "a repeated category counts once")
        #expect(first.episode == "S1 E2")
        #expect(first.icon == "https://example.com/p.jpg")
        try #require(collected.programmes.count == 3)
        #expect(collected.programmes[1].stop == collected.programmes[2].start, "an open-ended programme ends where the next one starts")
        #expect(parser.statistics.skippedUnwantedChannel == 1)
        #expect(parser.statistics.skippedOutsideWindow == 1)
        #expect(!parser.endedEarly)
    }

    /// What the parser's callbacks deliver (they run synchronously on the calling thread).
    private final class Collected {
        var channels: [XMLTVChannel] = []
        var programmes: [XMLTVProgramme] = []
    }
}
