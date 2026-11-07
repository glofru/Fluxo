//
//  main.swift
//  GuideCheck
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import SwiftData

/// Checks the TV guide pipeline outside the app, with the real sources:
///
///     guide-check selftest                         dates, episodes, name matching, M3U header URLs, incomplete files,
///                                                  re-reading guides after a playlist import
///     guide-check parse <file.xml[.gz]> [wanted]   streaming parse only (wanted: number of channels to keep, default all)
///     guide-check import <file> <store.sqlite>     full import into an on-disk SwiftData store, then every guide query
///     guide-check refresh <url> <store.sqlite> <name>...  download + import through EPGImporter.refresh, twice
///                                                  (the second download is unchanged and must be skipped)
///     guide-check delete <file> <store.sqlite>     imports the whole guide twice (two sources), then deletes one while
///                                                  the guide is read: timings, and nothing of it is left
///     guide-check generate <out.xml> <channels> <days>   synthetic XMLTV around now
///
/// Each command prints its timings; run it under `/usr/bin/time -l` for the peak memory (see run.sh).
@main
enum GuideCheck {

    /// Only the main task counts failures (the checks run one after another).
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("  ok   \(message)")
        } else {
            failures += 1
            print("  FAIL \(message)")
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "selftest":
            selfTest()
            try await lifecycleCheck()
        case "parse":
            try parse(URL(fileURLWithPath: arguments[1]), wantedLimit: arguments.count > 2 ? Int(arguments[2]) : nil)
        case "import":
            try await importCheck(URL(fileURLWithPath: arguments[1]), storeURL: URL(fileURLWithPath: arguments[2]))
        case "refresh":
            try await refreshCheck(URL(string: arguments[1]) ?? URL(fileURLWithPath: "/"), storeURL: URL(fileURLWithPath: arguments[2]), names: Array(arguments.dropFirst(3)))
        case "delete":
            try await deleteCheck(URL(fileURLWithPath: arguments[1]), storeURL: URL(fileURLWithPath: arguments[2]))
        case "generate":
            try generate(URL(fileURLWithPath: arguments[1]), channels: Int(arguments[2]) ?? 1_000, days: Int(arguments[3]) ?? 7)
        default:
            print("usage: guide-check selftest | parse <file> [wanted] | import <file> <store> | delete <file> <store> | generate <out> <channels> <days>")
            exit(2)
        }
        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
    }

    // MARK: - Self test

    static func selfTest() {
        print("== XMLTV dates")
        let utc = XMLTVParser.date(fromXMLTV: "20261102050000 +0000")
        expect(utc == Date(timeIntervalSince1970: 1_793_595_600), "20261102050000 +0000 → \(String(describing: utc))")
        let offset = XMLTVParser.date(fromXMLTV: "20261102070000 +0200")
        expect(offset == utc, "+0200 offset → \(String(describing: offset))")
        let negative = XMLTVParser.date(fromXMLTV: "20261102000000 -0500")
        expect(negative == utc, "-0500 offset → \(String(describing: negative))")
        expect(XMLTVParser.date(fromXMLTV: "202611020500") == utc, "no seconds, no zone = UTC")
        expect(XMLTVParser.date(fromXMLTV: "20240229120000 +0000") == Date(timeIntervalSince1970: 1_709_208_000), "leap day")
        expect(XMLTVParser.date(fromXMLTV: "2026110") == nil, "short value rejected")
        expect(XMLTVParser.date(fromXMLTV: "20261340000000 +0000") == nil, "month 13 rejected")

        print("== episodes")
        expect(XMLTVParser.episode(fromXMLTVNS: "0.4.0/1") == "S1 E5", "xmltv_ns 0.4.0/1 → S1 E5")
        expect(XMLTVParser.episode(fromXMLTVNS: "2 . 9 . ") == "S3 E10", "xmltv_ns with blanks")
        expect(XMLTVParser.episode(fromXMLTVNS: ".11.") == "E12", "episode only")
        expect(XMLTVParser.episode(fromXMLTVNS: "..") == nil, "empty")

        print("== name keys")
        let same: [(String, String)] = [
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
        ]
        for (lhs, rhs) in same {
            let left = ChannelNameNormalizer.key(lhs)
            let right = ChannelNameNormalizer.key(rhs)
            expect(left == right && !left.isEmpty, "\"\(lhs)\" = \"\(rhs)\" (\(left))")
        }
        let different: [(String, String)] = [
            ("Sky Sport F1", "Sky Sport F1 +1"),
            ("Canal+", "Canal"),
            ("Rai 1", "Rai 2"),
            ("BBC One - HD", "HD"),
            ("Rai 1: Live", "Live"),
            ("Sky TV", "Sky"),
        ]
        for (lhs, rhs) in different {
            expect(ChannelNameNormalizer.key(lhs) != ChannelNameNormalizer.key(rhs), "\"\(lhs)\" ≠ \"\(rhs)\" (\(ChannelNameNormalizer.key(lhs)) / \(ChannelNameNormalizer.key(rhs)))")
        }
        expect(ChannelNameNormalizer.looseKey("Rai Uno") == ChannelNameNormalizer.looseKey("Rai 1"), "loose: Rai Uno = Rai 1")
        expect(ChannelNameNormalizer.looseKey("Canale 5") == ChannelNameNormalizer.looseKey("5"), "loose: Canale 5 = 5")
        expect(ChannelNameNormalizer.idKeys("BBCOne.uk@HD") == ["bbcone.uk@hd", "bbcone.uk"], "id keys drop the feed")
        expect(ChannelNameNormalizer.key(ChannelNameNormalizer.nameFromID("SkySportF1.it")) == ChannelNameNormalizer.key("SkySport F1"), "name from id")

        print("== matcher")
        let playlistID = UUID()
        let otherPlaylistID = UUID()
        let playlistSource = EPGChannelMatcher.Source(sourceID: UUID(), importID: UUID(), playlistID: playlistID)
        let userSource = EPGChannelMatcher.Source(sourceID: UUID(), importID: UUID(), playlistID: nil)
        let otherSource = EPGChannelMatcher.Source(sourceID: UUID(), importID: UUID(), playlistID: otherPlaylistID)
        let matcher = EPGChannelMatcher(sources: [
            (otherSource, [.init(channelID: "Rai1.it", names: ["Rai 1"])]),
            (userSource, [.init(channelID: "SkySportF1.it", names: ["Sky Sport F1"]), .init(channelID: "Rai1.it", names: ["Rai 1"])]),
            (playlistSource, [.init(channelID: "raiuno.it", names: ["Rai Uno"]), .init(channelID: "bbc1.uk", names: ["BBC One"])]),
        ], overrides: [:])
        func item(_ name: String, tvgID: String? = nil) -> ChannelItem {
            ChannelItem(id: UUID(), playlistID: playlistID, name: name, logo: nil, url: URL(string: "https://example.com/\(UUID().uuidString)"), groupName: "", kind: .live, tvgID: tvgID)
        }
        expect(matcher.match(item("whatever", tvgID: "SKYSPORTF1.IT"))?.channelID == "SkySportF1.it", "tvg-id, case-insensitive")
        expect(matcher.match(item("IT: Sky Sport F1 FHD"))?.channelID == "SkySportF1.it", "normalized name")
        expect(matcher.match(item("Rai 1 HD"))?.sourceID == userSource.sourceID, "strict name before the loose key of the own playlist")
        expect(matcher.match(item("x", tvgID: "bbc1.uk"))?.sourceID == playlistSource.sourceID, "own playlist guide for ids")
        expect(matcher.match(item("BBC One HD", tvgID: "bbc1.uk@SD"))?.channelID == "bbc1.uk", "tvg-id with a feed suffix")
        expect(matcher.match(item("Unknown Channel")) == nil, "no match")
        let pinned = item("Rai 1")
        let pinnedMatcher = EPGChannelMatcher(sources: [(userSource, [.init(channelID: "Rai1.it", names: ["Rai 1"])])], overrides: [
            pinned.bookmarkKey ?? "": .none,
        ])
        expect(pinnedMatcher.match(pinned) == nil, "override: no guide")

        print("== M3U header")
        let header = Data("#EXTM3U url-tvg=\"https://a.example/epg.xml.gz,https://b.example/epg.xml\" x-tvg-url=https://a.example/epg.xml.gz tvg-shift=0\n#EXTINF:-1,One\nhttp://example.com/1\n".utf8)
        var parser = M3UParser()
        parser.consume(header) { _ in }
        parser.finish { _ in }
        expect(parser.guideURLs == ["https://a.example/epg.xml.gz", "https://b.example/epg.xml"], "url-tvg + x-tvg-url: \(parser.guideURLs)")
        expect(EPGImporter.guideURLs(in: "https://a.example/g.xml, ftp://x/y ,https://a.example/g.xml").map(\.absoluteString) == ["https://a.example/g.xml"], "stored guide URLs are http(s), without duplicates")

        print("== streaming parse of an inline guide (gzip and plain)")
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guide-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plain = directory.appendingPathComponent("inline.xml")
        try? xml.data(using: .isoLatin1)?.write(to: plain)
        let gzip = directory.appendingPathComponent("inline.xml.gz")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "gzip -c '\(plain.path)' > '\(gzip.path)'"]
        try? task.run()
        task.waitUntilExit()
        for file in [plain, gzip] {
            var channels: [XMLTVChannel] = []
            var programmes: [XMLTVProgramme] = []
            let window = DateInterval(start: Date(timeIntervalSince1970: 1_893_456_000 - 86_400), duration: 7 * 86_400)
            let parser = XMLTVParser(
                window: window,
                wantsChannel: { $0.id == "a.it" },
                wantsChannelID: { _ in false },
                onChannel: { channel, _ in channels.append(channel) },
                onProgramme: { programmes.append($0) }
            )
            guard let stream = InflatingInputStream(fileURL: file) else {
                expect(false, "open \(file.lastPathComponent)")
                continue
            }
            stream.open()
            do {
                try parser.parse(stream)
            } catch {
                expect(false, "parse \(file.lastPathComponent): \(error)")
            }
            stream.close()
            let name = file.lastPathComponent
            expect(channels.count == 2 && channels[0].displayNames == ["Canale A"] && channels[0].icon == "https://example.com/a.png", "\(name): channels")
            expect(programmes.map(\.title) == ["Caffè & Notizie", "Open ended", "Noon"], "\(name): kept programmes in order, entities, Latin-1: \(programmes.map(\.title))")
            if let first = programmes.first {
                expect(first.summary == "News <live>" && first.categories == ["News"] && first.episode == "S1 E2" && first.icon == "https://example.com/p.jpg", "\(name): CDATA, categories, episode, icon")
            }
            if programmes.count > 1 {
                expect(programmes[1].stop == programmes[2].start, "\(name): open-ended programme ends at the next one")
            }
            expect(parser.statistics.skippedUnwantedChannel == 1 && parser.statistics.skippedOutsideWindow == 1, "\(name): skipped unwanted and out-of-window")
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Lifecycle

    /// Offline refreshes through `EPGImporter.refresh` (a file URL stands in for the server): re-reading a guide
    /// when the playlist channels change, and files cut short.
    @MainActor
    static func lifecycleCheck() async throws {
        print("== refresh lifecycle (re-matching after a playlist import, incomplete files)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guide-check-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let guideURL = directory.appendingPathComponent("guide.xml")
        try generate(guideURL, channels: 20, days: 2)
        let fullGuide = try Data(contentsOf: guideURL)

        let schema = Schema(ModelRegistry.all)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: directory.appendingPathComponent("store.sqlite")))
        let context = ModelContext(container)
        let playlistID = UUID()
        let importID = UUID()
        let playlist = Playlist(uuid: playlistID, name: "Check", url: URL(string: "https://example.com/list.m3u") ?? guideURL, createdOn: .now)
        playlist.currentImportID = importID
        context.insert(playlist)
        func addChannels(_ range: Range<Int>) throws {
            for index in range {
                context.insert(PlaylistChannel(uuid: UUID(), name: "Channel \(index) HD", groupName: "Live", url: URL(string: "https://example.com/live/\(index)"), sortIndex: index, importID: importID, playlistID: playlistID, kind: .live))
            }
            try context.save()
        }
        try addChannels(0..<10)

        let importer = EPGImporter(container: container, downloadsDirectory: directory.appendingPathComponent("downloads"))
        let sourceID = try await importer.addSource(url: guideURL, name: nil)
        let first = try await importer.refresh(sourceID: sourceID) { _ in }
        expect(first.isComplete && first.storedChannelCount == 10, "first refresh: \(first.storedChannelCount) channels with programmes")
        expect(try await importer.sourcesNeedingRematch(forPlaylist: playlistID).isEmpty, "same channels: nothing to read again")

        try addChannels(10..<15)
        let rematch = try await importer.sourcesNeedingRematch(forPlaylist: playlistID)
        expect(rematch == [sourceID], "new playlist channels: the user's guide is read again")
        let second = try await importer.refresh(sourceID: sourceID) { _ in }
        expect(second.storedChannelCount == 15, "the unchanged file is read again for the new channels: \(second.storedChannelCount) channels")
        expect(try await importer.sourcesNeedingRematch(forPlaylist: playlistID).isEmpty, "after the refresh: nothing to read again")
        let unchanged = try await importer.refresh(sourceID: sourceID) { _ in }
        expect(unchanged.programmeCount == second.programmeCount, "same file, same channels: not read again")

        // The server now sends a file cut short: the previous, complete guide stays.
        try fullGuide.prefix(fullGuide.count * 2 / 5).write(to: guideURL)
        do {
            _ = try await importer.refresh(sourceID: sourceID) { _ in }
            expect(false, "a truncated file with fewer programmes is refused")
        } catch EPGImportError.incomplete {
            let source = try ModelContext(container).fetch(EPGQueries.source(uuid: sourceID)).first
            let rows = try ModelContext(container).fetchCount(FetchDescriptor<EPGProgramme>())
            expect(source?.programmeCount == second.programmeCount && rows == second.programmeCount, "a truncated file keeps the previous guide (\(rows) programmes)")
            expect(source?.lastError != nil, "the failure is recorded")
        }

        // Without a previous guide, a truncated file is better than nothing, but it is read again next time.
        let partialURL = directory.appendingPathComponent("partial.xml")
        try fullGuide.prefix(fullGuide.count / 2).write(to: partialURL)
        let partialSourceID = try await importer.addSource(url: partialURL, name: nil)
        let partial = try await importer.refresh(sourceID: partialSourceID) { _ in }
        expect(!partial.isComplete && partial.programmeCount > 0, "a first, truncated guide is stored as incomplete (\(partial.programmeCount) programmes)")
        let partialSource = try ModelContext(container).fetch(EPGQueries.source(uuid: partialSourceID)).first
        expect(partialSource?.contentHash == nil, "an incomplete guide is not remembered as read")

        // A gzip file cut short: the inflating stream reports it.
        let gzipURL = directory.appendingPathComponent("guide.xml.gz")
        try fullGuide.write(to: guideURL)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "gzip -c '\(guideURL.path)' > '\(gzipURL.path)'"]
        try task.run()
        task.waitUntilExit()
        let gzip = try Data(contentsOf: gzipURL)
        try gzip.prefix(gzip.count / 2).write(to: gzipURL)
        var kept = 0
        let parser = XMLTVParser(
            window: DateInterval(start: .now.addingTimeInterval(-86_400), duration: 7 * 86_400),
            wantsChannel: { _ in true },
            wantsChannelID: { _ in true },
            onChannel: { _, _ in },
            onProgramme: { _ in kept += 1 }
        )
        if let stream = InflatingInputStream(fileURL: gzipURL) {
            stream.open()
            try? parser.parse(stream)
            expect(kept > 0 && (stream.streamError != nil || parser.endedEarly), "truncated gzip: \(kept) programmes read, end reported (\(stream.streamError.map { "\($0)" } ?? "parser"))")
            stream.close()
        }
    }

    // MARK: - Parse

    static func parse(_ fileURL: URL, wantedLimit: Int?) throws {
        let clock = ContinuousClock()
        let started = clock.now
        var channelIDs: [String] = []
        var programmeCount = 0
        var titleBytes = 0
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-EPGImporter.windowBefore), end: now.addingTimeInterval(EPGImporter.windowAfter))
        let parser = XMLTVParser(
            window: window,
            wantsChannel: { _ in
                wantedLimit.map { channelIDs.count < $0 } ?? true
            },
            wantsChannelID: { _ in wantedLimit == nil },
            onChannel: { channel, _ in channelIDs.append(channel.id) },
            onProgramme: { programme in
                programmeCount += 1
                titleBytes += programme.title.utf8.count
            }
        )
        guard let stream = InflatingInputStream(fileURL: fileURL) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        stream.open()
        try parser.parse(stream)
        stream.close()
        let elapsed = clock.now - started
        let stats = parser.statistics
        let megabytes = Double(stream.totalBytesRead) / 1_048_576
        print(String(
            format: "  %@: %.1f MB on disk, %.1f MB of XML, %d channels, %d programmes (%d kept, %d outside the window, %d of other channels) in %.0f ms (%.1f MB/s)",
            fileURL.lastPathComponent, Double(size) / 1_048_576, megabytes, stats.channels, stats.programmes, stats.keptProgrammes,
            stats.skippedOutsideWindow, stats.skippedUnwantedChannel, milliseconds(elapsed), megabytes / (milliseconds(elapsed) / 1_000)
        ))
        expect(stats.channels > 0, "channels found")
        expect(programmeCount == stats.keptProgrammes, "every kept programme delivered")
    }

    // MARK: - Import

    @MainActor
    static func importCheck(_ fileURL: URL, storeURL: URL) async throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
        }
        let schema = Schema(ModelRegistry.all)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))

        // Collect the guide's channel names, then build a playlist with half of them (and some noise).
        var guideChannels: [XMLTVChannel] = []
        let collector = XMLTVParser(
            window: DateInterval(start: .distantPast, end: .distantPast),
            wantsChannel: { _ in false },
            wantsChannelID: { _ in false },
            onChannel: { channel, _ in guideChannels.append(channel) },
            onProgramme: { _ in }
        )
        if let stream = InflatingInputStream(fileURL: fileURL) {
            stream.open()
            try collector.parse(stream)
            stream.close()
        }
        let playlistID = UUID()
        let importID = UUID()
        let context = ModelContext(container)
        let playlist = Playlist(uuid: playlistID, name: "Check", url: URL(string: "https://example.com/list.m3u") ?? URL(fileURLWithPath: "/"), createdOn: .now)
        context.insert(playlist)
        var expectedNames: [String] = []
        for (index, channel) in guideChannels.enumerated() where index.isMultiple(of: 2) {
            // Odd decorations, as IPTV playlists have them: matching must see through them.
            let name = channel.displayNames.first ?? channel.id
            let decorated = index.isMultiple(of: 4) ? "IT: \(name) FHD" : "\(name) HD"
            expectedNames.append(name)
            context.insert(PlaylistChannel(
                uuid: UUID(), name: decorated, tvgID: index.isMultiple(of: 8) ? channel.id : nil,
                groupName: "Group \(index % 10)", url: URL(string: "https://example.com/live/\(index)"), sortIndex: index, importID: importID, playlistID: playlistID, kind: .live
            ))
        }
        for index in 0..<2_000 {
            context.insert(PlaylistChannel(uuid: UUID(), name: "Movie \(index)", groupName: "Movies", url: URL(string: "https://example.com/movie/\(index).mp4"), sortIndex: 100_000 + index, importID: importID, playlistID: playlistID, kind: .movie))
        }
        playlist.currentImportID = importID
        try context.save()
        print("== import \(fileURL.lastPathComponent): playlist with \(expectedNames.count) of \(guideChannels.count) guide channels")

        // BATCH=<n> compares batch sizes (the app's default otherwise).
        let batch = ProcessInfo.processInfo.environment["BATCH"].flatMap(Int.init)
        let importer = batch.map { EPGImporter(container: container, batchSize: $0) } ?? EPGImporter(container: container)
        let sourceID = try await importer.addSource(url: URL(string: "https://example.com/guide.xml.gz") ?? fileURL, name: "Check")
        var wanted = EPGWantedChannels()
        for channel in try context.fetch(FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.kindRawValue == 0 })) {
            wanted.add(tvgID: channel.tvgID, name: channel.name)
        }
        let first = try await importer.importFile(fileURL, sourceID: sourceID, wanted: wanted) { _ in }
        print(String(format: "  first import: %d programmes of %d/%d channels in %.0f ms", first.programmeCount, first.storedChannelCount, first.channelCount, milliseconds(first.duration)))
        expect(first.programmeCount > 0, "programmes stored")

        let second = try await importer.importFile(fileURL, sourceID: sourceID, wanted: wanted) { _ in }
        print(String(format: "  refresh: %d programmes in %.0f ms", second.programmeCount, milliseconds(second.duration)))
        let readContext = ModelContext(container)
        let totalRows = try readContext.fetchCount(FetchDescriptor<EPGProgramme>())
        expect(totalRows == second.programmeCount, "refresh replaced the previous import: \(totalRows) rows")

        guard let source = try readContext.fetch(EPGQueries.source(uuid: sourceID)).first, let currentImportID = source.currentImportID else {
            expect(false, "source has a current import")
            return
        }
        let reader = EPGReader(container: container)
        let clock = ContinuousClock()
        var started = clock.now
        await reader.reload()
        print(String(format: "  reader reload (matcher): %.1f ms", milliseconds(clock.now - started)))

        started = clock.now
        let channels = await reader.guideChannels(importIDs: [importID])
        print(String(format: "  guide channels of the playlist: %d in %.1f ms", channels.count, milliseconds(clock.now - started)))
        expect(channels.count >= first.storedChannelCount * 9 / 10, "most playlist channels matched (\(channels.count) for \(first.storedChannelCount) guide channels with programmes)")
        expect(channels.allSatisfy { $0.ref.importID == currentImportID }, "matches point at the current import")

        if let channel = channels.first {
            started = clock.now
            let nowNext = await reader.nowNext(for: channel.item, at: .now)
            print(String(format: "  now/next of %@: %.2f ms → %@ / %@", channel.item.displayName, milliseconds(clock.now - started), nowNext?.current?.title ?? "-", nowNext?.next?.title ?? "-"))
            started = clock.now
            let day = Calendar.current.dateInterval(of: .day, for: .now) ?? DateInterval(start: .now, duration: 86_400)
            let programmes = await reader.programmes(for: channel.ref, in: day)
            print(String(format: "  programmes of today: %d in %.2f ms", programmes.count, milliseconds(clock.now - started)))
            expect(zip(programmes, programmes.dropFirst()).allSatisfy { $0.start <= $1.start }, "programmes in order")
            if let title = programmes.last?.title, let word = title.split(separator: " ").max(by: { $0.count < $1.count }), word.count >= 3 {
                started = clock.now
                let results = await reader.search(term: String(word), importIDs: [importID], now: .now, limit: 100)
                print(String(format: "  search \"%@\": %d results in %.1f ms", String(word), results.count, milliseconds(clock.now - started)))
                expect(!results.isEmpty, "search finds the programme")
                expect(zip(results, results.dropFirst()).allSatisfy { $0.programme.start <= $1.programme.start }, "search results soonest first")
            }
            if let title = programmes.first(where: { $0.title.split(separator: " ").count >= 2 })?.title {
                let words = title.split(separator: " ")
                // Two words of the title, reversed and lowercased: every word must match, in any order.
                let term = "\(words[words.count - 1].lowercased()) \(words[0].lowercased())"
                started = clock.now
                let results = await reader.search(term: term, importIDs: [importID], now: .now, limit: 100)
                print(String(format: "  search \"%@\" (two words, any order): %d results in %.1f ms", term, results.count, milliseconds(clock.now - started)))
                let lowered = term.split(separator: " ").map { $0.lowercased() }
                let allMatch = results.allSatisfy { result in
                    let text = "\(result.programme.title) \(result.programme.subtitle) \(result.programme.summary)".lowercased()
                    return lowered.allSatisfy { text.contains($0) }
                }
                expect(!results.isEmpty && allMatch, "multi-word search: every result contains both words")
                expect(results.count == 100 || results.contains { $0.programme.title == title }, "multi-word search finds \"\(title)\"")
            }
        }

        started = clock.now
        try await importer.prune(now: Date().addingTimeInterval(8 * 86_400))
        let afterPrune = try ModelContext(container).fetchCount(FetchDescriptor<EPGProgramme>())
        print(String(format: "  prune 8 days ahead: %.1f ms, %d rows left", milliseconds(clock.now - started), afterPrune))
        expect(afterPrune == 0, "prune removes ended programmes")

        try await importer.deleteSource(sourceID)
        let channelRows = try ModelContext(container).fetchCount(FetchDescriptor<EPGChannel>())
        expect(channelRows == 0, "deleting the source deletes its channels")
        let attributes = try? FileManager.default.attributesOfItem(atPath: storeURL.path)
        print("  store file: \(((attributes?[.size] as? Int64) ?? 0).formatted(.byteCount(style: .file)))")
    }

    // MARK: - Delete

    /// Deleting a large guide (bug: "deleting a TV guide crashes"): two user sources with every channel of the
    /// file, matching overrides on both, then one is deleted while a reader keeps querying the guide. The deleted
    /// source must leave no source, channel, programme or override row, the other one must be untouched, and the
    /// guide must keep answering from the other source.
    @MainActor
    static func deleteCheck(_ fileURL: URL, storeURL: URL) async throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
        }
        let schema = Schema(ModelRegistry.all)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))

        var guideChannels: [XMLTVChannel] = []
        let collector = XMLTVParser(
            window: DateInterval(start: .distantPast, end: .distantPast),
            wantsChannel: { _ in false },
            wantsChannelID: { _ in false },
            onChannel: { channel, _ in guideChannels.append(channel) },
            onProgramme: { _ in }
        )
        if let stream = InflatingInputStream(fileURL: fileURL) {
            stream.open()
            try collector.parse(stream)
            stream.close()
        }
        let playlistID = UUID()
        let importID = UUID()
        let context = ModelContext(container)
        let playlist = Playlist(uuid: playlistID, name: "Check", url: URL(string: "https://example.com/list.m3u") ?? URL(fileURLWithPath: "/"), createdOn: .now)
        context.insert(playlist)
        var wanted = EPGWantedChannels()
        for (index, channel) in guideChannels.enumerated() {
            let name = channel.displayNames.first ?? channel.id
            context.insert(PlaylistChannel(uuid: UUID(), name: name, tvgID: channel.id, groupName: "Live", url: URL(string: "https://example.com/live/\(index)"), sortIndex: index, importID: importID, playlistID: playlistID, kind: .live))
            wanted.add(tvgID: channel.id, name: name)
        }
        playlist.currentImportID = importID
        try context.save()

        let importer = EPGImporter(container: container)
        let deleted = try await importer.addSource(url: URL(string: "https://example.com/deleted.xml.gz") ?? fileURL, name: "Deleted")
        let kept = try await importer.addSource(url: URL(string: "https://example.com/kept.xml.gz") ?? fileURL, name: "Kept")
        let clock = ContinuousClock()
        var started = clock.now
        let first = try await importer.importFile(fileURL, sourceID: deleted, wanted: wanted) { _ in }
        let second = try await importer.importFile(fileURL, sourceID: kept, wanted: wanted) { _ in }
        print(String(format: "== delete: 2 sources x %d programmes of %d channels, imported in %.0f ms", first.programmeCount, first.storedChannelCount, milliseconds(clock.now - started)))
        // Manual matches on both sources (one per channel of the first 50).
        for (index, channel) in guideChannels.prefix(50).enumerated() {
            let source = index.isMultiple(of: 2) ? deleted : kept
            context.insert(EPGChannelOverride(key: "check-\(index)", playlistID: playlistID, sourceID: source, channelID: channel.id))
        }
        try context.save()

        let reader = EPGReader(container: container)
        _ = await reader.reload()
        let item = ChannelItem(id: UUID(), playlistID: playlistID, name: guideChannels.last?.displayNames.first, logo: nil, url: URL(string: "https://example.com/live/\(guideChannels.count - 1)"), groupName: "Live", kind: .live, tvgID: guideChannels.last?.id)

        // Readers keep querying while the source is deleted, like the open guide grid and now / next would.
        let reading = Task.detached {
            var queries = 0
            while !Task.isCancelled {
                if let ref = await reader.ref(for: item) {
                    _ = await reader.programmes(for: ref, in: DateInterval(start: .now, duration: 6 * 3_600))
                }
                _ = await reader.nowNext(for: item, at: .now)
                _ = await reader.guideChannels(importIDs: [importID])
                queries += 1
            }
            return queries
        }
        started = clock.now
        try await importer.deleteSource(deleted)
        let deleteDuration = clock.now - started
        _ = await reader.reload()
        reading.cancel()
        let queries = await reading.value
        print(String(format: "  deleteSource: %.0f ms (%d guide reads meanwhile)", milliseconds(deleteDuration), queries))

        let check = ModelContext(container)
        let deletedOptional: UUID? = deleted
        expect(try check.fetchCount(EPGQueries.source(uuid: deleted)) == 0, "the source is gone")
        expect(try check.fetchCount(FetchDescriptor<EPGProgramme>(predicate: #Predicate { $0.sourceID == deleted })) == 0, "its programmes are gone")
        expect(try check.fetchCount(FetchDescriptor<EPGChannel>(predicate: #Predicate { $0.sourceID == deleted })) == 0, "its channels are gone")
        expect(try check.fetchCount(FetchDescriptor<EPGChannelOverride>(predicate: #Predicate { $0.sourceID == deletedOptional })) == 0, "its manual matches are gone")
        expect(try check.fetchCount(FetchDescriptor<EPGProgramme>(predicate: #Predicate { $0.sourceID == kept })) == second.programmeCount, "the other source keeps its \(second.programmeCount) programmes")
        expect(try check.fetchCount(FetchDescriptor<EPGChannelOverride>()) == 25, "the other source keeps its manual matches")
        let ref = await reader.ref(for: item)
        expect(ref?.sourceID == kept, "the channel now has the guide of the other source")
        expect(await reader.nowNext(for: item, at: .now)?.current != nil, "now / next still answers")

        // Deleting a source that is already gone (a second tap, or a refresh that removed it) is harmless.
        try await importer.deleteSource(deleted)
        expect(true, "deleting it again does nothing")

        // Deleted while its guide is being imported (a playlist sync or another path that does not wait for the
        // refresh to stop): the import fails, and nothing of the source is left once it has stopped. The import is
        // held on its parse thread at its first programme until the source is deleted, so the deletion always lands
        // in the middle of it (a small guide is otherwise read before a polling check sees it start).
        let racing = try await importer.addSource(url: URL(string: "https://example.com/racing.xml.gz") ?? fileURL, name: "Racing")
        let gate = ParseGate()
        let racingImport = Task {
            try await importer.importFile(fileURL, sourceID: racing, wanted: wanted) { gate.holdOnce($0) }
        }
        let deadline = clock.now + .seconds(120)
        while !gate.isHeld, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        expect(gate.isHeld, "the import of the source to delete is under way")
        try await importer.deleteSource(racing)
        gate.open()
        let racingResult = await racingImport.result
        if case .success = racingResult {
            expect(false, "the import of a deleted source fails")
        } else {
            expect(true, "the import of a deleted source fails")
        }
        let racingRows = try ModelContext(container).fetchCount(FetchDescriptor<EPGProgramme>(predicate: #Predicate { $0.sourceID == racing }))
            + ModelContext(container).fetchCount(FetchDescriptor<EPGChannel>(predicate: #Predicate { $0.sourceID == racing }))
        expect(racingRows == 0, "nothing of a source deleted during its import is left (\(racingRows) rows)")

        // Cancelled, awaited, then deleted, as EPGStore.deleteSource does with a running refresh.
        let cancelled = try await importer.addSource(url: URL(string: "https://example.com/cancelled.xml.gz") ?? fileURL, name: "Cancelled")
        let cancelledImport = Task {
            try await importer.importFile(fileURL, sourceID: cancelled, wanted: wanted) { _ in }
        }
        try await Task.sleep(for: .seconds(2))
        cancelledImport.cancel()
        _ = await cancelledImport.result
        try await importer.deleteSource(cancelled)
        let cancelledRows = try ModelContext(container).fetchCount(FetchDescriptor<EPGProgramme>(predicate: #Predicate { $0.sourceID == cancelled }))
        expect(cancelledRows == 0, "nothing of a source deleted after a cancelled refresh is left")
        expect(try ModelContext(container).fetchCount(FetchDescriptor<EPGProgramme>(predicate: #Predicate { $0.sourceID == kept })) == second.programmeCount, "the other source is still untouched")
    }

    // MARK: - Refresh

    /// The real refresh path: a playlist with the given channel names, a user source with `url`, two refreshes.
    @MainActor
    static func refreshCheck(_ url: URL, storeURL: URL, names: [String]) async throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
        }
        let schema = Schema(ModelRegistry.all)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
        let context = ModelContext(container)
        let playlistID = UUID()
        let importID = UUID()
        let playlist = Playlist(uuid: playlistID, name: "Check", url: URL(string: "https://example.com/list.m3u") ?? url, createdOn: .now)
        playlist.currentImportID = importID
        context.insert(playlist)
        for (index, name) in names.enumerated() {
            context.insert(PlaylistChannel(uuid: UUID(), name: name, groupName: "Live", url: URL(string: "https://example.com/live/\(index)"), sortIndex: index, importID: importID, playlistID: playlistID, kind: .live))
        }
        try context.save()

        print("== refresh \(url.absoluteString) for \(names.count) playlist channels")
        let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("guide-check-downloads-\(UUID().uuidString)")
        let importer = EPGImporter(container: container, downloadsDirectory: downloads)
        let sourceID = try await importer.addSource(url: url, name: nil)
        let first = try await importer.refresh(sourceID: sourceID) { _ in }
        print(String(format: "  first refresh: %.1f MB, %d programmes of %d/%d channels in %.0f ms",
                     Double(first.downloadedBytes) / 1_048_576, first.programmeCount, first.storedChannelCount, first.channelCount, milliseconds(first.duration)))
        expect(first.programmeCount > 0, "programmes stored")
        let second = try await importer.refresh(sourceID: sourceID) { _ in }
        print(String(format: "  second refresh (same file): %.1f MB downloaded, %.0f ms", Double(second.downloadedBytes) / 1_048_576, milliseconds(second.duration)))
        expect(second.programmeCount == first.programmeCount, "an unchanged guide keeps its programmes")
        if let source = try ModelContext(container).fetch(EPGQueries.source(uuid: sourceID)).first, source.entityTag != nil || source.lastModifiedHeader != nil {
            expect(second.downloadedBytes == 0, "conditional request: the server answered 304, nothing downloaded (ETag \(source.entityTag ?? "-"))")
        } else {
            print("  (the server sends no ETag / Last-Modified: no conditional request)")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []
        expect(leftovers.isEmpty, "downloads are removed")

        let reader = EPGReader(container: container)
        await reader.reload()
        let channels = await reader.guideChannels(importIDs: [importID])
        let matched = Set(channels.map(\.item.displayName))
        for name in names {
            if matched.contains(name), let channel = channels.first(where: { $0.item.displayName == name }) {
                let now = await reader.nowNext(for: channel.item)
                print("  match  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) → \(channel.ref.channelID.padding(toLength: 26, withPad: " ", startingAt: 0)) now: \(now?.current?.title ?? "-")")
            } else {
                print("  none   \(name)")
            }
        }
        expect(matched.count * 10 >= names.count * 7, "at least 70% of the channels matched (\(matched.count)/\(names.count))")
        try? FileManager.default.removeItem(at: downloads)
    }

    // MARK: - Generate

    /// Writes an XMLTV file with `channels` channels and half-hour programmes from 12 hours ago for `days` days.
    static func generate(_ url: URL, channels: Int, days: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        var buffer = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv generator-info-name=\"guide-check\">\n"
        func flush(force: Bool = false) throws {
            if force || buffer.utf8.count > 1 << 20 {
                try handle.write(contentsOf: Data(buffer.utf8))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        for channel in 0..<channels {
            buffer += "  <channel id=\"channel\(channel).xx\">\n    <display-name lang=\"en\">Channel \(channel)</display-name>\n    <icon src=\"https://example.com/logos/\(channel).png\"/>\n  </channel>\n"
            try flush()
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        // From 12 hours ago (on a half hour), so part of the guide is before the window and the rest inside it.
        let now = Date().timeIntervalSince1970
        let start = Date(timeIntervalSince1970: (now / 1_800).rounded(.down) * 1_800 - 12 * 3_600)
        let slots = days * 48
        let stamps = (0...slots).map { formatter.string(from: start.addingTimeInterval(TimeInterval($0) * 1_800)) + " +0000" }
        for channel in 0..<channels {
            for slot in 0..<slots {
                buffer += "  <programme start=\"\(stamps[slot])\" stop=\"\(stamps[slot + 1])\" channel=\"channel\(channel).xx\">\n"
                buffer += "    <title lang=\"en\">Show \(slot % 97) on \(channel)</title>\n"
                buffer += "    <desc lang=\"en\">Episode \(slot) of a synthetic programme used to measure the guide import. It has a description of a typical length, with a few sentences.</desc>\n"
                buffer += "    <category lang=\"en\">Category \(slot % 7)</category>\n    <episode-num system=\"xmltv_ns\">\(slot % 5).\(slot % 20).</episode-num>\n  </programme>\n"
                try flush()
            }
        }
        buffer += "</tv>\n"
        try flush(force: true)
    }
}

/// Holds a guide import on its parse thread at its first programme (its first `reading` progress) until `open()`: a
/// check can then act in the middle of the import whatever the size of the guide and the speed of the Mac. The parse
/// thread holds no store transaction there, and the importer actor is free meanwhile (it awaits the parse).
final class ParseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private let release = DispatchSemaphore(value: 0)

    var isHeld: Bool {
        lock.withLock { held }
    }

    /// The import's progress callback.
    func holdOnce(_ progress: EPGRefreshProgress) {
        guard progress.phase == .reading else {
            return
        }
        let isFirst = lock.withLock {
            defer {
                held = true
            }
            return !held
        }
        if isFirst {
            // Never forever: a check that fails must not hang the script.
            _ = release.wait(timeout: .now() + 60)
        }
    }

    func open() {
        release.signal()
    }
}
