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
    ]
    private static let fallbackTitles = ["Prime Time Show", "Documentary: Oceans", "Quiz Night", "Cooking Together", "Travel Diaries", "Late Night Talk"]

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
                        summary: "\(title) on \(name). A sample programme of the debug guide.",
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
}
#endif
