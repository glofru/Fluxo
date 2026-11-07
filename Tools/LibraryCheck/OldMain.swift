//
//  OldMain.swift
//  Fluxo
//
//  Compiled with the sources of the previous version (Tools/LibraryCheck/run.sh, OLD_REV): writes a library the way
//  that version did (one store, the schema without a version, `ModelContainerFactory` of then), and the dump of its
//  user rows and the counts of its cache rows for `check` to compare with.
//
//  Usage: old <folder> <live channels> <guide channels> <guide days>
//

import Foundation
import SwiftData

@main
struct OldLibrary {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let live = Int(CommandLine.arguments[2]) ?? 500
        let guideChannels = Int(CommandLine.arguments[3]) ?? 400
        let days = Int(CommandLine.arguments[4]) ?? 2
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = Date()
        do {
            let schema = Schema(ModelRegistry.all)
            let configuration = ModelConfiguration(schema: schema, url: folder.appendingPathComponent("default.store"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: configuration)
            try await Fixture.build(in: container, directory: folder, live: live, guideChannels: guideChannels, guideDays: days)
            try Fixture.write(try Fixture.dumpUserRows(container), to: folder.appendingPathComponent("user-rows.json"))
            try Fixture.write(try Fixture.cacheCounts(container), to: folder.appendingPathComponent("cache-counts.json"))
            print("old: library written in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, cache \(try Fixture.cacheCounts(container))")
        }
    }
}
