//
//  DebugGuideSeed.swift
//  Fluxo
//
//  Debug harness: a sample TV guide for the live channels of every playlist of the (isolated) library, so the
//  screens that show now / next (Home "On Now", Favorites, channel rows, schedules) can be checked with the
//  seeded libraries. Route `seed-guide`; compiled out of release builds.
//

#if DEBUG
import SwiftData
import SwiftUI

@MainActor
enum DebugGuideSeed {

    /// Programmes by category keyword; other channels use `fallbackTitles`.
    private static let titlesByKeyword: [(String, [String])] = [
        ("sport", ["Grand Prix Qualifying", "Matchday Live", "Tennis: Quarter-Final", "Football Tonight", "Motor Racing Highlights", "The Sports Desk"]),
        ("news", ["Morning Briefing", "World Report", "Business Today", "The Debate", "Evening News", "Late Edition"]),
        ("kids", ["Cartoon Club", "Science Explorers", "Story Time", "Animal Friends", "Space Rangers"]),
        ("cinema", ["The Silent Harbor", "Crimson Signal", "Night Train to Lisbon", "Paper Hearts", "Iron Bay"]),
        ("musica", ["Top 40 Countdown", "Live in Concert", "Unplugged Sessions", "Classic Hits"]),
        // The groups of the `store` seed (invented titles only, for App Store screenshots).
        ("documentar", ["The Living Ocean", "Mountain Kingdoms", "Planet Under Ice", "Night Skies", "Rivers of Light", "Wild Coasts"]),
        ("movies", ["The Silent Harbor", "Crimson Signal", "Golden Frontier", "The Velvet Station", "Midnight Tide"]),
        ("music", ["Live in Concert", "Jazz After Dark", "Top 40 Countdown", "Unplugged Sessions", "Classic Hits"]),
        ("entertainment", ["Prime Time Show", "Quiz Night", "The Comedy Hour", "Saturday Live", "Late Night Talk"]),
        ("lifestyle", ["Cooking Together", "Travel Diaries", "Home Makeover", "Garden Life", "Weekend Kitchen"]),
    ]
    nonisolated private static let fallbackTitles = ["Prime Time Show", "Documentary: Oceans", "Quiz Night", "Cooking Together", "Travel Diaries", "Late Night Talk"]

    /// The second sentence of a programme's description, by category keyword (the screens that show descriptions, and
    /// the App Store screenshots, read like a real guide).
    private static let descriptionsByKeyword: [(String, String)] = [
        ("sport", "Live coverage, analysis and the best of the action."),
        ("news", "The latest headlines, reports and analysis."),
        ("kids", "Stories and adventures for young viewers."),
        ("cinema", "A feature film."),
        ("documentar", "A journey through the wonders of the natural world."),
        ("movies", "A feature film."),
        ("music", "Music, performances and the artists behind them."),
        ("entertainment", "An evening of laughs, games and guests."),
        ("lifestyle", "Ideas for the kitchen, the home and the road."),
    ]

