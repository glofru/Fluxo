//
//  NowNextViews.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftUI

/// Loads what a live channel shows now and next, and keeps it current: it reloads when the programme ends and
/// when the guide changes (`EPGStore.revision`). Shows nothing (nil) without a guide.
///
/// Reads `EPGStore` as an optional environment value, so the views built on it work anywhere, including
/// previews and screens without a guide.
struct NowNextReader<Content: View>: View {

    let item: ChannelItem?
    @ViewBuilder var content: (NowNext?) -> Content

    @Environment(EPGStore.self) private var epg: EPGStore?
    @State private var value: NowNext?

    var body: some View {
        // The task hangs off a zero-size view that is always there: `content` is empty until something loads,
        // and a task on an empty view never starts.
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: 0, height: 0)
                .task(id: LoadKey(item: item, revision: epg?.revision ?? -1)) {
                    await load()
                }
                .accessibilityHidden(true)
            content(value)
        }
    }

    private struct LoadKey: Equatable {
        let item: ChannelItem?
        let revision: Int
    }

    private func load() async {
        guard let epg, let item, item.kind == .live, epg.hasGuide else {
            value = nil
            return
        }
        while !Task.isCancelled {
            let current = await epg.nowNext(for: item)
            guard !Task.isCancelled else {
                return
            }
            if current != value {
                value = current
            }
            guard let validUntil = current?.validUntil else {
                return
            }
            // Wake up when the programme changes (at most hourly, in case the clock jumps).
            let delay = min(3_600, max(1, validUntil.timeIntervalSinceNow + 0.5))
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}

enum GuideFormat {
    /// "20:00–21:30".
    ///
    /// Two short times rather than a date interval format: the interval styles add the dates when a programme
    /// runs past midnight and, in some languages (Japanese "20時00分～21時30分"), spell the times out, both too
    /// long for the guide's blocks. Translators pick the range separator of their language.
    static func timeRange(_ programme: GuideProgramme) -> String {
        guard programme.start < programme.stop else {
            return time(programme.start)
        }
        // Each time in a first-strong isolate: an Arabic time ends with a letter ("9:30 م"), and without the
        // isolates the bidi algorithm would show the end time first.
        let start = "\u{2068}\(time(programme.start))\u{2069}"
        let stop = "\u{2068}\(time(programme.stop))\u{2069}"
        return String(localized: "\(start)–\(stop)", comment: "Time range of a programme in the TV guide: its start time, then its end time, as in 20:00–21:30. Use the range separator of your language.")
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "1 hr, 30 min".
    static func duration(_ programme: GuideProgramme) -> String {
        Duration.seconds(max(0, programme.stop.timeIntervalSince(programme.start)))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "45 min left".
    static func remaining(_ programme: GuideProgramme, at date: Date) -> String {
        let seconds = max(60, programme.stop.timeIntervalSince(date))
        let value = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return String(localized: "\(value) left", comment: "Time left in the programme on now; the placeholder is a duration such as 45 min.")
    }

    /// "Today", "Tomorrow", "Wednesday 5 November".
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return String(localized: "Today", comment: "Day of a programme in the TV guide.")
        }
        if calendar.isDateInTomorrow(date) {
            return String(localized: "Tomorrow", comment: "Day of a programme in the TV guide.")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday", comment: "Day of a programme in the TV guide.")
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The stored season / episode of a programme in the app's language: "S1 E5", "E5" and "S1" (the form
    /// `XMLTVParser` stores for `xmltv_ns` numbers) are localized; any other text is the guide's own and is
    /// shown as it is.
    static func episode(_ stored: String) -> String {
        let parts = stored.split(separator: " ")
        func number(_ part: Substring, prefix: Character) -> Int? {
            guard part.count > 1, part.first == prefix, part.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
            return Int(part.dropFirst())
        }
        switch parts.count {
        case 2:
            if let season = number(parts[0], prefix: "S"), let episode = number(parts[1], prefix: "E") {
                return String(localized: "S\(season.formatted(.number.grouping(.never))) E\(episode.formatted(.number.grouping(.never)))", comment: "Short season and episode label of a TV programme, as in 'S1 E5'. Keep it very short.")
            }
        case 1:
            if let episode = number(parts[0], prefix: "E") {
                return String(localized: "E\(episode.formatted(.number.grouping(.never)))", comment: "Short episode label of a TV programme, as in 'E5'. Keep it very short.")
            }
            if let season = number(parts[0], prefix: "S") {
                return String(localized: "S\(season.formatted(.number.grouping(.never)))", comment: "Short season label of a TV programme, as in 'S1'. Keep it very short.")
            }
        default:
            break
        }
        return stored
    }

    /// "Today, 20:00 – 21:30".
    static func dayAndTime(_ programme: GuideProgramme) -> String {
        String(localized: "\(day(programme.start)), \(timeRange(programme))", comment: "When a programme airs: the day (Today, Tomorrow or a date), then its time range or its start time.")
    }

    /// "Today, 20:00": the day and the start time of a reminder.
    static func dayAndTime(at date: Date) -> String {
        String(localized: "\(day(date)), \(time(date))", comment: "When a programme airs: the day (Today, Tomorrow or a date), then its time range or its start time.")
    }

    /// "Next 21:00": the start of the next programme, before its title in a line of text.
    static func next(at date: Date) -> String {
        String(localized: "Next \(time(date))", comment: "TV guide, category and channel lists: the start time of the next programme. Its title follows after a separator, as in 'Next 21:00 · Weather'.")
    }

    /// The widest start times of the current locale ("10:58 AM" and "10:58 PM", or "10:58" and "22:58"), to
    /// size a column of times to fit any of them.
    static var widestTimeSamples: [String] {
        let calendar = Calendar.current
        let reference = calendar.startOfDay(for: .now)
        return [10, 22].compactMap { hour in
            calendar.date(bySettingHour: hour, minute: 58, second: 0, of: reference).map(time)
        }
    }
}

/// A start time in a column as wide as the widest time of the locale at the current text size, so the titles
/// next to a list of times line up, and a time never wraps (12-hour clocks, large Dynamic Type).
struct GuideTimeColumnText: View {
    let date: Date

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(GuideFormat.widestTimeSamples, id: \.self) { sample in
                Text(sample)
                    .hidden()
            }
            Text(GuideFormat.time(date))
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GuideFormat.time(date))
    }
}

extension Color {
    /// The "now" marker of the guide (now line, current time, LIVE badges): the theme's live color.
    static let guideNow = Theme.live
}

/// A thin progress bar of a programme on air.
struct ProgrammeProgressBar: View {
    let progress: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, proxy.size.width * progress))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// "On now" line for channel rows: the programme on air with its progress, or what comes next.
