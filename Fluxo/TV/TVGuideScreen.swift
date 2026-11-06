//
//  TVGuideScreen.swift
//  Fluxo
//
//  The Live TV tab of Apple TV: the TV guide as a grid of channels × time made for the focus engine, and the live
//  channels by category (Channels).
//
//  The grid shows a two-hour window. The channel column on the leading edge and the time ruler on top stay put; the
//  rows scroll up and down. Each programme is a button as wide as its time in the window, so swiping moves across
//  the programmes of a channel and up or down to the programme on air at the same time on the channel above or
//  below. A narrow Earlier / Later cell at each end of a row moves the window an hour back or on (the focus lands
//  on the programme that was just out of view), and Earlier, Now, Later and the day menu above the grid jump
//  further. A line marks the current time. Selecting a programme opens it (Watch, Remind Me, what follows), Play /
//  Pause plays its channel, and selecting a channel's name plays it.
//
//  Programmes are read a row at a time as rows scroll in, for a day around the window (`TVGuideModel`), so paging
//  the window within it reads nothing new.
//

#if os(tvOS)
import SwiftData
import SwiftUI

struct TVGuideScreen: View {

    enum Mode: String, CaseIterable {
        case guide
        case channels
    }

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @Query(EPGQueries.sources()) private var sources: [EPGSource]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""
    @AppStorage("tv.live.mode") private var modeRawValue = Mode.guide.rawValue
    @Environment(EPGStore.self) private var epg
    @Environment(AppNavigation.self) private var navigation

    @State private var channels: [GuideChannel]?
    @State private var groupFilter: String?
    @State private var selection: GuideSelection?
    @State private var showsAddSource = false
    @State private var path = NavigationPath()
    /// The window of the grid, kept while the tab is away (coming back shows the same hours).
    @State private var model = TVGuideModel()

    private var scope: LibraryScope {
        LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
    }

    private var hasEnabledSource: Bool {
        epg.visibleSources(sources).contains(where: \.isEnabled)
    }

    /// The channels by category when there is no guide to show.
    private var mode: Mode {
        hasEnabledSource ? (Mode(rawValue: modeRawValue) ?? .guide) : .channels
    }

