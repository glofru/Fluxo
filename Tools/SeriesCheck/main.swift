//
//  main.swift
//  Fluxo
//
//  Series checks (Tools/SeriesCheck/run.sh), compiled together with the app sources:
//  - parser: every name of `parserCases`, the series keys and classification, then the parse time of 100k names;
//  - store: the import of a synthetic playlist with series into an on-disk store, the queries of Home, Search and
//    the series page, a refresh and a delete (`StoreCheck.run`);
//  - backfill: a store written by the version before series grouping, opened and indexed by this one.
//
//  Usage: check parser | check generate <playlist.m3u> <entries> | check store <store.sqlite> <playlist.m3u> <entries>
//         | check backfill <store.sqlite> <playlist.m3u> <entries>
//

import Foundation
import SwiftData

@main
struct SeriesCheck {
    static func main() async throws {
        let arguments = CommandLine.arguments
        switch arguments.dropFirst().first {
        case "parser":
            ParserChecks.runParserCases()
            ParserChecks.benchmarkParser()
        case "generate" where arguments.count == 4:
            let counts = try SyntheticPlaylist.write(to: URL(fileURLWithPath: arguments[2]), layout: .init(entries: Int(arguments[3]) ?? 100_000))
            print("playlist: \(arguments[3]) entries, \(counts.episodes) episodes of \(counts.series) series")
        case "store" where arguments.count == 5:
            let playlist = URL(fileURLWithPath: arguments[3])
            StoreCheck.expectedCounts = try SyntheticPlaylist.write(to: playlist, layout: .init(entries: Int(arguments[4]) ?? 100_000))
            try await StoreCheck.run(storeURL: URL(fileURLWithPath: arguments[2]), playlist: playlist)
        case "backfill" where arguments.count == 5:
            StoreCheck.expectedCounts = try SyntheticPlaylist.write(to: URL(fileURLWithPath: arguments[3]), layout: .init(entries: Int(arguments[4]) ?? 100_000))
            try await StoreCheck.backfill(storeURL: URL(fileURLWithPath: arguments[2]))
        default:
            print("usage: check parser | check generate <playlist.m3u> <entries> | check store <store.sqlite> <playlist.m3u> <entries> | check backfill <store.sqlite> <playlist.m3u> <entries>")
            exit(2)
        }
    }
}