    /// Adds one guide source per playlist with programmes from 6 hours ago to 2 days ahead for its live
    /// channels (matched by tvg-id, or by name when a channel has none), then reloads the guide.
    static func seed(context: ModelContext, epg: EPGStore, now: Date = .now) throws {
        let playlists = try context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.createdOn)]))
        let live = ChannelContentKind.live.rawValue
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now).addingTimeInterval(-6 * 3_600)
        let end = calendar.startOfDay(for: now).addingTimeInterval(2 * 86_400)
        let durations: [TimeInterval] = [1_800, 2_700, 3_600, 5_400, 1_800, 3_600]

        for playlist in playlists {
            guard let importID = playlist.currentImportID else {
                continue
            }
            let sourceURL = URL(string: "https://guide.seed.fluxo.invalid/\(playlist.uuid.uuidString).xml") ?? URL(fileURLWithPath: "/")
            let source = EPGSource(url: sourceURL, name: "Sample guide", playlistID: playlist.uuid)
            let guideImportID = UUID()
            source.currentImportID = guideImportID
            source.lastRefreshedOn = now
            context.insert(source)
            // The playlist header lists the guide, as a real playlist would (the source sync keeps it).
            playlist.guideURLString = sourceURL.absoluteString
            playlist.guideHeaderCheckedOn = now

            var descriptor = FetchDescriptor<PlaylistChannel>(
                predicate: #Predicate { $0.importID == importID && $0.kindRawValue == live },
                sortBy: [SortDescriptor(\.sortIndex)]
            )
            descriptor.fetchLimit = 400
            let channels = try context.fetch(descriptor)
            var seen: Set<String> = []
            var programmeCount = 0
            for (channelIndex, channel) in channels.enumerated() {
                let name = channel.name ?? "Channel"
                let channelID = channel.tvgID.flatMap { $0.isEmpty ? nil : $0 } ?? GuidePreviewData.slug(name)
                guard seen.insert(channelID.lowercased()).inserted else {
                    continue
                }
                context.insert(EPGChannel(sourceID: source.uuid, importID: guideImportID, channelID: channelID, displayName: name, otherNames: "", icon: channel.logo, hasProgrammes: true))
                let group = channel.groupName.lowercased()
                let pool = titlesByKeyword.first { group.contains($0.0) }?.1 ?? fallbackTitles
                let about = descriptionsByKeyword.first { group.contains($0.0) }?.1 ?? "Tonight on \(name)."
                var time = start.addingTimeInterval(TimeInterval(channelIndex % 4) * -600)
                var slot = channelIndex
                while time < end {
                    let duration = durations[slot % durations.count]
                    let title = pool[slot % pool.count]
                    context.insert(EPGProgramme(
                        sourceID: source.uuid,
                        importID: guideImportID,
                        channelID: channelID,
                        start: time,
                        stop: time.addingTimeInterval(duration),
                        title: title,
                        subtitle: slot % 3 == 0 ? "Part \(1 + slot % 3)" : "",
                        summary: "\(title) on \(name). \(about)",
                        categories: channel.groupName,
                        icon: nil,
                        episode: slot % 4 == 0 ? "S\(1 + slot % 5) E\(1 + slot % 12)" : nil
                    ))
                    programmeCount += 1
                    time = time.addingTimeInterval(duration)
                    slot += 1
                }
            }
            source.channelCount = seen.count
            source.storedChannelCount = seen.count
            source.programmeCount = programmeCount
        }
        try context.save()
        epg.reloadGuide()
    }

    /// Name of the guide `addUserSource` adds.
    nonisolated static let userSourceName = "Debug Guide"

    /// Adds a guide "added by the user" (no playlist; the one kind Settings can delete) with half-hour programmes
    /// for every live channel of every playlist over `days` days, written in batches on a background context like
    /// a real import (about 100,000 programmes for the sample library over 7 days). Returns the source and the
    /// number of programmes.
    static func addUserSource(container: ModelContainer, days: Int, epg: EPGStore, now: Date = .now) async throws -> (sourceID: UUID, programmes: Int) {
        let result = try await Task.detached(priority: .userInitiated) {
            try writeUserSource(container: container, days: days, now: now)
        }.value
        epg.reloadGuide()
        return result
    }

    nonisolated private static func writeUserSource(container: ModelContainer, days: Int, now: Date) throws -> (sourceID: UUID, programmes: Int) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let live = ChannelContentKind.live.rawValue
        let importIDs = try context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.createdOn)])).compactMap(\.currentImportID)
        let sourceURL = URL(string: "https://guide.seed.fluxo.invalid/user-\(UUID().uuidString).xml.gz") ?? URL(fileURLWithPath: "/")
        let source = EPGSource(url: sourceURL, name: userSourceName, playlistID: nil)
        let sourceID = source.uuid
        let guideImportID = UUID()
        context.insert(source)
        try context.save()

        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(-6 * 3_600)
        let end = start.addingTimeInterval(TimeInterval(max(days, 1)) * 86_400)
        var seen: Set<String> = []
        var programmeCount = 0
        var pending = 0
        for importID in importIDs {
            let descriptor = FetchDescriptor<PlaylistChannel>(
                predicate: #Predicate { $0.importID == importID && $0.kindRawValue == live },
                sortBy: [SortDescriptor(\.sortIndex)]
            )
            for channel in try context.fetch(descriptor) {
                let name = channel.name ?? "Channel"
                let channelID = channel.tvgID.flatMap { $0.isEmpty ? nil : $0 } ?? ChannelNameNormalizer.key(name) + ".sample"
                guard seen.insert(channelID.lowercased()).inserted else {
                    continue
                }
                context.insert(EPGChannel(sourceID: sourceID, importID: guideImportID, channelID: channelID, displayName: name, otherNames: "", icon: nil, hasProgrammes: true))
                var time = start
                var slot = seen.count
                while time < end {
                    let title = fallbackTitles[slot % fallbackTitles.count]
                    context.insert(EPGProgramme(
                        sourceID: sourceID,
                        importID: guideImportID,
                        channelID: channelID,
                        start: time,
                        stop: time.addingTimeInterval(1_800),
                        title: title,
                        subtitle: "",
                        summary: "\(title) on \(name). A programme of the debug guide.",
                        categories: channel.groupName,
                        icon: nil,
                        episode: nil
                    ))
                    programmeCount += 1
                    pending += 1
                    time = time.addingTimeInterval(1_800)
                    slot += 1
                    if pending >= 5_000 {
                        try context.save()
                        pending = 0
                    }
                }
            }
        }
        source.currentImportID = guideImportID
        source.lastRefreshedOn = now
        source.lastAttemptOn = now
        source.channelCount = seen.count
        source.storedChannelCount = seen.count
        source.programmeCount = programmeCount
        try context.save()
        return (sourceID, programmeCount)
    }
}
#endif