    var body: some View {
        let scope = scope
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                if playlists.isEmpty {
                    TVNoPlaylistsState(message: String(localized: "TV.live.noPlaylists", defaultValue: "Add an M3U playlist. Its channels and TV guide show up here.", comment: "Apple TV Live TV page when there is no playlist."), systemImage: "calendar.day.timeline.left")
                } else {
                    content(scope: scope)
                }
            }
            .tvDestinations()
        }
        .environment(model)
        .sheet(item: $selection) { selection in
            TVProgrammeScreen(programme: selection.programme, channel: selection.channel.item, ref: selection.channel.ref)
        }
        .sheet(isPresented: $showsAddSource) {
            AddGuideSourceView()
        }
        .task(id: ChannelsKey(importIDs: scope.importIDs, revision: epg.revision)) {
            let loaded = await epg.guideChannels(importIDs: scope.importIDs)
            guard !Task.isCancelled else {
                return
            }
            channels = loaded
            if let groupFilter, !loaded.contains(where: { $0.item.groupName == groupFilter }) {
                self.groupFilter = nil
            }
        }
        #if DEBUG
        .onChange(of: navigation.debugGuideSelection, initial: true) { _, debugSelection in
            // Debug harness (`programme:<channel>`).
            if let debugSelection {
                modeRawValue = Mode.guide.rawValue
                selection = debugSelection
                navigation.debugGuideSelection = nil
            }
        }
        #endif
        // Open Screen (Siri, a fluxo:// link): Live TV from its root.
        .onChange(of: navigation.rootRequest) { _, request in
            if request?.tab == .guide {
                path = NavigationPath()
            }
        }
        .onChange(of: navigation.guideFocus, initial: true) { _, focus in
            // Show in TV Guide: the grid, at the channel.
            if focus != nil {
                modeRawValue = Mode.guide.rawValue
                groupFilter = nil
                path = NavigationPath()
            }
        }
    }

    private struct ChannelsKey: Equatable {
        let importIDs: [UUID]
        let revision: Int
    }

    @ViewBuilder
    private func content(scope: LibraryScope) -> some View {
        let visible = (channels ?? []).filter { groupFilter == nil || $0.item.groupName == groupFilter }
        switch mode {
        case .channels:
            VStack(alignment: .leading, spacing: 0) {
                controls(scope: scope, visible: [])
                if !hasEnabledSource {
                    TVNoGuideBanner {
                        showsAddSource = true
                    }
                }
                TVKindScreen(kind: .live, embedsNavigation: false)
            }
            .padding(.top, TVLayout.tabBarClearance)
            .ignoresSafeArea(edges: [.top, .horizontal])
        case .guide:
            VStack(alignment: .leading, spacing: 0) {
                controls(scope: scope, visible: visible)
                if !epg.isReady || channels == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visible.isEmpty {
                    noChannels
                } else {
                    TVGuideGrid(channels: visible) { selection in
                        self.selection = selection
                    }
                }
            }
            .padding(.top, TVLayout.tabBarClearance)
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
    }

    // MARK: - Controls

    /// Guide / Channels, and in the guide the day, the time and the category.
    private func controls(scope: LibraryScope, visible: [GuideChannel]) -> some View {
        HStack(spacing: 24) {
            if hasEnabledSource {
                Picker(String(localized: "TV.live.mode", defaultValue: "Show", comment: "Apple TV Live TV: the picker between the TV guide grid and the channels by category."), selection: $modeRawValue) {
                    Text(String(localized: "TV.live.guide", defaultValue: "Guide", comment: "Apple TV Live TV: the TV guide grid."))
                        .tag(Mode.guide.rawValue)
                    Text(String(localized: "TV.live.channels", defaultValue: "Channels", comment: "Apple TV Live TV: the live channels by category."))
                        .tag(Mode.channels.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 520)
            } else {
                Text("Live TV")
                    .font(.title3.bold())
            }
            Spacer()
            if mode == .guide {
                TVGuideWindowControls()
                let groups = orderedGroups
                if groups.count > 1 {
                    Picker(selection: $groupFilter) {
                        Text("All Categories")
                            .tag(String?.none)
                        ForEach(groups, id: \.self) { group in
                            Text(ChannelCandidate.displayGroup(group))
                                .tag(String?.some(group))
                        }
                    } label: {
                        Label(groupFilter.map(ChannelCandidate.displayGroup) ?? String(localized: "All Categories"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .padding(.horizontal, TVLayout.margin)
        .padding(.bottom, 24)
        .focusSection()
    }

    /// Categories of the channels with a guide, in playlist order.
    private var orderedGroups: [String] {
        var seen: Set<String> = []
        return (channels ?? []).compactMap { channel in
            seen.insert(channel.item.groupName).inserted ? channel.item.groupName : nil
        }
    }

    @ViewBuilder
    private var noChannels: some View {
        if epg.isRefreshing {
            VStack(spacing: 20) {
                ProgressView()
                Text("Loading the TV guide…")
                    .font(.headline)
                if let message = epg.progress.values.first?.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TVEmptyState(title: String(localized: "No Guide for These Channels"), message: noChannelsDescription, systemImage: "calendar.badge.exclamationmark") {
                Button(String(localized: "Refresh Guide"), systemImage: "arrow.clockwise") {
                    epg.refreshAll()
                }
                .tvActionButton(prominent: true)
                Button(String(localized: "TV.live.showChannels", defaultValue: "Show Channels", comment: "Apple TV Live TV: shows the live channels by category instead of the TV guide."), systemImage: "square.grid.2x2") {
                    modeRawValue = Mode.channels.rawValue
                }
                .tvActionButton()
            }
        }
    }

    private var noChannelsDescription: String {
        let enabled = epg.visibleSources(sources).filter(\.isEnabled)
        if let error = enabled.compactMap(\.lastErrorMessage).first {
            return error
        }
        if enabled.allSatisfy({ $0.currentImportID == nil }) {
            return String(localized: "The guide has not been downloaded yet.")
        }
        return String(localized: "TV.live.noMatch", defaultValue: "None of the live channels match a channel of the guide.", comment: "Apple TV Live TV, when no channel of the playlists has a TV guide.")
    }
}

/// No guide source yet: what a guide adds, and the button to add one.
private struct TVNoGuideBanner: View {
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 30) {
            Image(systemName: "calendar.badge.plus")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "TV.live.noGuide.title", defaultValue: "Add a TV Guide", comment: "Apple TV Live TV, when no TV guide source is set up: the title of the prompt."))
                    .font(.headline)
                Text(String(localized: "TV.live.noGuide.message", defaultValue: "With an XMLTV guide, Live TV shows what is on every channel, now and for the week ahead.", comment: "Apple TV Live TV, when no TV guide source is set up: what a guide adds."))
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button(String(localized: "Add Guide Source…"), systemImage: "plus", action: onAdd)
                .tvActionButton(prominent: true)
        }
        .padding(30)
        .background(.regularMaterial, in: .rect(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, TVLayout.margin)
        .padding(.bottom, 20)
        .focusSection()
    }
}

// MARK: - Model

/// The two-hour window of the grid and the programmes of the rows that were shown, for a day around the window.
@MainActor
@Observable
final class TVGuideModel {

    nonisolated static let windowDuration: TimeInterval = 2 * 3_600
    /// How far Earlier / Later and the cells at the ends of a row move the window.
    static let step: TimeInterval = 3_600
    /// Rows read their programmes for this long around the window.
    static let loadSpan: TimeInterval = 30 * 3_600
    static let dayCount = 7

    var windowStart: Date

    struct Row {
        let range: DateInterval
        let programmes: [GuideProgramme]
    }

    private(set) var rows: [UUID: Row] = [:]
    /// Bumped when rows load (pending focus moves wait for them).
    private(set) var loadCount = 0
    @ObservationIgnored
    private var revision = -1

    init(now: Date = .now) {
        windowStart = Self.aligned(now.addingTimeInterval(-Self.leadIn))
    }

    /// The window starts this much before now (on the half hour before that), so what is on air shows with some
    /// of what came before.
    static let leadIn: TimeInterval = 15 * 60

    func showNow() {
        show(Date.now.addingTimeInterval(-Self.leadIn))
    }

    var windowEnd: Date {
        windowStart.addingTimeInterval(Self.windowDuration)
    }

    var window: DateInterval {
        DateInterval(start: windowStart, duration: Self.windowDuration)
    }

    /// Today's first half hour; the guide keeps the programmes of the week ahead.
    var earliestStart: Date {
        Calendar.current.startOfDay(for: .now)
    }

    var latestStart: Date {
        let end = Calendar.current.date(byAdding: .day, value: Self.dayCount, to: earliestStart) ?? earliestStart.addingTimeInterval(7 * 86_400)
        return end.addingTimeInterval(-Self.windowDuration)
    }

    var canGoEarlier: Bool {
        windowStart > earliestStart
    }

    var canGoLater: Bool {
        windowStart < latestStart
    }

    /// Starts the window on the half hour at or before `date`, within the days the guide keeps.
    func show(_ date: Date) {
        windowStart = min(latestStart, max(earliestStart, Self.aligned(date)))
    }

    func move(by interval: TimeInterval) {
        show(windowStart.addingTimeInterval(interval))
    }

    /// The half hour at or before `date`.
    static func aligned(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var aligned = components
        aligned.minute = (components.minute ?? 0) < 30 ? 0 : 30
        return calendar.date(from: aligned) ?? date
    }

    /// The load key of the window: rows read again only when it leaves the span read for the last one.
    var loadBucket: Date {
        let start = earliestStart
        let index = (windowStart.timeIntervalSince(start) / (12 * 3_600)).rounded(.down)
        return start.addingTimeInterval(index * 12 * 3_600)
    }

    func programmes(for channelID: UUID) -> [GuideProgramme]? {
        guard let row = rows[channelID], row.range.contains(windowStart), row.range.contains(windowEnd) else {
            return nil
        }
        let window = window
        return row.programmes.filter { $0.stop > window.start && $0.start < window.end && $0.stop > $0.start }
    }

    /// Reads the programmes of a row for the span around the window, unless they are read already.
    func load(_ channel: GuideChannel, epg: EPGStore) async {
        if revision != epg.revision {
            revision = epg.revision
            rows = [:]
        }
        if programmes(for: channel.id) != nil {
            return
        }
        let range = DateInterval(start: loadBucket.addingTimeInterval(-6 * 3_600), duration: Self.loadSpan)
        let loaded = await epg.programmes(for: channel.ref, in: range)
        guard !Task.isCancelled else {
            return
        }
        rows[channel.id] = Row(range: range, programmes: loaded.sorted { $0.start < $1.start })
        loadCount &+= 1
    }

    /// The programme of a row on air at `date`, or the first one after it in the window.
    func programme(in channelID: UUID, at date: Date, forward: Bool) -> GuideProgramme? {
        guard let programmes = programmes(for: channelID) else {
            return nil
        }
        if let covering = programmes.first(where: { $0.start <= date && date < $0.stop }) {
            return covering
        }
        return forward ? programmes.first { $0.start >= date } : programmes.last { $0.stop <= date }
    }
}

/// Earlier, Now, Later and the day, above the grid.
private struct TVGuideWindowControls: View {
    @Environment(TVGuideModel.self) private var model

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let days = (0..<TVGuideModel.dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let shownDay = calendar.startOfDay(for: model.windowStart)
        HStack(spacing: 20) {
            Button {
                model.move(by: -TVGuideModel.step * 2)
            } label: {
                Label(String(localized: "TV.guide.earlier", defaultValue: "Earlier", comment: "Apple TV TV guide: moves the grid two hours back."), systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
            }
            .disabled(!model.canGoEarlier)
            Button(String(localized: "TV.guide.now", defaultValue: "Now", comment: "Apple TV TV guide: moves the grid to the current time.")) {
                model.showNow()
            }
            .lineLimit(1)
            .fixedSize()
            Button {
                model.move(by: TVGuideModel.step * 2)
            } label: {
                Label(String(localized: "TV.guide.later", defaultValue: "Later", comment: "Apple TV TV guide: moves the grid two hours on."), systemImage: "chevron.forward")
                    .labelStyle(.iconOnly)
            }
            .disabled(!model.canGoLater)
            Picker(selection: Binding(get: { shownDay }, set: { day in
                // Another day at the same time of day (now, for today).
                let offset = model.windowStart.timeIntervalSince(shownDay)
                if calendar.isDateInToday(day) {
                    model.showNow()
                } else {
                    model.show(day.addingTimeInterval(offset))
                }
            })) {
                ForEach(days, id: \.self) { day in
                    Text(GuideFormat.day(day))
                        .tag(day)
                }
            } label: {
                Label(GuideFormat.day(shownDay), systemImage: "calendar")
                    .lineLimit(1)
                    .fixedSize()
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

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
        .defaultFocus($focus, initialFocus)
        .onChange(of: focus) { old, new in
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
                if window.contains(now) {
                    Rectangle()
                        .fill(Theme.live)
                        .frame(width: 3, height: TVGuideMetrics.rowHeight)
                        .offset(x: TVGuideMetrics.x(of: now, in: window) - 1.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
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
                TVLandscapeArtwork(item: channel.item, size: CGSize(width: 120, height: 68))
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    if let number = channel.item.number {
                        Text(number.formatted(.number.grouping(.never)))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .opacity(0.7)
                    }
                    Text(channel.item.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
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

// MARK: - Programme

/// A programme that follows on the channel: its time and title. Selecting it sets a reminder (or removes it).
private struct TVUpNextRow: View {
    let programme: GuideProgramme
    let channel: ChannelItem
    let now: Date

    @Environment(EPGStore.self) private var epg

    var body: some View {
        let isScheduled = epg.reminders.isScheduled(programme)
        let canRemind = ReminderCenter.canRemind(programme, now: now)
        Button {
            Task {
                await epg.reminders.toggle(programme, on: channel)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(GuideFormat.time(programme.start))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(programme.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if isScheduled || canRemind {
                    Image(systemName: isScheduled ? "bell.fill" : "bell")
                        .font(.callout)
                        .foregroundStyle(isScheduled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(width: 640, alignment: .leading)
        }
        .buttonStyle(TVGuideCellStyle(kind: .programme(isOnAir: false, isPast: false)))
        .disabled(!canRemind && !isScheduled)
        .accessibilityLabel(Text(TextParts.spoken([GuideFormat.time(programme.start), programme.title, isScheduled ? String(localized: "TV.programme.reminderSet", defaultValue: "Reminder Set", comment: "Apple TV, a programme: the reminder is set (selecting it removes it).") : nil])))
        .accessibilityHint(Text(isScheduled ? String(localized: "TV.programme.removeReminderHint", defaultValue: "Removes the reminder", comment: "VoiceOver hint of a programme that follows, on Apple TV, when a reminder is set for it.") : String(localized: "TV.programme.remindHint", defaultValue: "Reminds you before it starts", comment: "VoiceOver hint of a programme that follows, on Apple TV: selecting it sets a reminder.")))
    }
}

/// A programme, full screen: its image (or the channel's), the channel, the title, when it airs and how far it is,
/// the categories and the description, with Watch and Remind Me, and what follows on the channel.
struct TVProgrammeScreen: View {
    let programme: GuideProgramme
    let channel: ChannelItem
    let ref: GuideChannelRef?

    @Environment(EPGStore.self) private var epg
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dismiss) private var dismiss
    @State private var upNext: [GuideProgramme] = []
    @FocusState private var isWatchFocused: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let isOnAir = programme.isOnAir(at: now)
            HStack(alignment: .top, spacing: 70) {
                VStack(alignment: .leading, spacing: 30) {
                    artwork
                    if !upNext.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Up Next on \(channel.displayName)", comment: "Apple TV, a programme of the TV guide shown full screen: header of the programmes that follow on the channel; the placeholder is the channel name.")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(upNext) { next in
                                TVUpNextRow(programme: next, channel: channel, now: now)
                            }
                        }
                    }
                }
                .frame(width: 640, alignment: .leading)

                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        if isOnAir {
                            LiveBadge()
                        }
                        Text(TextParts.line([channel.displayName, channel.number.map { String(localized: "Channel \($0.formatted(.number.grouping(.never)))", comment: "The channel number of the playlist, as in 'Channel 12'.") }]))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    Text(programme.title)
                        .font(.title.bold())
                        .lineLimit(3)
                        .accessibilityAddTraits(.isHeader)
                    if let detail = programme.detailLine {
                        Text(detail)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Text(TextParts.line([GuideFormat.dayAndTime(programme), GuideFormat.duration(programme)]))
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                    if isOnAir {
                        HStack(spacing: 20) {
                            ProgrammeProgressBar(progress: programme.progress(at: now), tint: Theme.live, height: 8)
                                .frame(width: 420)
                            Text(GuideFormat.remaining(programme, at: now))
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if !programme.categories.isEmpty {
                        Text(programme.categories.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                    }
                    if !programme.summary.isEmpty {
                        Text(programme.summary)
                            .font(.body)
                            .lineLimit(8)
                            .frame(maxWidth: 1_000, alignment: .leading)
                    }
                    actions(now: now, isOnAir: isOnAir)
                        .padding(.top, 16)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TVLayout.margin + 20)
            .padding(.vertical, TVLayout.verticalMargin + 30)
        }
        .defaultFocus($isWatchFocused, true)
        .task(id: ref) {
            guard let ref else {
                return
            }
            upNext = await epg.upcoming(for: ref, from: programme.stop, limit: 4).filter { $0.start >= programme.stop }
        }
    }

    private var artwork: some View {
        let size = CGSize(width: 640, height: 360)
        return ZStack {
            TVLandscapeArtwork(item: channel, size: size)
            if let icon = programme.icon {
                LogoImage(source: icon, size: size, contentMode: .fill) { _ in
                    Color.clear
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .accessibilityHidden(true)
    }

    private func actions(now: Date, isOnAir: Bool) -> some View {
        let reminders = epg.reminders
        let canRemind = ReminderCenter.canRemind(programme, now: now)
        let isScheduled = reminders.isScheduled(programme)
        return GlassEffectContainer(spacing: 24) {
            HStack(spacing: 24) {
                Button {
                    dismiss()
                    playChannel(channel)
                } label: {
                    Label(isOnAir ? String(localized: "Watch Now") : String(localized: "TV.programme.watchChannel", defaultValue: "Watch Channel", comment: "Apple TV, a programme that is not on air: plays its channel."), systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 12)
                }
                .tvActionButton(prominent: true)
                .focused($isWatchFocused)

                if canRemind || isScheduled {
                    Button {
                        Task {
                            await reminders.toggle(programme, on: channel)
                        }
                    } label: {
                        Label(isScheduled ? String(localized: "TV.programme.reminderSet", defaultValue: "Reminder Set", comment: "Apple TV, a programme: the reminder is set (selecting it removes it).") : String(localized: "Remind Me"), systemImage: isScheduled ? "bell.fill" : "bell")
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .tvActionButton()
                }
            }
        }
    }
}
#endif
