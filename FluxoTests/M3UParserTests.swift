//
//  M3UParserTests.swift
//  FluxoTests
//
//  The streaming M3U / M3U8 parser (`M3UParser`): the EXTINF grammar, line endings, encodings, the guide URLs of the
//  header. Every input is also fed one byte at a time, as a slow network would deliver it.
//

import Foundation
import Testing
@testable import Fluxo

@Suite("M3U parsing")
struct M3UParserTests {

    /// The entries of `input` parsed whole, and fed one byte at a time (every chunk boundary).
    private func parse(_ input: Data) -> (whole: [M3UEntry], byByte: [M3UEntry]) {
        let whole = M3UParser.parse(input)
        var parser = M3UParser()
        var byByte: [M3UEntry] = []
        for byte in input {
            parser.consume(Data([byte])) { byByte.append($0) }
        }
        parser.finish { byByte.append($0) }
        return (whole, byByte)
    }

    private func expectEntries(_ input: String, _ expected: [M3UEntry], sourceLocation: SourceLocation = #_sourceLocation) {
        let (whole, byByte) = parse(Data(input.utf8))
        #expect(whole == expected, sourceLocation: sourceLocation)
        #expect(byByte == expected, "fed one byte at a time", sourceLocation: sourceLocation)
    }

    @Test("Quoted attributes may hold spaces and commas; the title starts after the attribute block")
    func quotedAttributes() {
        expectEntries(
            "#EXTM3U\n#EXTINF:-1 tvg-id=\"news.us\" tvg-name=\"Fox News HD\" tvg-logo=\"https://l.example/fox.png\" group-title=\"News, USA\",Fox News, Live HD\nhttp://s.example/1\n",
            [M3UEntry(title: "Fox News, Live HD", url: "http://s.example/1", tvgID: "news.us", tvgName: "Fox News HD", logo: "https://l.example/fox.png", group: "News, USA")]
        )
    }

    @Test("CRLF line endings, a byte order mark, no header and a positive duration")
    func crlfAndBOM() {
        expectEntries(
            "\u{FEFF}#EXTINF:123 group-title=\"Movies\",Movie A\r\nhttps://s.example/a.mp4\r\n",
            [M3UEntry(title: "Movie A", url: "https://s.example/a.mp4", group: "Movies", duration: 123)]
        )
    }

    @Test("CR-only line endings and a last line without a newline")
    func carriageReturnsOnly() {
        expectEntries(
            "#EXTM3U\r#EXTINF:-1,One\rhttp://s.example/1\r#EXTINF:-1,Two\rhttp://s.example/2",
            [M3UEntry(title: "One", url: "http://s.example/1"), M3UEntry(title: "Two", url: "http://s.example/2")]
        )
    }

    @Test("EXTGRP, option lines and blank lines between EXTINF and its URL")
    func linesBetweenInfoAndURL() {
        expectEntries(
            "#EXTM3U\n\n#EXTINF:-1,Sky\n#EXTGRP:Sports\n#EXTVLCOPT:http-user-agent=VLC\n\n   http://s.example/sky   \n",
            [M3UEntry(title: "Sky", url: "http://s.example/sky", group: "Sports")]
        )
    }

    @Test("group-title wins over EXTGRP")
    func groupTitleWins() {
        expectEntries(
            "#EXTGRP:Other\n#EXTINF:-1 group-title=\"Kids\",Cartoon\nhttp://s.example/c\n",
            [M3UEntry(title: "Cartoon", url: "http://s.example/c", group: "Kids")]
        )
    }

    @Test("Empty and placeholder logos are dropped; protocol-relative logos get https")
    func logos() {
        expectEntries(
            "#EXTINF:-1 tvg-logo=\"\",A\nhttp://s/a\n#EXTINF:-1 tvg-logo=\"none\",B\nhttp://s/b\n#EXTINF:-1 logo=//cdn.example/b.png,C\nhttp://s/c\n",
            [M3UEntry(title: "A", url: "http://s/a"), M3UEntry(title: "B", url: "http://s/b"), M3UEntry(title: "C", url: "http://s/c", logo: "https://cdn.example/b.png")]
        )
    }

