//
//  GuideGrid.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftUI

/// Geometry of the time grid: `pointsPerMinute` points per minute of real time (so a day with a daylight saving
/// change is shorter or longer), a pinned channel column on the leading edge and a pinned time ruler on top.
/// Right-to-left languages get the mirrored grid: the channel column on the right and time running leftwards.
struct GuideMetrics: Equatable {
    let pointsPerMinute: CGFloat
    let channelColumnWidth: CGFloat
    let rowHeight: CGFloat
    let rulerHeight: CGFloat
    /// Length of the day shown: 23 or 25 hours on the days daylight saving time starts or ends.
    var dayDuration: TimeInterval = 86_400

    var dayWidth: CGFloat {
        CGFloat(dayDuration / 60) * pointsPerMinute
    }

    /// Half-hour marks of the ruler.
    var halfHourCount: Int {
        Int((dayDuration / 1_800).rounded(.up))
    }

    /// The length of the calendar day that starts at `dayStart`.
    static func duration(ofDayStartingAt dayStart: Date, calendar: Calendar = .current) -> TimeInterval {
        calendar.dateInterval(of: .day, for: dayStart)?.duration ?? 86_400
    }

    func x(for date: Date, dayStart: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(dayStart) / 60) * pointsPerMinute
    }

    /// Horizontal span of a programme inside the day, clipped to it.
    func span(of programme: GuideProgramme, dayStart: Date) -> (x: CGFloat, width: CGFloat) {
        let start = max(0, x(for: programme.start, dayStart: dayStart))
        let end = min(dayWidth, x(for: programme.stop, dayStart: dayStart))
        return (start, max(0, end - start))
    }
}

/// A programme the user opened, with the channel that airs it.
struct GuideSelection: Identifiable, Hashable {
    let programme: GuideProgramme
    let channel: GuideChannel

    var id: String {
        "\(programme.id)|\(channel.id.uuidString)"
    }
}

/// Channels × time for one day: rows are lazy and each loads its own programmes when it appears.
///
/// The channel column stays on the leading edge while scrolling sideways, and the time ruler stays on top while
/// scrolling down (a pinned section header). Both pins and the "sticky" programme titles are `visualEffect`
/// offsets computed from the scroll geometry, so scrolling never re-renders the rows. A line marks the current
/// time on today's grid.
struct GuideGrid: View {

    let channels: [GuideChannel]
    /// Start of the day shown.
    let day: Date
    /// Bumped to scroll to the current time.
    let scrollToNowRequest: Int
    let onSelect: (GuideSelection) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 72
    @State private var position = ScrollPosition(x: 0, y: 0)

    private var metrics: GuideMetrics {
        let isCompact = horizontalSizeClass == .compact
        return GuideMetrics(
            pointsPerMinute: isCompact ? 4 : 5,
            channelColumnWidth: isCompact ? 92 : 172,
            rowHeight: rowHeight,
            rulerHeight: 34,
            dayDuration: GuideMetrics.duration(ofDayStartingAt: day)
        )
    }

    var body: some View {
        let metrics = metrics
        TimelineView(.everyMinute) { timeline in
            let now = timeline.date
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(channels) { channel in
                            GuideRow(channel: channel, day: day, metrics: metrics, now: now, onSelect: onSelect)
                                .id(channel.id)
                        }
                    } header: {
                        GuideTimeRuler(day: day, metrics: metrics, now: now)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            // VoiceOver: the Channels rotor jumps from channel to channel (each row is a container named after it).
            .accessibilityRotor("Channels", entries: channels, entryID: \.id, entryLabel: \.item.displayName)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.width
            } action: { _, _ in
                // The lazy content gets its real width after the first layout: place the grid again until the
                // user scrolls it.
                if !position.isPositionedByUser {
                    scrollToCurrentTime(animated: false)
                }
            }
        }
        .onAppear {
            scrollToCurrentTime(animated: false)
        }
        .onChange(of: scrollToNowRequest) {
            scrollToCurrentTime(animated: true)
        }
        .onChange(of: day) {
            scrollToCurrentTime(animated: false)
        }
    }

    /// Today: half an hour before now. Other days: the same time of day.
    private func scrollToCurrentTime(animated: Bool) {
        let calendar = Calendar.current
        let now = Date.now
        let timeOfDay = now.timeIntervalSince(calendar.startOfDay(for: now))
        let minutes = max(0, timeOfDay / 60 - 30)
        let x = CGFloat(minutes) * metrics.pointsPerMinute
        let apply = {
            position.scrollTo(x: x)
        }
        if animated {
            withAnimation(.smooth, apply)
        } else {
            // After the first layout, so the content size is known.
            DispatchQueue.main.async(execute: apply)
        }
    }
}

