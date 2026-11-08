//
//  DebugDownloadRoutes.swift
//  Fluxo
//
//  Debug harness: routes for the offline downloads (`download:`, `download-wait`, `offline:` …). They use the
//  isolated downloads folder of the debug run (`DebugEnvironment.downloadsDirectory`) and background sessions of
//  their own, so they never touch the real downloads. See Tools/Simulator/README.md.
//

#if DEBUG
import Foundation
import os
import SwiftData
import SwiftUI

enum DebugDownloadRoutes {

    static let all: [DebugRoute] = [
        DebugRoute("download:<channel>", "Downloads a movie or episode, like Download in its menu.") { context, argument in
            let downloads = try context.downloads()
            downloads.download(try context.channel(named: argument))
        },
        DebugRoute("download-season:<series>[,<season>]", "Downloads the episodes of a season of a series (the first season by default).") { context, argument in
            let downloads = try context.downloads()
            let parts = argument.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let series = try context.series(named: parts.first ?? argument)
            guard let episodes = SeriesLookup.episodes(of: series, in: context.modelContext.container) else {
                throw DebugRouteError.notFound("episodes of series", argument)
            }
            let season = parts.count > 1 ? Int(parts[1]) : episodes.seasons.first
            downloads.download(season.map(episodes.episodes(inSeason:)) ?? episodes.episodes)
        },
        DebugRoute("download-wait[:<seconds>]", "Waits until no download is queued, downloading or converting (90 s at most by default).") { context, argument in
            let downloads = try context.downloads()
            let seconds = Double(argument) ?? 90
            await context.wait(timeout: seconds) {
                !downloads.records.contains { $0.status.isActive }
            }
            log(downloads)
        },
        DebugRoute("download-progress:<fraction>", "Waits until every running download has reached a fraction (0…1) of its size (60 s at most).") { context, argument in
            let downloads = try context.downloads()
            let target = Double(argument) ?? 0.3
            await context.wait(timeout: 60) {
                let running = downloads.records.filter { $0.status == .downloading }
                return !running.isEmpty && running.allSatisfy { downloads.progress(for: $0).fraction >= target }
            }
        },
        DebugRoute("pause-download:<channel>", "Pauses the download of a movie or episode.") { context, argument in
            let downloads = try context.downloads()
            guard let record = downloads.record(for: try context.channel(named: argument)) else {
                throw DebugRouteError.notFound("download", argument)
            }
            downloads.pause(record.id)
        },
        DebugRoute("resume-download:<channel>", "Resumes (or retries) the download of a movie or episode.") { context, argument in
            let downloads = try context.downloads()
            guard let record = downloads.record(for: try context.channel(named: argument)) else {
                throw DebugRouteError.notFound("download", argument)
            }
            downloads.retry(record.id)
        },
        DebugRoute("delete-download:<channel>", "Deletes the download of a movie or episode.") { context, argument in
            let downloads = try context.downloads()
            guard let record = downloads.record(for: try context.channel(named: argument)) else {
                throw DebugRouteError.notFound("download", argument)
            }
            downloads.delete(record.id)
        },
        DebugRoute("delete-downloads", "Deletes every download.") { context, _ in
            try context.downloads().deleteAll()
        },
        DebugRoute("downloads", "The downloads (the Library tab on iOS, the Downloads item of the Mac sidebar).") { context, _ in
            context.navigation.show(.downloads)
        },
        DebugRoute("downloads-all", "Every download on a screen of its own (See All of the Library on iOS).") { context, _ in
            context.navigation.show(.downloads)
            #if os(iOS)
            context.navigation.libraryPath.append(ChannelRoute.downloads)
            #endif
        },
        DebugRoute("downloaded-series:<title>", "The downloaded episodes of a series (pushed on the Library tab, iOS).") { context, argument in
            let downloads = try context.downloads()
            guard let record = downloads.records.first(where: { $0.item.seriesTitle?.localizedStandardContains(argument) == true }),
                  let key = record.item.seriesKey else {
                throw DebugRouteError.notFound("downloaded series", argument)
            }
            context.navigation.show(.downloads)
            #if os(iOS)
            context.navigation.libraryPath.append(ChannelRoute.downloadedSeries(playlistID: record.item.playlistID, key: key, title: record.title))
            #endif
        },
        DebugRoute("play-download:<channel>", "Plays a downloaded movie or episode (from its file) full screen, and logs where it plays from.") { context, argument in
            let downloads = try context.downloads()
            let item = try context.channel(named: argument)
            guard let local = downloads.localPlaybackURL(for: item) else {
                throw DebugRouteError.notFound("completed download", argument)
            }
            await context.play(item, present: true)
            await context.wait(timeout: 10) { context.player.playbackState == .playing }
            DebugLaunchOptions.logger.notice("play-download: \(item.displayName, privacy: .public) from \(local.lastPathComponent, privacy: .public), playing download: \(context.player.isPlayingDownload), state: \(context.player.playbackState.label, privacy: .public)")
            appendStatus("play-download \(item.displayName): local=\(local.path) isPlayingDownload=\(context.player.isPlayingDownload) state=\(context.player.playbackState.label)")
        },
        DebugRoute("offline:<on|off|system>", "Pretends the device is offline (on), online (off), or follows the system.") { _, argument in
            switch argument.lowercased() {
            case "on", "yes", "true":
                NetworkMonitor.shared.debugOverride = true
            case "off", "no", "false":
                NetworkMonitor.shared.debugOverride = false
            case "system", "":
                NetworkMonitor.shared.debugOverride = nil
            default:
                throw DebugRouteError.invalidArgument("offline", argument)
            }
        },
        DebugRoute("settings-section:<icloud|playback|tracks|guide|recommendations|intelligence|siri|siri-whats-on|downloads|video-quality|recordings|about>", "Settings, scrolled to a section (siri-whats-on: to the Siri phrases after the first, whose example names a real channel): the Settings tab on iOS, the Settings window on macOS.") { context, argument in
            if let openSettings = context.openSettings {
                openSettings()
            } else {
                context.navigation.tab = .settings
            }
            try await Task.sleep(for: .milliseconds(600))
            NotificationCenter.default.post(name: .fluxoDebugSettingsSection, object: argument.lowercased())
        },
        DebugRoute("downloads-log", "Writes every download (state, method, sizes, file) to Status/downloads.log.") { context, _ in
            log(try context.downloads())
        },
    ]