    @Test("Single quotes, unquoted values, and keys and tags in any case")
    func quotingAndCase() {
        expectEntries(
            "#extinf:-1 TVG-NAME='My Channel' Group-Title=Music,Title\nhttp://s/m\n",
            [M3UEntry(title: "Title", url: "http://s/m", tvgName: "My Channel", group: "Music")]
        )
    }

    @Test("Without a title, the display name is the tvg-name")
    func displayNameFallsBackToTVGName() throws {
        let entries = M3UParser.parse(Data("#EXTINF:-1 tvg-name=\"Only Name\"\nhttp://s/o\n".utf8))
        #expect(entries == [M3UEntry(title: nil, url: "http://s/o", tvgName: "Only Name")])
        #expect(try #require(entries.first).displayName == "Only Name")
    }

    @Test("An unterminated quote ends at the next comma")
    func unterminatedQuote() {
        expectEntries(
            "#EXTINF:-1 group-title=\"Broken,Name Here\nhttp://s/u\n",
            [M3UEntry(title: "Name Here", url: "http://s/u", group: "Broken")]
        )
    }

    @Test("Bare stream URLs without EXTINF are entries; other text is ignored")
    func bareURLs() {
        expectEntries(
            "<html>\n<a href=\"https://x\">\nrtmp://live.example/app/stream\nnot a url\n",
            [M3UEntry(title: nil, url: "rtmp://live.example/app/stream")]
        )
    }

    @Test("A title that is not UTF-8 is read as Latin-1")
    func latin1Title() {
        let bytes = Data([UInt8]("#EXTINF:-1,Caf".utf8) + [0xE9] + [UInt8]("\nhttp://s/l\n".utf8))
        let (whole, byByte) = parse(bytes)
        #expect(whole.first?.title == "Caf\u{E9}")
        #expect(byByte == whole)
    }

    @Test("The header's guide URLs: url-tvg and x-tvg-url, several per attribute, http(s) only, without duplicates")
    func guideURLs() {
        let header = Data("#EXTM3U url-tvg=\"https://a.example/epg.xml.gz,https://b.example/epg.xml\" x-tvg-url=https://a.example/epg.xml.gz tvg-shift=0\n#EXTINF:-1,One\nhttp://example.com/1\n".utf8)
        var parser = M3UParser()
        var entries: [M3UEntry] = []
        parser.consume(header) { entries.append($0) }
        parser.finish { entries.append($0) }
        #expect(parser.sawHeader)
        #expect(parser.guideURLs == ["https://a.example/epg.xml.gz", "https://b.example/epg.xml"])
        #expect(entries.count == 1)
        #expect(EPGImporter.guideURLs(in: "https://a.example/g.xml, ftp://x/y ,https://a.example/g.xml").map(\.absoluteString) == ["https://a.example/g.xml"])
    }

    @Test("A large playlist parses entry for entry, in order, whatever the chunk size", arguments: [1, 7, 4_096, 65_536])
    func largePlaylistInChunks(chunkSize: Int) {
        var text = "#EXTM3U\n"
        for index in 0..<2_000 {
            text += "#EXTINF:-1 tvg-id=\"ch\(index)\" group-title=\"Group \(index % 13)\",Channel \(index)\nhttp://s.example/live/\(index).ts\n"
        }
        let data = Data(text.utf8)
        var parser = M3UParser()
        var entries: [M3UEntry] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            parser.consume(data.subdata(in: offset..<end)) { entries.append($0) }
            offset = end
        }
        parser.finish { entries.append($0) }
        #expect(entries.count == 2_000)
        #expect(parser.entryCount == 2_000)
        #expect(entries.first == M3UEntry(title: "Channel 0", url: "http://s.example/live/0.ts", tvgID: "ch0", group: "Group 0"))
        #expect(entries.last?.title == "Channel 1999")
        #expect(entries.map(\.tvgID) == (0..<2_000).map { "ch\($0)" })
    }
}