/// The hours along the top, pinned while scrolling down; its leading corner stays over the channel column.
private struct GuideTimeRuler: View {
    let day: Date
    let metrics: GuideMetrics
    let now: Date

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let isToday = Calendar.current.isDate(day, inSameDayAs: now)
        let columnWidth = metrics.channelColumnWidth
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(0..<metrics.halfHourCount, id: \.self) { slot in
                    let date = day.addingTimeInterval(TimeInterval(slot) * 1_800)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(GuideFormat.time(date))
                            .font(slot.isMultiple(of: 2) ? .caption.weight(.semibold).monospacedDigit() : .caption2.monospacedDigit())
                            .foregroundStyle(slot.isMultiple(of: 2) ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.secondaryText))
                            .padding(.leading, 6)
                            .fadingUnderPinnedColumn(columnWidth: columnWidth, inset: 6, layoutDirection: layoutDirection)
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(.separator)
                            .frame(width: 1, height: slot.isMultiple(of: 2) ? 10 : 6)
                    }
                    .frame(width: 30 * metrics.pointsPerMinute, height: metrics.rulerHeight, alignment: .topLeading)
                    .offset(x: CGFloat(slot) * 30 * metrics.pointsPerMinute)
                }
                if isToday {
                    // A zero-width anchor on the now line, with the pill centered over it: the pill is as wide
                    // as the time needs ("20:15", "10:15 PM", "午後10:15", larger text).
                    Color.clear
                        .frame(width: 0, height: 0)
                        .overlay(alignment: .top) {
                            Text(GuideFormat.time(now))
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.liveFill, in: .capsule)
                                .fixedSize()
                        }
                        .offset(x: metrics.x(for: now, dayStart: day), y: metrics.rulerHeight - 18)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: metrics.dayWidth, height: metrics.rulerHeight, alignment: .topLeading)
            .padding(.leading, columnWidth)
            .accessibilityHidden(true)

            Text(GuideFormat.day(day))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(width: columnWidth, height: metrics.rulerHeight, alignment: .leading)
                .background(GuidePinnedBackground())
                .overlay(alignment: .trailing) {
                    GuideColumnSeparator()
                }
                .visualEffect { [layoutDirection] content, proxy in
                    content.offset(x: max(0, -proxy.leadingInsetInScrollView(layoutDirection)))
                }
                .zIndex(1)
        }
        .frame(width: columnWidth + metrics.dayWidth, height: metrics.rulerHeight, alignment: .topLeading)
        .background(GuidePinnedBackground())
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Opaque background of the pinned channel column and time ruler, so programmes scrolling under them never
/// show through (a material would let their titles bleed into the channel names).
private struct GuidePinnedBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color.appBackground)
            .overlay(Rectangle().fill(.fill.quinary))
    }
}

/// The vertical hairline at the trailing edge of the pinned column.
private struct GuideColumnSeparator: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1 / displayScale)
            .accessibilityHidden(true)
    }
}

private extension GeometryProxy {
    /// How far the view's leading edge is from the leading edge of the scroll view's visible area, in the
    /// reading direction (negative once it has scrolled past it).
    ///
    /// Offsets are mirrored in right-to-left layouts but geometry frames are not, so there the distance is
    /// measured from the right edge of the visible area to the right edge of the view.
    func leadingInsetInScrollView(_ layoutDirection: LayoutDirection) -> CGFloat {
        let frame = frame(in: .scrollView)
        guard layoutDirection == .rightToLeft, let visible = bounds(of: .scrollView) else {
            return frame.minX
        }
        return visible.width - frame.maxX
    }
}

private extension View {
    /// Fades the view out while it slides under the pinned channel column, so its glyphs are never cut in half
    /// at the column edge: fully visible while its content (`inset` points from its leading edge) is clear of the
    /// column, invisible once that content reaches it.
    func fadingUnderPinnedColumn(columnWidth: CGFloat, inset: CGFloat, layoutDirection: LayoutDirection) -> some View {
        visualEffect { content, proxy in
            let contentStart = proxy.leadingInsetInScrollView(layoutDirection) + inset
            return content.opacity(Double(min(1, max(0, (contentStart - columnWidth) / inset))))
        }
    }
}

/// One channel: its pinned cell and its programmes of the day.
private struct GuideRow: View {
    let channel: GuideChannel
    let day: Date
    let metrics: GuideMetrics
    let now: Date
    let onSelect: (GuideSelection) -> Void

    @Environment(EPGStore.self) private var epg
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var programmes: [GuideProgramme] = []
    @State private var loadedKey: LoadKey?

    private struct LoadKey: Equatable {
        let day: Date
        let ref: GuideChannelRef
        let revision: Int
    }

