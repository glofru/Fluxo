//
//  DebugLibraryRoutes.swift
//  Fluxo
//
//  Debug harness: routes for the library store and its neighbours (`library-log`, `downloads-fake-failures`,
//  `recording-limit:`). See Tools/Simulator/README.md.
//

#if DEBUG
import Foundation
import os
import SwiftData

enum DebugLibraryRoutes {

    static let all: [DebugRoute] = [
        DebugRoute("library-log", "Writes the rows of every model and where the stores are (library, cache, versions, backups) to Status/library.log.") { context, _ in
            let modelContext = context.modelContext
            func count<T: PersistentModel>(_ type: T.Type) -> Int {
                (try? modelContext.fetchCount(FetchDescriptor<T>())) ?? -1
            }
            let favorites = (try? modelContext.fetchCount(FetchDescriptor<ChannelBookmark>(predicate: #Predicate { $0.isFavorite }))) ?? -1
            let watched = (try? modelContext.fetchCount(FetchDescriptor<ChannelBookmark>(predicate: #Predicate { $0.lastWatchedAt != nil }))) ?? -1
            var lines = [
                "playlists: \(count(Playlist.self))",
                "channels: \(count(PlaylistChannel.self)) groups: \(count(PlaylistChannelGroup.self)) series: \(count(PlaylistSeries.self))",
                "bookmarks: \(count(ChannelBookmark.self)) favorites: \(favorites) watched: \(watched) series bookmarks: \(count(SeriesBookmark.self))",
                "guide sources: \(count(EPGSource.self)) guide channels: \(count(EPGChannel.self)) programmes: \(count(EPGProgramme.self)) overrides: \(count(EPGChannelOverride.self)) reminders: \(count(ProgrammeReminder.self))",
            ]
            lines.append("recording: \(context.player.isRecording) message: \(context.player.recordingError ?? "-") recordings: \(context.player.recordings.recordings.count)")
            if let location = ModelContainerFactory.location {
                let fileManager = FileManager.default
                for (name, url) in [("library", location.userStoreURL), ("cache", location.cacheStoreURL)] {
                    let version: String
                    switch LibraryStore.inspect(url) {
                    case .success(let found):
                        version = found?.description ?? "none"
                    case .failure(let failure):
                        version = failure.rawValue
                    }
                    lines.append("\(name) store: \(url.path) exists: \(fileManager.fileExists(atPath: url.path)) version: \(version)")
                }
                lines.append("maintenance pending: \(fileManager.fileExists(atPath: location.maintenanceURL.path))")
                lines.append("backups: \(LibraryStore.backups(location).count)")
            } else {
                lines.append("stores: in memory")
            }
            write(lines.joined(separator: "\n"), to: "library.log")
        },
        DebugRoute("downloads-fake-failures", "Adds failed downloads with each kind of reason (unexpected, expired link, offline, unsupported format) for screenshots of the Couldn't Download section.") { context, _ in
            let downloads = try context.downloads()
            let movies = ((try? context.modelContext.fetch(FetchDescriptor<PlaylistChannel>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
                .filter { $0.kind != .live && $0.url != nil }
                .prefix(4)
            let reasons: [(DownloadFailure.Reason, Bool)] = [
                (.unexpected, false),
                (.http(status: 403), false),
                (.network(.offline), false),
                (.unsupportedFormat(engineMessage: nil), true),
            ]
            for (channel, (reason, isPermanent)) in zip(movies, reasons) {
                guard let item = DownloadedItem(ChannelItem(channel)) else {
                    continue
                }
                var record = DownloadRecord(id: UUID(), item: item, status: .failed, method: .file, addedOn: .now)
                record.failureReason = reason
                record.failureIsPermanent = isPermanent
                downloads.debugInsert(record)
            }
        },
        DebugRoute("recording-limit:<seconds>", "Stops recordings after this many seconds (instead of Settings › Recordings › Stop Recording After); 0 restores the setting.") { _, argument in
            guard let seconds = TimeInterval(argument) else {
                throw DebugRouteError.invalidArgument("recording-limit", argument)
            }
            RecordingLimits.debugMaximumDuration = seconds > 0 ? seconds : nil
        },
    ]

    private static func write(_ text: String, to name: String) {
        try? FileManager.default.createDirectory(at: DebugEnvironment.statusDirectory, withIntermediateDirectories: true)
        try? text.write(to: DebugEnvironment.statusDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        DebugLaunchOptions.logger.notice("\(name, privacy: .public):\n\(text, privacy: .public)")
    }
}
#endif
