//
//  Fixture.swift
//  Fluxo
//
//  Shared by both binaries of Tools/LibraryCheck: compiled with the sources of the previous version (`old`, which
//  writes the library) and with the current ones (`check`, which opens it). Builds a library the way the app does
//  (the playlist and the guide through their importers) plus every kind of user row, and dumps every attribute of
//  every user row, so "nothing of the user's was lost" is a comparison of two dumps.
//

import Foundation
import SwiftData

enum Fixture {

    static let playlistName = "Check Library"
    static let userGuideURL = URL(string: "https://example.com/user-guide.xml.gz") ?? URL(fileURLWithPath: "/")

    // MARK: - Content

    /// An M3U with `live` channels (with tvg-id), 300 movies and 4 series of 2 seasons x 10 episodes.
    static func playlist(live: Int) -> String {
        var lines = ["#EXTM3U url-tvg=\"https://example.com/guide.xml.gz\""]
        for index in 0..<live {
            lines.append("#EXTINF:-1 tvg-id=\"ch\(index).check\" tvg-logo=\"https://example.com/logo/\(index).png\" group-title=\"Live \(index % 12)\",Channel \(index) HD")
            lines.append("http://example.com/live/user/pass/\(index)")
        }
        for index in 0..<300 {
            lines.append("#EXTINF:-1 tvg-logo=\"https://example.com/poster/\(index).jpg\" group-title=\"Movies \(index % 5)\",Movie Number \(index) (20\(10 + index % 15))")
            lines.append("http://example.com/movie/user/pass/\(index).mp4")
        }
        for series in 0..<4 {
            for season in 1...2 {
                for episode in 1...10 {
                    lines.append("#EXTINF:-1 group-title=\"Series \(series)\",Show \(series) S0\(season)E\(String(format: "%02d", episode))")
                    lines.append("http://example.com/series/user/pass/\(series)\(season)\(episode).mkv")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// An XMLTV guide for `channels` channels (the first ones of the playlist), half-hour programmes from 6 hours ago
    /// for `days` days.
    static func guide(channels: Int, days: Int, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 1_800).rounded(.down) * 1_800 - 6 * 3_600)
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n"
        for index in 0..<channels {
            text += "<channel id=\"ch\(index).check\"><display-name>Channel \(index)</display-name></channel>\n"
        }
        let slots = days * 48 + 12
        for index in 0..<channels {
            for slot in 0..<slots {
                let begin = start.addingTimeInterval(Double(slot) * 1_800)
                text += "<programme start=\"\(formatter.string(from: begin)) +0000\" stop=\"\(formatter.string(from: begin.addingTimeInterval(1_800))) +0000\" channel=\"ch\(index).check\"><title>Show \(slot) on \(index)</title><desc>Programme \(slot) of channel \(index).</desc><category>News</category></programme>\n"
            }
        }
        return text + "</tv>\n"
    }

    // MARK: - Building the library

    /// Imports the playlist and the guide (also a guide the user added), then adds favorites, history with resume
    /// positions, a watched series, a guide match chosen by hand and a reminder. Returns the playlist's id.
    @discardableResult
    static func build(in container: ModelContainer, directory: URL, live: Int, guideChannels: Int, guideDays: Int, now: Date = .now) async throws -> UUID {
        let playlistURL = directory.appendingPathComponent("playlist.m3u")
        try playlist(live: live).write(to: playlistURL, atomically: true, encoding: .utf8)
        let importer = PlaylistImporter(container: container)
        let playlistID = UUID()
        try await importer.createPlaylist(uuid: playlistID, name: playlistName, url: playlistURL)
        _ = try await importer.importContent(ofPlaylist: playlistID, from: playlistURL) { _ in }

        let guideURL = directory.appendingPathComponent("guide.xml")
        try guide(channels: min(live, guideChannels), days: guideDays, now: now).write(to: guideURL, atomically: true, encoding: .utf8)
        let epg = EPGImporter(container: container)
        let context = ModelContext(container)
        var wanted = EPGWantedChannels()
        let liveKind = ChannelContentKind.live.rawValue
        for channel in try context.fetch(FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.kindRawValue == liveKind })) {
            wanted.add(tvgID: channel.tvgID, name: channel.name)
        }
        let playlistGuideID = try await epg.addSource(url: URL(string: "https://example.com/guide.xml.gz") ?? guideURL, name: "Playlist Guide")
        _ = try await epg.importFile(guideURL, sourceID: playlistGuideID, wanted: wanted) { _ in }
        let userGuideID = try await epg.addSource(url: userGuideURL, name: "My Guide", isEnabled: false)

        // The user's own rows.
        let channels = try context.fetch(FetchDescriptor<PlaylistChannel>(sortBy: [SortDescriptor(\.sortIndex)]))
        for (index, channel) in channels.enumerated() where index % 37 == 0 {
            guard let url = channel.url else {
                continue
            }
            let bookmark = ChannelBookmark(key: ChannelBookmark.key(playlistID: playlistID, url: url), playlistID: playlistID, url: url, channelID: channel.uuid, name: channel.name, logo: channel.logo, groupName: channel.groupName, kind: channel.kind)
            bookmark.tvgID = channel.tvgID
            if index % 2 == 0 {
                bookmark.isFavorite = true
                bookmark.favoritedOn = now.addingTimeInterval(-Double(index))
                bookmark.favoriteOrder = Double(index)
            }
            bookmark.lastWatchedAt = now.addingTimeInterval(-Double(index * 60))
            bookmark.watchCount = index % 7 + 1
            if channel.kind != .live {
                bookmark.resumePosition = Double(120 + index)
                bookmark.knownDuration = 5_400.5
            }
            if let episode = channel.episodeRef {
                bookmark.setEpisode(episode)
            }
            context.insert(bookmark)
        }
        let seriesBookmark = SeriesBookmark(key: SeriesBookmark.key(playlistID: playlistID, seriesKey: "show 0"), playlistID: playlistID, seriesKey: "show 0", title: "Show 0", artwork: "https://example.com/show0.jpg", groupName: "Series 0")
        seriesBookmark.isFavorite = true
        seriesBookmark.favoritedOn = now
        seriesBookmark.favoriteOrder = -3.5
        seriesBookmark.lastWatchedAt = now
        seriesBookmark.lastEpisodeURL = URL(string: "http://example.com/series/user/pass/013.mkv")
        seriesBookmark.lastSeason = 1
        seriesBookmark.lastEpisode = 3
        seriesBookmark.watchedEpisodeCodes = ["1:1", "1:2"]
        context.insert(seriesBookmark)

        if let channel = channels.first, let url = channel.url {
            context.insert(EPGChannelOverride(key: ChannelBookmark.key(playlistID: playlistID, url: url), playlistID: playlistID, sourceID: playlistGuideID, channelID: "ch5.check"))
            let item = ChannelItem(channel)
            let programme = GuideProgramme(sourceID: playlistGuideID, channelID: "ch0.check", start: now.addingTimeInterval(3_600), stop: now.addingTimeInterval(5_400), title: "Evening News", subtitle: "Live")
            context.insert(ProgrammeReminder(key: programme.reminderKey, programme: programme, channel: item, channelURL: url, fireDate: now.addingTimeInterval(3_300)))
        }
        if let source = try context.fetch(FetchDescriptor<EPGSource>(predicate: #Predicate { $0.uuid == userGuideID })).first {
            source.lastError = "network"
            source.entityTag = "\"etag\""
        }
        try context.save()
        return playlistID
    }

    // MARK: - Dumps

    /// Every attribute of every user row, by model, rows sorted: equal dumps mean nothing of the user's changed.
    static func dumpUserRows(_ container: ModelContainer) throws -> [String: [String]] {
        let context = ModelContext(container)
        func text(_ values: [Any?]) -> String {
            values.map { value -> String in
                guard let value else {
                    return "nil"
                }
                if let date = value as? Date {
                    return "\(date.timeIntervalSinceReferenceDate)"
                }
                return "\(value)"
            }
            .joined(separator: " | ")
        }
        var dump: [String: [String]] = [:]
        dump["Playlist"] = try context.fetch(FetchDescriptor<Playlist>()).map {
            text([$0.uuid, $0.name, $0.url, $0.createdOn, $0.currentImportID, $0.lastRefreshedOn, $0.channelCount, $0.groupCount, $0.guideURLString, $0.guideHeaderCheckedOn, $0.seriesIndexVersion])
        }.sorted()
        dump["ChannelBookmark"] = try context.fetch(FetchDescriptor<ChannelBookmark>()).map {
            text([$0.key, $0.playlistID, $0.url, $0.channelID, $0.name, $0.logo, $0.groupName, $0.kindRawValue, $0.tvgID, $0.isFavorite, $0.favoritedOn, $0.favoriteOrder, $0.lastWatchedAt, $0.watchCount, $0.resumePosition, $0.knownDuration, $0.seriesKey, $0.seriesTitle, $0.seasonNumber, $0.episodeNumber, $0.episodeTitle])
        }.sorted()
        dump["SeriesBookmark"] = try context.fetch(FetchDescriptor<SeriesBookmark>()).map {
            text([$0.key, $0.playlistID, $0.seriesKey, $0.title, $0.artwork, $0.groupName, $0.isFavorite, $0.favoritedOn, $0.favoriteOrder, $0.lastWatchedAt, $0.lastEpisodeURL, $0.lastSeason, $0.lastEpisode, $0.watchedEpisodeCodes.joined(separator: ",")])
        }.sorted()
        dump["EPGSource"] = try context.fetch(FetchDescriptor<EPGSource>()).map {
            text([$0.uuid, $0.url, $0.name, $0.playlistID, $0.isEnabled, $0.addedOn, $0.currentImportID, $0.lastRefreshedOn, $0.lastAttemptOn, $0.lastError, $0.channelCount, $0.contentHash, $0.entityTag, $0.lastModifiedHeader, $0.storedChannelCount, $0.programmeCount])
        }.sorted()
        dump["EPGChannelOverride"] = try context.fetch(FetchDescriptor<EPGChannelOverride>()).map {
            text([$0.key, $0.playlistID, $0.sourceID, $0.channelID, $0.updatedOn])
        }.sorted()
        dump["ProgrammeReminder"] = try context.fetch(FetchDescriptor<ProgrammeReminder>()).map {
            text([$0.key, $0.title, $0.subtitle, $0.start, $0.stop, $0.fireDate, $0.playlistID, $0.channelURL, $0.channelUUID, $0.channelName, $0.channelLogo, $0.groupName, $0.tvgID])
        }.sorted()
        return dump
    }

    /// How many rows each cache model has.
    static func cacheCounts(_ container: ModelContainer) throws -> [String: Int] {
        let context = ModelContext(container)
        return [
            "PlaylistChannel": try context.fetchCount(FetchDescriptor<PlaylistChannel>()),
            "PlaylistChannelGroup": try context.fetchCount(FetchDescriptor<PlaylistChannelGroup>()),
            "PlaylistSeries": try context.fetchCount(FetchDescriptor<PlaylistSeries>()),
            "EPGChannel": try context.fetchCount(FetchDescriptor<EPGChannel>()),
            "EPGProgramme": try context.fetchCount(FetchDescriptor<EPGProgramme>()),
        ]
    }

    static func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url)
    }
}