    var body: some View {
        let columnWidth = metrics.channelColumnWidth
        let key = LoadKey(day: day, ref: channel.ref, revision: epg.revision)
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(programmes) { programme in
                    let span = metrics.span(of: programme, dayStart: day)
                    if span.width > 0 {
                        GuideProgrammeCell(
                            programme: programme,
                            channel: channel,
                            now: now,
                            columnWidth: columnWidth,
                            layoutDirection: layoutDirection,
                            onSelect: onSelect
                        )
                        .frame(width: max(0, span.width - 3), height: metrics.rowHeight - 8)
                        .offset(x: span.x + 1.5, y: 4)
                    }
                }
                if loadedKey == key, programmes.isEmpty {
                    Text("No information")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 10)
                        .frame(height: metrics.rowHeight)
                        .visualEffect { [layoutDirection] content, proxy in
                            content.offset(x: max(0, columnWidth - proxy.leadingInsetInScrollView(layoutDirection)))
                        }
                }
                if Calendar.current.isDate(day, inSameDayAs: now) {
                    Rectangle()
                        .fill(Color.guideNow.opacity(0.85))
                        .frame(width: 1.5, height: metrics.rowHeight)
                        .offset(x: metrics.x(for: now, dayStart: day) - 0.75)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: metrics.dayWidth, height: metrics.rowHeight, alignment: .topLeading)
            .padding(.leading, columnWidth)

            GuideChannelCell(channel: channel)
                .frame(width: columnWidth, height: metrics.rowHeight)
                .background(GuidePinnedBackground())
                .overlay(alignment: .trailing) {
                    GuideColumnSeparator()
                }
                .visualEffect { [layoutDirection] content, proxy in
                    content.offset(x: max(0, -proxy.leadingInsetInScrollView(layoutDirection)))
                }
                .zIndex(1)
        }
        .frame(width: columnWidth + metrics.dayWidth, height: metrics.rowHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            Divider()
        }
        // The channel, then its programmes in time order.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(channel.item.displayName)
        .task(id: key) {
            let interval = DateInterval(start: day, duration: metrics.dayDuration)
            let loaded = await epg.programmes(for: channel.ref, in: interval)
            guard !Task.isCancelled else {
                return
            }
            programmes = loaded
            loadedKey = key
        }
    }
}

/// The channel's logo and name; tapping plays it.
private struct GuideChannelCell: View {
    let channel: GuideChannel

    @Environment(\.playChannel) private var playChannel
    @Environment(ChannelLibrary.self) private var library
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var sourceID = UUID().uuidString

