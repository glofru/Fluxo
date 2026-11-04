//
//  GuideValues.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation

/// Points at the programmes of one guide channel: the XMLTV channel id inside the current import of a source.
struct GuideChannelRef: Hashable, Sendable {
    let sourceID: UUID
    let importID: UUID
    let channelID: String
}

/// Value snapshot of a programme for the UI (views never hold `EPGProgramme` models).
struct GuideProgramme: Identifiable, Hashable, Sendable {
    let sourceID: UUID
    let channelID: String
    let start: Date
    let stop: Date
    let title: String
    let subtitle: String
    let summary: String
    let categories: [String]
    let icon: String?
    let episode: String?

    init(
        sourceID: UUID,
        channelID: String,
        start: Date,
        stop: Date,
        title: String,
        subtitle: String = "",
        summary: String = "",
        categories: [String] = [],
        icon: String? = nil,
        episode: String? = nil
    ) {
        self.sourceID = sourceID
        self.channelID = channelID
        self.start = start
        self.stop = stop
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.categories = categories
        self.icon = icon
        self.episode = episode
    }

    init(_ programme: EPGProgramme) {
        self.init(
            sourceID: programme.sourceID,
            channelID: programme.channelID,
            start: programme.start,
            stop: programme.stop,
            title: programme.title.isEmpty ? String(localized: "Untitled", comment: "Title of a TV guide programme that has none.") : programme.title,
            subtitle: programme.subtitle,
            summary: programme.summary,
            categories: programme.categories.isEmpty ? [] : programme.categories.components(separatedBy: "\n"),
            icon: programme.icon,
            episode: programme.episode
        )
    }

    var id: String {
        reminderKey
    }

    /// Stable across guide refreshes (unlike row identifiers): one reminder per show and start time.
    var reminderKey: String {
        "\(sourceID.uuidString)|\(channelID)|\(Int(start.timeIntervalSince1970))"
    }

    var interval: DateInterval {
        DateInterval(start: start, end: max(start, stop))
    }

    func isOnAir(at date: Date) -> Bool {
        start <= date && date < stop
    }

    /// 0...1 elapsed at `date`.
    func progress(at date: Date) -> Double {
        let duration = stop.timeIntervalSince(start)
        guard duration > 0 else {
            return 0
        }
        return min(1, max(0, date.timeIntervalSince(start) / duration))
    }

    /// "Subtitle · S1 E2" (the episode in the app's language), or nil when the guide has neither.
    var detailLine: String? {
        let line = TextParts.line([subtitle, episode.map(GuideFormat.episode)])
        return line.isEmpty ? nil : line
    }
}

/// What a channel shows now and next. `current` is nil between programmes (a gap in the guide).
struct NowNext: Hashable, Sendable {
    let current: GuideProgramme?
    let next: GuideProgramme?

    /// When the information goes stale (the current programme ends, or the next one starts).
    var validUntil: Date? {
        current?.stop ?? next?.start
    }
}

/// A playlist channel that has a guide, as listed by the Guide screen.
struct GuideChannel: Identifiable, Hashable, Sendable {
    let item: ChannelItem
    let ref: GuideChannelRef

    var id: UUID {
        item.id
    }
}

/// A search hit: the programme and the playlist channel that airs it.
struct GuideSearchResult: Identifiable, Hashable, Sendable {
    let programme: GuideProgramme
    let channel: ChannelItem
    let ref: GuideChannelRef

    var id: String {
        "\(programme.id)|\(channel.id.uuidString)"
    }
}

/// A guide channel offered by the manual matching picker.
struct GuideChannelChoice: Identifiable, Hashable, Sendable {
    let ref: GuideChannelRef
    let sourceName: String
    let displayName: String
    let icon: String?
    let hasProgrammes: Bool

    var id: String {
        "\(ref.sourceID.uuidString)|\(ref.channelID)"
    }
}
