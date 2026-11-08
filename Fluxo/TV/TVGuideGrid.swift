//
//  TVGuideGrid.swift
//  Fluxo
//
//  Apple TV's guide grid (TVGuideScreen): channels × time for the focus engine, its time ruler, its rows and their
//  programme cells.
//

import SwiftData
import SwiftUI

#if os(tvOS)
// MARK: - Grid

enum TVGuideFocus: Hashable {
    case channel(UUID)
    case programme(UUID, String)
    /// The cell at the leading end of a row: an hour back.
    case earlier(UUID)
    /// The cell at the trailing end of a row: an hour on.
    case later(UUID)
    /// A row without programmes in the window.
    case empty(UUID)

    var rowID: UUID {
        switch self {
        case .channel(let id), .programme(let id, _), .earlier(let id), .later(let id), .empty(let id):
            return id
        }
    }
}

struct TVGuideMetrics {
    static let channelColumnWidth: CGFloat = 330
    static let endCellWidth: CGFloat = 56
    static let rowHeight: CGFloat = 116
    static let cellSpacing: CGFloat = 8
    static let rulerHeight: CGFloat = 54

    /// Width of the programmes of the window.
    static var timelineWidth: CGFloat {
        1_920 - 2 * TVLayout.margin - channelColumnWidth - 2 * endCellWidth - 2 * cellSpacing
    }

    static var pointsPerSecond: CGFloat {
        timelineWidth / CGFloat(TVGuideModel.windowDuration)
    }

    static func x(of date: Date, in window: DateInterval) -> CGFloat {
        CGFloat(date.timeIntervalSince(window.start)) * pointsPerSecond
    }
}

struct TVGuideGrid: View {
    let channels: [GuideChannel]
    let onSelect: (GuideSelection) -> Void