    @MainActor
    private static func log(_ downloads: DownloadCenter) {
        let lines = downloads.records.map { record in
            let file = downloads.localPlaybackURL(for: record.item.channelItem(logo: nil))?.lastPathComponent ?? "-"
            return "\(record.title) | \(record.episodeLine ?? "-") | \(record.status.rawValue) | \(record.method?.rawValue ?? "-") | \(record.bytesOnDisk) / \(record.bytesExpected ?? -1) bytes | \(record.qualityHeight.map { "\($0)p" } ?? "-") | audio: \((record.audioLanguages ?? []).joined(separator: ", ")) | subtitles: \((record.subtitleLanguages ?? []).joined(separator: ", ")) | file: \(file) | failure: \(record.failureReason.map { "\($0)" } ?? "-")"
        }
        appendStatus((["downloads (\(lines.count)):"] + lines).joined(separator: "\n"))
        DebugLaunchOptions.logger.notice("\(lines.joined(separator: "\n"), privacy: .public)")
    }

    private static func appendStatus(_ text: String) {
        let url = DebugEnvironment.statusDirectory.appendingPathComponent("downloads.log")
        try? FileManager.default.createDirectory(at: DebugEnvironment.statusDirectory, withIntermediateDirectories: true)
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

extension DebugRouteContext {
    func downloads() throws -> DownloadCenter {
        guard let downloads = player.downloads else {
            throw DebugRouteError.notFound("download center", "player.downloads")
        }
        return downloads
    }
}
#endif