struct ChannelProgrammeLine: View {
    let item: ChannelItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NowNextReader(item: item) { nowNext in
            if let nowNext {
                TimelineView(.everyMinute) { context in
                    content(nowNext, now: context.date)
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func content(_ nowNext: NowNext, now: Date) -> some View {
        if let current = nowNext.current, current.isOnAir(at: now) {
            let stacked = dynamicTypeSize.prefersStackedLayout
            Group {
                if stacked {
                    // The title on lines of its own, then the progress and the time left.
                    VStack(alignment: .leading, spacing: 3) {
                        Text(current.title)
                            .lineLimit(3)
                        HStack(spacing: 6) {
                            ProgrammeProgressBar(progress: current.progress(at: now), height: 3)
                                .frame(width: 28)
                            Text(GuideFormat.remaining(current, at: now))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgrammeProgressBar(progress: current.progress(at: now), height: 3)
                            .frame(width: 28)
                        Text(current.title)
                            .lineLimit(1)
                        Text("·")
                            .foregroundStyle(Theme.tertiaryText)
                        Text(GuideFormat.remaining(current, at: now))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("On now: \(current.title), \(GuideFormat.remaining(current, at: now))")
            .channelProgrammeSummary(ChannelAccessibility.onNow(current, at: now))
        } else if let next = nowNext.next {
            Text("Next \(GuideFormat.time(next.start)): \(next.title)")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 1)
                .accessibilityLabel("Next at \(GuideFormat.time(next.start)): \(next.title)")
        }
    }
}

/// Bottom overlay of a live channel card: the programme on air over a soft scrim, with its progress.
struct ChannelCardProgrammeOverlay: View {
    let item: ChannelItem

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if item.kind == .live {
            NowNextReader(item: item) { nowNext in
                if let current = nowNext?.current {
                    TimelineView(.everyMinute) { context in
                        if current.isOnAir(at: context.date) {
                            overlay(current, now: context.date)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private func overlay(_ programme: GuideProgramme, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(programme.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(dynamicTypeSize.prefersStackedLayout ? 2 : 1)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            ProgrammeProgressBar(progress: programme.progress(at: now), tint: .white, height: 3)
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(reduceTransparency || contrast == .increased ? 0.85 : 0.65)], startPoint: .top, endPoint: .bottom)
        }
        // A preview over the artwork: it stops growing at AX1 (the card's label, and the rows, have it whole).
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // The card speaks it in its own label.
        .accessibilityHidden(true)
        .channelProgrammeSummary(ChannelAccessibility.onNow(programme, at: now))
    }
}

/// The programme on air (and the next one) for the player's top bar. With `showGuide` it is a button, with a
/// chevron, that shows the channel's guide.
struct PlayerProgrammeInfo: View {
    let item: ChannelItem?
    var showGuide: (() -> Void)?

    var body: some View {
        NowNextReader(item: item) { nowNext in
            if let nowNext, nowNext.current != nil || nowNext.next != nil {
                TimelineView(.everyMinute) { context in
                    if let showGuide {
                        Button(action: showGuide) {
                            HStack(spacing: 8) {
                                content(nowNext, now: context.date)
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.secondaryText)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the channel's TV guide")
                        .accessibilityInputLabels([Text("Channel Guide"), Text("Guide")])
                        .accessibilityIdentifier("player.programmeInfo")
                        .help("Show the channel's TV guide")
                    } else {
                        content(nowNext, now: context.date)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func content(_ nowNext: NowNext, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let current = nowNext.current, current.isOnAir(at: now) {
                HStack(spacing: 6) {
                    Text(current.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(GuideFormat.timeRange(current))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                ProgrammeProgressBar(progress: current.progress(at: now), tint: .white, height: 3)
                    .frame(maxWidth: 220)
            }
            if let next = nowNext.next {
                Text(TextParts.line([GuideFormat.next(at: next.start), next.title]))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(nowNext, now: now))
    }

    private func accessibilityLabel(_ nowNext: NowNext, now: Date) -> String {
        var parts: [String] = []
        if let current = nowNext.current, current.isOnAir(at: now) {
            parts.append(String(localized: "On now: \(current.title), until \(GuideFormat.time(current.stop))", comment: "VoiceOver description of a channel's programme on now; the placeholders are its title and end time."))
        }
        if let next = nowNext.next {
            parts.append(String(localized: "Next at \(GuideFormat.time(next.start)): \(next.title)", comment: "VoiceOver description of a channel's next programme; the placeholders are its start time and title."))
        }
        return TextParts.sentences(parts)
    }
}

#Preview("Programme lines") {
    let programme = GuideProgramme(sourceID: UUID(), channelID: "a", start: .now.addingTimeInterval(-1_200), stop: .now.addingTimeInterval(2_400), title: "Evening News")
    VStack(alignment: .leading, spacing: 16) {
        Text(GuideFormat.dayAndTime(programme))
        Text(GuideFormat.duration(programme))
        ProgrammeProgressBar(progress: programme.progress(at: .now))
            .frame(width: 120)
        ChannelCardProgrammeOverlay(item: PreviewSampleData.sampleItems[0])
    }
    .padding()
    .fluxoPreviewEnvironment()
}
