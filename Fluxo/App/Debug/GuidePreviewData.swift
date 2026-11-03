//
//  GuidePreviewData.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// A sample TV guide for the live channels of `PreviewSampleData`: two days of programmes around now, for
/// SwiftUI previews and the debug demo (`-FluxoDebugGuideDemo YES`).
@MainActor
enum GuidePreviewData {

    static let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000E0001") ?? UUID()
    static let importID = UUID(uuidString: "00000000-0000-0000-0000-0000000E1E1E") ?? UUID()

    static let container: ModelContainer = {
        let container = PreviewSampleData.makeContainer(withSamples: true)
        seedGuide(into: container.mainContext, now: .now)
        return container
    }()

    /// The sample live channels with their guide channel.
    static var channels: [GuideChannel] {
        let importID = PreviewSampleData.freeviewImportID
        let live = ChannelContentKind.live.rawValue
        let descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.kindRawValue == live },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        let rows = (try? container.mainContext.fetch(descriptor)) ?? []
        return rows.map { channel in
            GuideChannel(item: ChannelItem(channel), ref: GuideChannelRef(sourceID: sourceID, importID: Self.importID, channelID: slug(channel.name ?? "")))
        }
    }

    private static let titles: [String: [String]] = [
        "News": ["Morning Briefing", "World Report", "Business Today", "The Debate", "Evening News", "Late Edition", "Weather Watch", "Newsnight"],
        "Sports": ["Matchday Live", "Grand Prix Qualifying", "Tennis: Quarter-Final", "Football Tonight", "Motor Racing Highlights", "The Sports Desk"],
        "Kids": ["Cartoon Club", "Science Explorers", "Story Time", "Animal Friends", "Space Rangers"],
    ]

    /// Adds a guide source for the sample "Freeview" playlist with programmes from 6 hours ago to 2 days ahead.
    static func seedGuide(into context: ModelContext, now: Date) {
        let source = EPGSource(uuid: sourceID, url: URL(string: "https://example.com/guide.xml.gz") ?? URL(fileURLWithPath: "/"), name: "example.com", playlistID: PreviewSampleData.freeviewID)
        source.currentImportID = importID
        source.lastRefreshedOn = now
        context.insert(source)
        // The playlist header lists the guide, as a real playlist would (`EPGImporter.syncSources` keeps it).
        for playlist in (try? context.fetch(FetchDescriptor<Playlist>())) ?? [] {
            playlist.guideHeaderCheckedOn = now
            if playlist.uuid == PreviewSampleData.freeviewID {
                playlist.guideURLString = source.url.absoluteString
            }
        }

        let importID = PreviewSampleData.freeviewImportID
        let live = ChannelContentKind.live.rawValue
        // In playlist order, so every run gives each channel the same schedule (comparable screenshots).
        let channels = (try? context.fetch(FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.kindRawValue == live },
            sortBy: [SortDescriptor(\.sortIndex)]
        ))) ?? []
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now).addingTimeInterval(-6 * 3_600)
        let end = calendar.startOfDay(for: now).addingTimeInterval(2 * 86_400)
        var programmeCount = 0
        for (channelIndex, channel) in channels.enumerated() {
            let name = channel.name ?? "Channel"
            let channelID = slug(name)
            context.insert(EPGChannel(sourceID: sourceID, importID: Self.importID, channelID: channelID, displayName: name, otherNames: "", icon: channel.logo, hasProgrammes: true))
            let pool = titles[channel.groupName] ?? titles["News"] ?? []
            let durations: [TimeInterval] = [1_800, 2_700, 3_600, 5_400, 1_800, 3_600]
            var time = start.addingTimeInterval(TimeInterval(channelIndex % 3) * -900)
            var slot = channelIndex
            while time < end {
                let duration = durations[slot % durations.count]
                let title = pool[slot % pool.count]
                let episode = slot % 4 == 0 ? "S\(1 + slot % 5) E\(1 + slot % 12)" : nil
                context.insert(EPGProgramme(
                    sourceID: sourceID,
                    importID: Self.importID,
                    channelID: channelID,
                    start: time,
                    stop: time.addingTimeInterval(duration),
                    title: title,
                    subtitle: slot % 3 == 0 ? "Part \(1 + slot % 3)" : "",
                    summary: "\(title) on \(name). A sample programme of the preview guide, with a short description of what to expect.",
                    categories: channel.groupName,
                    icon: nil,
                    episode: episode
                ))
                programmeCount += 1
                time = time.addingTimeInterval(duration)
                slot += 1
            }
        }
        source.channelCount = channels.count
        source.storedChannelCount = channels.count
        source.programmeCount = programmeCount
        try? context.save()
    }

    static func slug(_ name: String) -> String {
        ChannelNameNormalizer.key(name) + ".sample"
    }
}