    var body: some View {
        let item = channel.item
        let isCompact = horizontalSizeClass == .compact
        Button {
            playChannel(item, from: sourceID)
        } label: {
            Group {
                if isCompact {
                    VStack(spacing: 4) {
                        logo(size: CGSize(width: 52, height: 30))
                        Text(item.displayName)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 6)
                } else {
                    HStack(spacing: 10) {
                        logo(size: CGSize(width: 56, height: 36))
                        Text(item.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ChannelContextMenu(item: item, isFavorite: library.isFavorite(item))
        }
        .accessibilityLabel(item.displayName)
        .accessibilityHint("Plays the channel")
        .help(item.displayName)
    }

    private func logo(size: CGSize) -> some View {
        LogoImage(source: channel.item.logo, size: size) { phase in
            if phase == .unavailable {
                ArtworkPlaceholder(name: channel.item.displayName, kind: .live)
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                Color.clear
            }
        }
        .playerTransitionSource(id: sourceID, cornerRadius: 6)
        .accessibilityHidden(true)
    }
}

/// One programme block. The title stays visible while the block scrolls under the channel column.
private struct GuideProgrammeCell: View {
    let programme: GuideProgramme
    let channel: GuideChannel
    let now: Date
    let columnWidth: CGFloat
    /// Passed in rather than read here: the row already reads it, and there are many cells.
    let layoutDirection: LayoutDirection
    let onSelect: (GuideSelection) -> Void

    @Environment(EPGStore.self) private var epg
    @Environment(\.playChannel) private var playChannel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    /// Leading padding of the text.
    nonisolated private static let textInset: CGFloat = 8
    /// Width of block the title needs: it stops following the column when less is left.
    nonisolated private static let stickyWidth: CGFloat = 110

    var body: some View {
        let isOnAir = programme.isOnAir(at: now)
        let isOver = programme.stop <= now
        let isReminded = epg.reminders.isScheduled(programme)
        Button {
            onSelect(GuideSelection(programme: programme, channel: channel))
        } label: {
            GeometryReader { proxy in
                if proxy.size.width >= 28 {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            if isOnAir && differentiateWithoutColor {
                                // The block on air is told apart by its tint; with Differentiate Without Color
                                // a symbol says it too.
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Theme.live)
                            }
                            if isReminded {
                                Image(systemName: "bell.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                            }
                            Text(programme.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        Text(GuideFormat.timeRange(programme))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                        if isOnAir {
                            ProgrammeProgressBar(progress: programme.progress(at: now), height: 3)
                                .frame(maxWidth: 120)
                        }
                    }
                    .foregroundStyle(isOver ? AnyShapeStyle(Theme.secondaryText) : AnyShapeStyle(.primary))
                    .padding(.horizontal, Self.textInset)
                    .padding(.vertical, 6)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .visualEffect { [layoutDirection] content, geometry in
                        // Keep the title in view while the start of the block is under the channel column, until
                        // only `stickyWidth` points of the block are left; then fade it out rather than letting
                        // the column cut its glyphs.
                        let minX = geometry.leadingInsetInScrollView(layoutDirection)
                        let hidden = max(0, columnWidth - minX)
                        let shift = min(hidden, max(0, geometry.size.width - Self.stickyWidth))
                        let textStart = minX + shift + Self.textInset
                        let opacity = min(1, max(0, (textStart - columnWidth) / Self.textInset))
                        return content.offset(x: shift).opacity(Double(opacity))
                    }
                    // A title shifted along with the column can run past the end of the block: fade it out there
                    // instead of cutting it (the mask stays on the block, not on the shifted text).
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: Self.textInset)
                                // Unit points are not mirrored: the fade belongs at the trailing end in either direction.
                                .flipsForRightToLeftLayoutDirection(true)
                        }
                    }
                }
            }
            .background(background(isOnAir: isOnAir, isOver: isOver), in: shape)
            .overlay {
                if isOnAir {
                    shape.strokeBorder(.tint.opacity(contrast == .increased ? 1 : 0.6), lineWidth: contrast == .increased || differentiateWithoutColor ? 2 : 1)
                } else if contrast == .increased {
                    shape.strokeBorder(Theme.surfaceStroke)
                }
            }
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .contextMenu {
            Button("Details", systemImage: "info.circle") {
                onSelect(GuideSelection(programme: programme, channel: channel))
            }
            Button("Watch \(channel.item.displayName)", systemImage: "play.fill") {
                playChannel(channel.item)
            }
            if ReminderCenter.canRemind(programme) {
                Button(isReminded ? "Cancel Reminder" : "Remind Me", systemImage: isReminded ? "bell.slash" : "bell") {
                    Task {
                        await epg.reminders.toggle(programme, on: channel.item)
                    }
                }
            }
            // The link of the channel (a programme has none of its own), named so, in its own group.
            if StreamLink(channel.item.url) != nil {
                Divider()
                StreamLinkMenuItems(url: channel.item.url, name: channel.item.displayName, target: .channel)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(isOnAir: isOnAir, isOver: isOver, isReminded: isReminded))
        .accessibilityHint("Shows the details")
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            Button("Watch \(channel.item.displayName)") {
                playChannel(channel.item)
            }
            if ReminderCenter.canRemind(programme) {
                Button(isReminded ? "Cancel Reminder" : "Remind Me") {
                    Task {
                        await epg.reminders.toggle(programme, on: channel.item)
                    }
                }
            }
        }
    }

    private func background(isOnAir: Bool, isOver: Bool) -> AnyShapeStyle {
        if isOnAir {
            return AnyShapeStyle(Theme.accent.opacity(0.22))
        }
        return isOver ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.fill.tertiary)
    }

    private func accessibilityLabel(isOnAir: Bool, isOver: Bool, isReminded: Bool) -> String {
        var parts = [programme.title, channel.item.displayName, GuideFormat.timeRange(programme)]
        if isOnAir {
            parts.append(String(localized: "On now, \(GuideFormat.remaining(programme, at: now))"))
        } else if isOver {
            parts.append(String(localized: "Ended"))
        }
        if isReminded {
            parts.append(String(localized: "Reminder set"))
        }
        return TextParts.spoken(parts)
    }
}

#Preview("Guide grid") {
    GuideGrid(channels: GuidePreviewData.channels, day: Calendar.current.startOfDay(for: .now), scrollToNowRequest: 0) { _ in }
        .fluxoPreviewEnvironment(GuidePreviewData.container)
}

#Preview("Guide grid, right to left") {
    GuideGrid(channels: GuidePreviewData.channels, day: Calendar.current.startOfDay(for: .now), scrollToNowRequest: 0) { _ in }
        .fluxoPreviewEnvironment(GuidePreviewData.container)
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "ar"))
}
