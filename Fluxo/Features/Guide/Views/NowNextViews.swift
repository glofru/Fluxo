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
    /// "20:00 – 21:30".
    static func timeRange(_ programme: GuideProgramme) -> String {
        "\(time(programme.start)) – \(time(programme.stop))"
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
        return String(localized: "\(value) left")
    }

    /// "Today", "Tomorrow", "Wednesday 5 November".
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return String(localized: "Today")
        }
        if calendar.isDateInTomorrow(date) {
            return String(localized: "Tomorrow")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// "Today, 20:00 – 21:30".
    static func dayAndTime(_ programme: GuideProgramme) -> String {
        "\(day(programme.start)), \(timeRange(programme))"
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
    /// The "now" marker of the guide (now line, current time, LIVE badges). Red, as in most TV guides; one place
    /// to change it for the app theme.
    static let guideNow = Color.red
}

/// A thin progress bar of a programme on air.
struct ProgrammeProgressBar: View {
    let progress: Double
    var tint: Color = .accentColor
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
            HStack(spacing: 6) {
                ProgrammeProgressBar(progress: current.progress(at: now), height: 3)
                    .frame(width: 28)
                Text(current.title)
                    .lineLimit(1)
                Text("· \(GuideFormat.remaining(current, at: now))")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("On now: \(current.title), \(GuideFormat.remaining(current, at: now))")
        } else if let next = nowNext.next {
            Text("Next \(GuideFormat.time(next.start)): \(next.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("Next at \(GuideFormat.time(next.start)): \(next.title)")
        }
    }
}

/// Bottom overlay of a live channel card: the programme on air over a soft scrim, with its progress.
struct ChannelCardProgrammeOverlay: View {
    let item: ChannelItem

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
                .lineLimit(1)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            ProgrammeProgressBar(progress: programme.progress(at: now), tint: .white, height: 3)
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// The programme on air (and the next one) for the player's top bar.
struct PlayerProgrammeInfo: View {
    let item: ChannelItem?

    var body: some View {
        NowNextReader(item: item) { nowNext in
            if let nowNext, nowNext.current != nil || nowNext.next != nil {
                TimelineView(.everyMinute) { context in
                    content(nowNext, now: context.date)
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
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                ProgrammeProgressBar(progress: current.progress(at: now), tint: .white, height: 3)
                    .frame(maxWidth: 220)
            }
            if let next = nowNext.next {
                Text("Next \(GuideFormat.time(next.start)) · \(next.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(nowNext, now: now))
    }

    private func accessibilityLabel(_ nowNext: NowNext, now: Date) -> String {
        var parts: [String] = []
        if let current = nowNext.current, current.isOnAir(at: now) {
            parts.append(String(localized: "On now: \(current.title), until \(GuideFormat.time(current.stop))"))
        }
        if let next = nowNext.next {
            parts.append(String(localized: "Next at \(GuideFormat.time(next.start)): \(next.title)"))
        }
        return parts.joined(separator: ". ")
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
