//
//  NewMain.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//
//  Benchmark driver for the new playlist pipeline (M3UParser + PlaylistImporter), compiled together with the
//  app sources by run.sh. Usage: bench-new parse|import|selftest <playlist.m3u|->
//

import Foundation
import SwiftData

@main
struct NewBenchmark {
    @MainActor
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            print("usage: bench-new parse|import|selftest <playlist.m3u|->")
            exit(2)
        }
        let path = arguments[2]
        switch arguments[1] {
        case "parse":
            try parse(path)
        case "import":
            try await importPlaylist(path)
        case "selftest":
            ParserSelfTest.run()
        default:
            exit(2)
        }
    }

    /// Parser only, fed in 64 KB chunks like a network stream.
    static func parse(_ path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var timings: [Double] = []
        var count = 0
        var sample: [M3UEntry] = []
        for iteration in 0..<7 {
            var parsed = 0
            var parser = M3UParser()
            let elapsed = Bench.time {
                var offset = 0
                while offset < data.count {
                    let end = min(offset + 65_536, data.count)
                    parser.consume(data.subdata(in: offset..<end)) { entry in
                        parsed += 1
                        if iteration == 0, sample.count < 3 || (entry.tvgName == nil && sample.count < 4) {
                            sample.append(entry)
                        }
                    }
                    offset = end
                }
                parser.finish { _ in parsed += 1 }
            }
            count = parsed
            timings.append(elapsed)
        }
        print(String(format: "new parse: entries=%d median=%.1f ms min=%.1f ms peakRSS=%.0f MB", count, Bench.median(timings), timings.min() ?? 0, Bench.peakRSSMegabytes()))
        for entry in sample {
            print("  sample: title=\(entry.title ?? "nil") | tvg-name=\(entry.tvgName ?? "nil") | group=\(entry.group ?? "nil") | logo=\(entry.logo ?? "nil") | url=\(entry.url)")
        }
    }

    /// Full pipeline: file:// download stream -> parser -> batched background SwiftData inserts into an on-disk store.
    @MainActor
    static func importPlaylist(_ path: String) async throws {
        let storeURL = Bench.temporaryStoreURL("new")
        defer { Bench.removeStore(storeURL) }
        let schema = Schema([Playlist.self, PlaylistChannel.self, PlaylistChannelGroup.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
        let importer = PlaylistImporter(container: container)
        let uuid = UUID()
        let url = path.hasPrefix("http://") || path.hasPrefix("https://") ? URL(string: path) ?? URL(fileURLWithPath: path) : URL(fileURLWithPath: path)
        try await importer.createPlaylist(uuid: uuid, name: "Bench", url: url)

        let monitor = MainThreadStallMonitor()
        monitor.start()
        let updates = ProgressCounter()
        let clock = ContinuousClock()
        let start = clock.now
        let summary: PlaylistImportSummary
        do {
            summary = try await importer.importContent(ofPlaylist: uuid, from: url) { _ in updates.increment() }
        } catch {
            let left = try ModelContext(container).fetchCount(FetchDescriptor<PlaylistChannel>())
            print("new import failed: \(error.localizedDescription) (channels left: \(left))")
            return
        }
        let importMilliseconds = Bench.milliseconds(clock.now - start)
        monitor.stop()

        let context = ModelContext(container)
        let channels = try context.fetchCount(FetchDescriptor<PlaylistChannel>())
        let groups = try context.fetchCount(FetchDescriptor<PlaylistChannelGroup>())
        print(String(format: "new import: channels=%d groups=%d stored=%d/%d time=%.0f ms progressUpdates=%d maxMainStall=%.1f ms peakRSS=%.0f MB",
                     summary.channelCount, summary.groupCount, channels, groups, importMilliseconds, updates.value, monitor.maxStallMilliseconds, Bench.peakRSSMegabytes()))

        // Refresh replaces the content: the row count must stay the same.
        let refreshStart = clock.now
        _ = try await importer.importContent(ofPlaylist: uuid, from: url) { _ in }
        let refreshMilliseconds = Bench.milliseconds(clock.now - refreshStart)
        let afterRefresh = try ModelContext(container).fetchCount(FetchDescriptor<PlaylistChannel>())
        print(String(format: "new refresh: time=%.0f ms channelsAfterRefresh=%d", refreshMilliseconds, afterRefresh))

        // Cancellation leaves the previous content untouched.
        let cancelled = Task { try await importer.importContent(ofPlaylist: uuid, from: url) { _ in } }
        try await Task.sleep(for: .milliseconds(300))
        cancelled.cancel()
        let cancelResult = await cancelled.result
        let afterCancel = try ModelContext(container).fetchCount(FetchDescriptor<PlaylistChannel>())
        if case .failure(let error) = cancelResult {
            print("new cancel: error=\(type(of: error)) channelsAfterCancel=\(afterCancel)")
        } else {
            print("new cancel: finished before cancel, channelsAfterCancel=\(afterCancel)")
        }

        // Rows of a playlist deleted outside the importer (plain context delete) are removed by the purge.
        let other = UUID()
        try await importer.createPlaylist(uuid: other, name: "Other", url: url)
        _ = try await importer.importContent(ofPlaylist: other, from: url) { _ in }
        let plain = ModelContext(container)
        try plain.delete(model: Playlist.self, where: #Predicate { $0.uuid == other })
        try plain.save()
        let beforePurge = try ModelContext(container).fetchCount(FetchDescriptor<PlaylistChannel>())
        try await importer.purgeOrphanedContent()
        let purgeContext = ModelContext(container)
        print("new purge: channelsBefore=\(beforePurge) channelsAfter=\(try purgeContext.fetchCount(FetchDescriptor<PlaylistChannel>())) groupsAfter=\(try purgeContext.fetchCount(FetchDescriptor<PlaylistChannelGroup>()))")

        let deleteStart = clock.now
        try await importer.deletePlaylist(uuid: uuid)
        let deleteMilliseconds = Bench.milliseconds(clock.now - deleteStart)
        let verify = ModelContext(container)
        print(String(format: "new delete: time=%.0f ms playlists=%d channels=%d groups=%d", deleteMilliseconds,
                     try verify.fetchCount(FetchDescriptor<Playlist>()), try verify.fetchCount(FetchDescriptor<PlaylistChannel>()), try verify.fetchCount(FetchDescriptor<PlaylistChannelGroup>())))
    }
}

final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// Edge cases of the M3U grammar. Every input is also fed one byte at a time to exercise chunk boundaries.
enum ParserSelfTest {
    static func run() {
        var failures = 0
        func check(_ name: String, _ input: String, _ expected: [M3UEntry]) {
            let data = Data(input.utf8)
            let whole = M3UParser.parse(data)
            var parser = M3UParser()
            var byByte: [M3UEntry] = []
            for byte in data {
                parser.consume(Data([byte])) { byByte.append($0) }
            }
            parser.finish { byByte.append($0) }
            if whole != expected || byByte != expected {
                failures += 1
                print("FAIL \(name)\n  expected: \(expected)\n  whole:    \(whole)\n  by byte:  \(byByte)")
            } else {
                print("ok   \(name)")
            }
        }

        check("quoted attributes with spaces, title with commas",
              "#EXTM3U\n#EXTINF:-1 tvg-id=\"news.us\" tvg-name=\"Fox News HD\" tvg-logo=\"https://l.example/fox.png\" group-title=\"News, USA\",Fox News, Live HD\nhttp://s.example/1\n",
              [M3UEntry(title: "Fox News, Live HD", url: "http://s.example/1", tvgID: "news.us", tvgName: "Fox News HD", logo: "https://l.example/fox.png", group: "News, USA", duration: nil)])
        check("CRLF, BOM, no header, positive duration",
              "\u{FEFF}#EXTINF:123 group-title=\"Movies\",Movie A\r\nhttps://s.example/a.mp4\r\n",
              [M3UEntry(title: "Movie A", url: "https://s.example/a.mp4", group: "Movies", duration: 123)])
        check("CR only line endings",
              "#EXTM3U\r#EXTINF:-1,One\rhttp://s.example/1\r#EXTINF:-1,Two\rhttp://s.example/2",
              [M3UEntry(title: "One", url: "http://s.example/1"), M3UEntry(title: "Two", url: "http://s.example/2")])
        check("EXTGRP, option lines and blank lines between EXTINF and URL",
              "#EXTM3U\n\n#EXTINF:-1,Sky\n#EXTGRP:Sports\n#EXTVLCOPT:http-user-agent=VLC\n\n   http://s.example/sky   \n",
              [M3UEntry(title: "Sky", url: "http://s.example/sky", group: "Sports")])
        check("group-title wins over EXTGRP",
              "#EXTGRP:Other\n#EXTINF:-1 group-title=\"Kids\",Cartoon\nhttp://s.example/c\n",
              [M3UEntry(title: "Cartoon", url: "http://s.example/c", group: "Kids")])
        check("empty and unusable logos are dropped, protocol-relative logos fixed",
              "#EXTINF:-1 tvg-logo=\"\",A\nhttp://s/a\n#EXTINF:-1 tvg-logo=\"none\",B\nhttp://s/b\n#EXTINF:-1 logo=//cdn.example/b.png,C\nhttp://s/c\n",
              [M3UEntry(title: "A", url: "http://s/a"), M3UEntry(title: "B", url: "http://s/b"), M3UEntry(title: "C", url: "http://s/c", logo: "https://cdn.example/b.png")])
        check("single quotes, unquoted values, case-insensitive keys and tags",
              "#extinf:-1 TVG-NAME='My Channel' Group-Title=Music,Title\nhttp://s/m\n",
              [M3UEntry(title: "Title", url: "http://s/m", tvgName: "My Channel", group: "Music")])
        check("missing title falls back to tvg-name",
              "#EXTINF:-1 tvg-name=\"Only Name\"\nhttp://s/o\n",
              [M3UEntry(title: nil, url: "http://s/o", tvgName: "Only Name")])
        check("unterminated quote runs to the next comma",
              "#EXTINF:-1 group-title=\"Broken,Name Here\nhttp://s/u\n",
              [M3UEntry(title: "Name Here", url: "http://s/u", group: "Broken")])
        check("bare URLs without EXTINF, junk ignored",
              "<html>\n<a href=\"https://x\">\nrtmp://live.example/app/stream\nnot a url\n",
              [M3UEntry(title: nil, url: "rtmp://live.example/app/stream")])
        check("non-UTF-8 (Latin-1) titles",
              String(decoding: [UInt8]("#EXTINF:-1,Caf".utf8) + [0xE9] + [UInt8]("\nhttp://s/l\n".utf8), as: UTF8.self),
              [M3UEntry(title: "Caf\u{FFFD}", url: "http://s/l")])

        // Latin-1 must be checked on raw bytes (the String above was already repaired by Swift).
        let latin1 = M3UParser.parse(Data([UInt8]("#EXTINF:-1,Caf".utf8) + [0xE9] + [UInt8]("\nhttp://s/l\n".utf8)))
        if latin1.first?.title == "Caf\u{E9}" {
            print("ok   raw Latin-1 bytes decoded as Latin-1")
        } else {
            failures += 1
            print("FAIL raw Latin-1 bytes: \(latin1)")
        }

        print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
        if failures > 0 {
            exit(1)
        }
    }
}