    @Environment(TVGuideModel.self) private var model
    @Environment(EPGStore.self) private var epg
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.playChannel) private var playChannel
    @FocusState private var focus: TVGuideFocus?
    /// A move of the window waits for the row's programmes, then focuses this one.
    @State private var pendingFocus: PendingFocus?
    /// The last channel or programme that had the focus: it gets it back when the focus returns to the grid, from the
    /// player (Watch or Record in a programme's sheet, a channel's name) or from the tab bar.
    @State private var lastFocus: TVGuideFocus?

    private struct PendingFocus: Equatable {
        let rowID: UUID
        let date: Date
        let forward: Bool
    }

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let now = timeline.date
            VStack(alignment: .leading, spacing: 0) {
                TVGuideRuler(window: model.window, now: now)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(channels) { channel in
                                TVGuideRow(channel: channel, now: now, focus: $focus, onSelect: onSelect)
                                    .id(channel.id)
                            }
                        }
                        .padding(.horizontal, TVLayout.margin)
                        .padding(.bottom, TVLayout.verticalMargin)
                    }
                    .scrollClipDisabled()
                    .scrollIndicators(.hidden)
                    .accessibilityRotor("Channels", entries: channels, entryID: \.id, entryLabel: \.item.displayName)
                    .onChange(of: navigation.guideFocus, initial: true) { _, request in
                        if let request {
                            show(request.item, proxy: proxy)
                        }
                    }
                }
            }
        }
        .focusSection()
        .defaultFocus($focus, restoredFocus ?? initialFocus)
        .onChange(of: focus) { old, new in
            switch new {
            case .channel, .programme, .empty:
                lastFocus = new
            case .earlier, .later, nil:
                // The end cells move the window as they take the focus: never given back.
                break
            }
            moveWindowIfNeeded(from: old, to: new)
        }
        .onChange(of: model.loadCount) {
            applyPendingFocus()
        }
        #if DEBUG
        .onChange(of: navigation.debugFocusName, initial: true) { _, name in
            debugFocus(name)
        }
        .onChange(of: model.loadCount) {
            if navigation.debugFocusName != nil, focus == nil {
                debugFocus(navigation.debugFocusName)
            }
        }
        #endif
    }

    /// `lastFocus`, while it is still in the grid (its channel listed, its programme in the window).
    private var restoredFocus: TVGuideFocus? {
        guard let last = lastFocus, channels.contains(where: { $0.id == last.rowID }) else {
            return nil
        }
        switch last {
        case .programme(let rowID, let programmeID):
            return model.programmes(for: rowID)?.contains { $0.id == programmeID } == true ? last : .channel(rowID)
        case .empty(let rowID):
            return model.programmes(for: rowID)?.isEmpty == true ? last : .channel(rowID)
        case .channel, .earlier, .later:
            return last
        }
    }

    /// The programme on air on the first channel (or the channel itself while its row loads).
    private var initialFocus: TVGuideFocus? {
        guard let first = channels.first else {
            return nil
        }
        if let programme = model.programme(in: first.id, at: max(.now, model.windowStart), forward: true) {
            return .programme(first.id, programme.id)
        }
        return .channel(first.id)
    }

    /// The cells at the ends of a row move the window and hand the focus to the programme that comes into view.
    private func moveWindowIfNeeded(from old: TVGuideFocus?, to new: TVGuideFocus?) {
        switch new {
        case .later(let rowID):
            guard model.canGoLater else {
                return
            }
            let target = model.windowEnd
            model.move(by: TVGuideModel.step)
            pendingFocus = PendingFocus(rowID: rowID, date: target, forward: true)
            applyPendingFocus()
        case .earlier(let rowID):
            guard model.canGoEarlier else {
                return
            }
            let target = model.windowStart.addingTimeInterval(-1)
            model.move(by: -TVGuideModel.step)
            pendingFocus = PendingFocus(rowID: rowID, date: target, forward: false)
            applyPendingFocus()
        default:
            break
        }
    }

    private func applyPendingFocus() {
        guard let pending = pendingFocus, model.programmes(for: pending.rowID) != nil else {
            return
        }
        pendingFocus = nil
        let target: TVGuideFocus
        if let programme = model.programme(in: pending.rowID, at: pending.date, forward: pending.forward) {
            target = .programme(pending.rowID, programme.id)
        } else {
            target = .empty(pending.rowID)
        }
        Task { @MainActor in
            // The cells of the new window are laid out first.
            try? await Task.sleep(for: .milliseconds(60))
            focus = target
        }
    }

    /// Show in TV Guide: the window at now, the channel's row in view, its programme on air focused.
    private func show(_ item: ChannelItem, proxy: ScrollViewProxy) {
        guard let match = channels.first(where: { $0.id == item.id })
            ?? channels.first(where: { item.url != nil && $0.item.url == item.url && $0.item.playlistID == item.playlistID }) else {
            return
        }
        navigation.guideFocus = nil
        model.showNow()
        proxy.scrollTo(match.id, anchor: .center)
        pendingFocus = PendingFocus(rowID: match.id, date: .now, forward: true)
        applyPendingFocus()
        AccessibilityAnnouncer.announce(String(localized: "\(match.item.displayName) in the TV guide", comment: "VoiceOver announcement when the TV guide opens at a channel (Full Guide in the player); the placeholder is the channel name."))
    }

    #if DEBUG
    /// `focus:guide-now` (the programme on air on the first channel), `focus:guide-later` (the Later cell of the
    /// first row), `focus:guide-channel` (the first channel), `focus:programme:<channel>`.
    private func debugFocus(_ name: String?) {
        guard let name = name?.lowercased(), let first = channels.first else {
            return
        }
        switch name {
        case "guide-now":
            if let programme = model.programme(in: first.id, at: .now, forward: true) {
                focus = .programme(first.id, programme.id)
            }
        case "guide-later":
            focus = .later(first.id)
        case "guide-channel":
            focus = .channel(first.id)
        default:
            if name.hasPrefix("programme:") {
                let channelName = name.dropFirst("programme:".count)
                if let channel = channels.first(where: { $0.item.displayName.lowercased() == channelName }),
                   let programme = model.programme(in: channel.id, at: max(.now, model.windowStart), forward: true) {
                    focus = .programme(channel.id, programme.id)
                }
            }
        }
    }
    #endif
}

/// The times of the window above the rows, every half hour, and the current time.
private struct TVGuideRuler: View {
    let window: DateInterval
    let now: Date

    var body: some View {
        // The half hours, but not the one the current time's label would cover.
        let nowX = window.contains(now) ? TVGuideMetrics.x(of: now, in: window) : nil
        let marks = stride(from: 0, to: TVGuideModel.windowDuration, by: 1_800).map { window.start.addingTimeInterval($0) }.filter { mark in
            guard let nowX else {
                return true
            }
            let x = TVGuideMetrics.x(of: mark, in: window)
            return x + 130 < nowX - 40 || x > nowX + 110
        }
        HStack(spacing: 0) {
            Text(GuideFormat.day(window.start))
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: TVGuideMetrics.channelColumnWidth + TVGuideMetrics.endCellWidth + TVGuideMetrics.cellSpacing * 2, alignment: .leading)
            ZStack(alignment: .leading) {
                ForEach(marks, id: \.self) { mark in
                    Text(GuideFormat.time(mark))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .offset(x: TVGuideMetrics.x(of: mark, in: window))
                }
                if window.contains(now) {
                    Text(GuideFormat.time(now))
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(Theme.liveFill, in: .capsule)
                        .offset(x: max(0, TVGuideMetrics.x(of: now, in: window) - 40))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: TVGuideMetrics.timelineWidth, height: TVGuideMetrics.rulerHeight, alignment: .leading)
        }
        .padding(.horizontal, TVLayout.margin)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(TextParts.spoken([GuideFormat.day(window.start), GuideFormat.time(window.start), GuideFormat.time(window.end)])))
    }
}

