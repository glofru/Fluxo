//
//  OldMain.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//
//  Benchmark driver for the previous playlist pipeline (PlaylistValidator + PlaylistViewModel), compiled by run.sh
//  together with the old sources extracted from git. Usage: bench-old parse|import <playlist.m3u>
//

import Foundation
import SwiftData

@main
struct OldBenchmark {
    @MainActor
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            print("usage: bench-old parse|import <playlist.m3u>")
            exit(2)
        }
        let path = arguments[2]
        switch arguments[1] {
        case "parse":
            try await parse(path)
        case "import":
            try await importPlaylist(path)
        default:
            exit(2)
        }
    }

    /// The old validator on the whole file, exactly as the app ran it (it creates unattached model objects).
    @MainActor
    static func parse(_ path: String) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let validator = PlaylistValidator()
        var timings: [Double] = []
        var count = 0
        for _ in 0..<3 {
            let playlist = Playlist(uuid: UUID(), name: "Bench", url: URL(fileURLWithPath: path), createdOn: .now)
            var channels: [PlaylistChannel] = []
            var groups: [PlaylistChannelGroup] = []
            let clock = ContinuousClock()
            let start = clock.now
            for try await _ in validator.validate(playlist: playlist, content: data, playlistChannels: &channels, playlistChannelGroups: &groups) {}
            timings.append(Bench.milliseconds(clock.now - start))
            count = channels.count
        }
        print(String(format: "old parse (with model objects): entries=%d median=%.1f ms min=%.1f ms peakRSS=%.0f MB", count, Bench.median(timings), timings.min() ?? 0, Bench.peakRSSMegabytes()))

        // The same string logic producing plain values, to separate parsing from model allocation.
        var stringTimings: [Double] = []
        for _ in 0..<3 {
            var parsed = 0
            stringTimings.append(Bench.time { parsed = OldStringParser.parse(data) })
            count = parsed
        }
        print(String(format: "old parse (strings only):       entries=%d median=%.1f ms min=%.1f ms", count, Bench.median(stringTimings), stringTimings.min() ?? 0))
    }

    /// Full old pipeline: DownloadManager (whole file) -> validator -> inserts on the main context.
    @MainActor
    static func importPlaylist(_ path: String) async throws {
        let storeURL = Bench.temporaryStoreURL("old")
        defer { Bench.removeStore(storeURL) }
        let schema = Schema([Playlist.self, PlaylistChannel.self, PlaylistChannelGroup.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
        let viewModel = PlaylistViewModel()

        let monitor = MainThreadStallMonitor()
        monitor.start()
        let clock = ContinuousClock()
        let start = clock.now
        let result = await viewModel.addPlaylist(.init(name: "Bench", url: URL(fileURLWithPath: path)), context: container.mainContext)
        let importMilliseconds = Bench.milliseconds(clock.now - start)
        monitor.stop()
        if case .failure(let error) = result {
            print("old import failed: \(error.localizedDescription)")
        }

        let context = ModelContext(container)
        print(String(format: "old import: channels=%d groups=%d time=%.0f ms maxMainStall=%.1f ms peakRSS=%.0f MB",
                     try context.fetchCount(FetchDescriptor<PlaylistChannel>()), try context.fetchCount(FetchDescriptor<PlaylistChannelGroup>()),
                     importMilliseconds, monitor.maxStallMilliseconds, Bench.peakRSSMegabytes()))
    }
}

/// Copy of the old PlaylistValidator string handling that returns plain values.
enum OldStringParser {
    struct Entry {
        let name: String?
        let logo: String
        let duration: Int?
        let group: String
        let url: URL?
    }

    static func parse(_ data: Data) -> Int {
        guard let content = String(data: data, encoding: .utf8) else {
            return 0
        }
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasHeader = lines.first?.uppercased() == "#EXTM3U"
        var currentInfo: String?
        var entries: [Entry] = []
        var groups: [String: [Int]] = [:]
        for i in (hasHeader ? 1 : 0)..<lines.count {
            let line = lines[i]
            if line.hasPrefix("#EXTINF:") {
                currentInfo = line
            } else if line.hasPrefix("#") {
                continue
            } else if currentInfo != nil {
                let lineSplit = currentInfo?.replacingOccurrences(of: "#EXTINF:", with: "").components(separatedBy: ",")
                let infoSplit = lineSplit?.first?.split(separator: " ")
                let duration = Int(infoSplit?.first ?? "-1") ?? -1
                let properties = infoSplit?[1...].reduce(into: [String: String]()) {
                    let propertySplit = $1.split(separator: "=")
                    guard propertySplit.count == 2 else {
                        return
                    }
                    $0[String(propertySplit.first ?? "")] = String(propertySplit.last?.replacingOccurrences(of: "\"", with: "") ?? "")
                }
                let group = properties?.first(where: { $0.key.contains("group-") })?.value ?? ""
                entries.append(Entry(name: lineSplit?.last, logo: properties?.first(where: { $0.key.contains("logo") })?.value ?? "invalid-:+%$#@!~*|",
                                     duration: duration >= 0 ? duration : nil, group: group, url: URL(string: line)))
                groups[group, default: []].append(entries.count - 1)
                currentInfo = nil
            }
        }
        return entries.count
    }
}