/// One channel: its name (plays it) and its programmes in the window.
private struct TVGuideRow: View {
    let channel: GuideChannel
    let now: Date
    let focus: FocusState<TVGuideFocus?>.Binding
    let onSelect: (GuideSelection) -> Void

    @Environment(TVGuideModel.self) private var model
    @Environment(EPGStore.self) private var epg
    @Environment(\.playChannel) private var playChannel

    var body: some View {
        let window = model.window
        let programmes = model.programmes(for: channel.id)
        HStack(spacing: TVGuideMetrics.cellSpacing) {
            channelCell
            endCell(isLater: false, isEnabled: model.canGoEarlier)
            ZStack(alignment: .leading) {
                // The line of now, behind the programmes' opaque tiles (`TVGuideCellStyle`): it shows between them
                // and the rows, and never crosses their titles.
                if window.contains(now) {
                    Rectangle()
                        .fill(Theme.live)
                        .frame(width: 3, height: TVGuideMetrics.rowHeight)
                        .offset(x: TVGuideMetrics.x(of: now, in: window) - 1.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let programmes {
                    if programmes.isEmpty {
                        emptyCell
                    } else {
                        cells(programmes, window: window)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.primary.opacity(0.05))
                        .frame(width: TVGuideMetrics.timelineWidth, height: TVGuideMetrics.rowHeight - 12)
                }
            }
            .frame(width: TVGuideMetrics.timelineWidth, height: TVGuideMetrics.rowHeight, alignment: .leading)
            endCell(isLater: true, isEnabled: model.canGoLater)
        }
        .frame(height: TVGuideMetrics.rowHeight)
        .focusSection()
        .task(id: LoadKey(channelID: channel.id, bucket: model.loadBucket, revision: epg.revision)) {
            await model.load(channel, epg: epg)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(channel.item.displayName))
    }

    private struct LoadKey: Hashable {
        let channelID: UUID
        let bucket: Date
        let revision: Int
    }

    private var channelCell: some View {
        Button {
            playChannel(channel.item)
        } label: {
            HStack(spacing: 18) {
                // The number on the logo, so the name has the cell's height for two lines in every script (Arabic,
                // Thai and Devanagari lines are taller than Latin ones).
                TVLandscapeArtwork(item: channel.item, size: CGSize(width: 120, height: 68))
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if let number = channel.item.number {
                            Text(number.formatted(.number.grouping(.never)))
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(.black.opacity(0.65), in: .capsule)
                                .offset(x: -6, y: 8)
                        }
                    }
                Text(channel.item.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(width: TVGuideMetrics.channelColumnWidth, height: TVGuideMetrics.rowHeight - 12)
        }
        .buttonStyle(TVGuideCellStyle(kind: .channel))
        .focused(focus, equals: .channel(channel.id))
        .accessibilityLabel(Text(TextParts.spoken([channel.item.displayName, channel.item.number.map { String(localized: "Channel \($0.formatted(.number.grouping(.never)))", comment: "VoiceOver: the channel number of the playlist, as in 'Channel 12'.") }])))
        .accessibilityHint(Text(TVText.playsHint(for: channel.item)))
    }

    private func endCell(isLater: Bool, isEnabled: Bool) -> some View {
        Button {
            model.move(by: isLater ? TVGuideModel.step : -TVGuideModel.step)
        } label: {
            Image(systemName: isLater ? "chevron.forward" : "chevron.backward")
                .font(.callout.weight(.bold))
                .frame(width: TVGuideMetrics.endCellWidth, height: TVGuideMetrics.rowHeight - 12)
        }
        .buttonStyle(TVGuideCellStyle(kind: .end))
        .focused(focus, equals: isLater ? .later(channel.id) : .earlier(channel.id))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.25)
        .accessibilityLabel(isLater ? Text(String(localized: "TV.guide.laterHour", defaultValue: "An Hour Later", comment: "VoiceOver: the cell at the end of a TV guide row on Apple TV, which moves the grid an hour on.")) : Text(String(localized: "TV.guide.earlierHour", defaultValue: "An Hour Earlier", comment: "VoiceOver: the cell at the start of a TV guide row on Apple TV, which moves the grid an hour back.")))
    }

    private var emptyCell: some View {
        Button {
            playChannel(channel.item)
        } label: {
            Text(String(localized: "TV.guide.noInformation", defaultValue: "No programme information", comment: "Apple TV TV guide: a row without programmes in the hours shown."))
                .font(.caption)
                .frame(width: TVGuideMetrics.timelineWidth, height: TVGuideMetrics.rowHeight - 12)
        }
        .buttonStyle(TVGuideCellStyle(kind: .programme(isOnAir: false, isPast: false)))
        .focused(focus, equals: .empty(channel.id))
        .accessibilityHint(Text(TVText.playsHint(for: channel.item)))
    }

    /// The programmes laid out in time, with gaps where the guide has none.
    private func cells(_ programmes: [GuideProgramme], window: DateInterval) -> some View {
        let layout = programmes.map { programme -> (programme: GuideProgramme, x: CGFloat, width: CGFloat) in
            let start = max(programme.start, window.start)
            let end = min(programme.stop, window.end)
            let x = TVGuideMetrics.x(of: start, in: window)
            return (programme, x, max(0, TVGuideMetrics.x(of: end, in: window) - x))
        }
        return ZStack(alignment: .leading) {
            ForEach(layout, id: \.programme.id) { entry in
                if entry.width >= 24 {
                    programmeCell(entry.programme, width: entry.width - TVGuideMetrics.cellSpacing, isClippedAtStart: entry.programme.start < window.start)
                        .offset(x: entry.x)
                }
            }
        }
        .frame(width: TVGuideMetrics.timelineWidth, alignment: .leading)
    }

    private func programmeCell(_ programme: GuideProgramme, width: CGFloat, isClippedAtStart: Bool) -> some View {
        let isOnAir = programme.isOnAir(at: now)
        let isPast = programme.stop <= now
        return Button {
            onSelect(GuideSelection(programme: programme, channel: channel))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isClippedAtStart {
                        Image(systemName: "chevron.backward")
                            .font(.caption2.weight(.bold))
                            .opacity(0.6)
                            .accessibilityHidden(true)
                    }
                    Text(programme.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                if width > 150 {
                    Text(GuideFormat.timeRange(programme))
                        .font(.caption2)
                        .monospacedDigit()
                        .opacity(0.7)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isOnAir {
                    ProgrammeProgressBar(progress: programme.progress(at: now), tint: Theme.live, height: 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: max(0, width), height: TVGuideMetrics.rowHeight - 12, alignment: .leading)
        }
        .buttonStyle(TVGuideCellStyle(kind: .programme(isOnAir: isOnAir, isPast: isPast)))
        .focused(focus, equals: .programme(channel.id, programme.id))
        .onPlayPauseCommand {
            playChannel(channel.item)
        }
        .accessibilityLabel(Text(TextParts.spoken([programme.title, GuideFormat.timeRange(programme), isOnAir ? String(localized: "On Now") : nil, channel.item.displayName])))
        .accessibilityHint(Text(String(localized: "TV.guide.programmeHint", defaultValue: "Shows the programme. Play/Pause plays the channel.", comment: "VoiceOver hint of a programme in the Apple TV TV guide.")))
    }
}

/// The cells of the grid: quiet tiles that turn into the accent and grow a little under the focus. Programmes on
/// air are tinted, programmes that ended are dimmed.
struct TVGuideCellStyle: ButtonStyle {
    enum Kind {
        case channel
        case end
        case programme(isOnAir: Bool, isPast: Bool)
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        Cell(configuration: configuration, kind: kind)
    }

    private struct Cell: View {
        let configuration: Configuration
        let kind: Kind

        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.white : textColor)
                .background(background, in: .rect(cornerRadius: 12, style: .continuous))
                // Opaque, on the page's color: the line of now passes behind the tiles, in the gaps between them,
                // never through their titles.
                .background(Color.tvPageBackground(colorScheme), in: .rect(cornerRadius: 12, style: .continuous))
                .scaleEffect(isFocused ? 1.04 : (configuration.isPressed ? 0.98 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 16, y: 8)
                .zIndex(isFocused ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }

        private var background: AnyShapeStyle {
            if isFocused {
                return AnyShapeStyle(Theme.accentFill)
            }
            switch kind {
            case .channel:
                return AnyShapeStyle(.primary.opacity(0.08))
            case .end:
                return AnyShapeStyle(.primary.opacity(0.04))
            case .programme(let isOnAir, _):
                return isOnAir ? AnyShapeStyle(Theme.accent.opacity(colorScheme == .dark ? 0.22 : 0.16)) : AnyShapeStyle(.primary.opacity(0.08))
            }
        }

        private var textColor: Color {
            if case .programme(_, let isPast) = kind, isPast {
                return Theme.secondaryText
            }
            return .primary
        }
    }
}
#endif
