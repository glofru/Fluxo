//
//  PlayerSidePanel.swift
//  Fluxo
//
//  The panel next to the video in a wide player (iPad in landscape, a wide Mac window): the channels of the
//  playing channel's category, with what each shows now, to switch channel at a glance; and the guide of the
//  playing channel (what is on now and next, with reminders). The video shrinks to make room, so nothing of it
//  is hidden. The player's top bar has the button that shows and hides it; it stays open across channels and
//  launches.
//

import SwiftData
import SwiftUI

/// What the side panel shows.
enum PlayerSidePanelTab: String, CaseIterable, Identifiable {
    case channels
    case guide

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .channels:
            return "Channels"
        case .guide:
            return "Guide"
        }
    }

    var systemImage: String {
        switch self {
        case .channels:
            return "list.bullet"
        case .guide:
            return "calendar.day.timeline.left"
        }
    }
}

/// When the panel can be shown, and its width.
enum PlayerSidePanelLayout {
    static let width: CGFloat = 360
    static let storageKey = "player.sidePanel"
    static let tabStorageKey = "player.sidePanelTab"

    /// The player is wide enough (landscape, room for the panel and a usable video) and plays a playlist entry.
    @MainActor
    static func isAvailable(size: CGSize, item: ChannelItem?) -> Bool {
        guard item != nil else {
            return false
        }
        #if os(iOS)
        guard DeviceIdiom.isPad else {
            return false
        }
        #endif
        return size.width >= 900 && size.width > size.height
    }
}

struct PlayerSidePanel: View {

    let viewModel: AVPlayerViewModel
    let close: () -> Void

    @AppStorage(PlayerSidePanelLayout.tabStorageKey) private var tab: PlayerSidePanelTab = .channels
    /// The channel whose schedule the Guide tab shows instead of the playing one ("Today's Schedule" in the menu
    /// of a channel row). The schedule opens here, in the panel: the app's schedule sheet and inspector are under
    /// the player, or in another window.
    @State private var scheduleItem: ChannelItem?
    @Environment(ChannelLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $tab) {
                    ForEach(PlayerSidePanelTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Hide Side Panel")
                .help("Hide the channel list")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let item = viewModel.currentItem {
                switch tab {
                case .channels:
                    PlayerChannelList(viewModel: viewModel, item: item) { channel in
                        scheduleItem = channel.id == item.id ? nil : channel
                        tab = .guide
                    }
                    .id(GroupKey(playlistID: item.playlistID, groupName: item.groupName))
                case .guide:
                    if let scheduleItem, scheduleItem.id != item.id {
                        PlayerScheduleHeader(item: scheduleItem, canPlay: !viewModel.isRecording) {
                            library.recordWatch(scheduleItem)
                            viewModel.play(scheduleItem, present: false)
                        } close: {
                            self.scheduleItem = nil
                        }
                        .transition(.opacity)
                    }
                    let guideItem = scheduleItem ?? item
                    PlayerGuideList(item: guideItem)
                        .id(guideItem.id)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
        .padding(.vertical, 12)
        .padding(.trailing, 12)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: tab)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: scheduleItem?.id)
        .onChange(of: tab) { _, tab in
            if tab == .channels {
                scheduleItem = nil
            }
        }
        .onChange(of: viewModel.currentItem?.id) { _, _ in
            // Zapped (possibly to the channel of the schedule, with its Watch button): back to the playing one.
            scheduleItem = nil
        }
    }

    private struct GroupKey: Hashable {
        let playlistID: UUID
        let groupName: String
    }
}

// MARK: - Channels

/// The channels of the playing channel's category in playlist order, a page at a time. The playing one is
/// highlighted and scrolled to; a tap plays another one (channel zapping without leaving the video).
private struct PlayerChannelList: View {

    let viewModel: AVPlayerViewModel
    /// The channel the list was opened for: the category it lists.
    let item: ChannelItem
    /// Shows a channel's schedule in the panel's Guide tab.
    let showSchedule: (ChannelItem) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(ChannelLibrary.self) private var library
    @State private var model = CategoryChannelsModel()
    @State private var didScrollToCurrent = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text(item.groupName.isEmpty ? String(localized: "Other") : item.groupName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 6)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(model.items) { channel in
                        PlayerChannelRow(
                            item: channel,
                            isCurrent: channel.id == viewModel.currentItem?.id,
                            isEnabled: !viewModel.isRecording
                        ) {
                            library.recordWatch(channel)
                            viewModel.play(channel, present: false)
                        } showSchedule: {
                            showSchedule(channel)
                        }
                        .id(channel.id)
                        .onAppear {
                            if channel.id == model.items.last?.id {
                                Task {
                                    await model.loadMore(container: modelContext.container)
                                }
                            }
                        }
                    }

                    if viewModel.isRecording {
                        Label("Stop recording to switch channel.", systemImage: "record.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(18)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .overlay {
                if !model.isLoaded {
                    ProgressView()
                } else if model.items.isEmpty {
                    ContentUnavailableView("No Channels", systemImage: "tv.slash")
                }
            }
            .task {
                await load()
                scrollToCurrent(proxy)
            }
            .onChange(of: viewModel.currentItem?.id) { _, _ in
                withAnimation(.smooth) {
                    scrollToCurrent(proxy, force: true)
                }
            }
        }
    }

    private func load() async {
        guard let importID = try? modelContext.fetch(HomeQueries.playlist(uuid: item.playlistID)).first?.currentImportID else {
            return
        }
        let request = CategoryChannelsModel.Request(importID: importID, playlistID: item.playlistID, groupName: item.groupName, order: .playlist, term: "")
        await model.load(request, container: modelContext.container)
        // Long categories: load pages until the playing channel is in the list, so it can be scrolled to.
        var pages = 0
        while !model.items.contains(where: { $0.id == item.id }), !model.reachedEnd, pages < 20 {
            await model.loadMore(container: modelContext.container)
            pages += 1
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || !didScrollToCurrent, let id = viewModel.currentItem?.id, model.items.contains(where: { $0.id == id }) else {
            return
        }
        didScrollToCurrent = true
        proxy.scrollTo(id, anchor: .center)
    }
}

private struct PlayerChannelRow: View {
    let item: ChannelItem
    let isCurrent: Bool
    let isEnabled: Bool
    let play: () -> Void
    let showSchedule: () -> Void

    @Environment(ChannelLibrary.self) private var library
    @Environment(EPGStore.self) private var epg
    @Environment(\.openChannelWindow) private var openChannelWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isFavorite = library.isFavorite(item)
        Button(action: play) {
            HStack(spacing: 10) {
                if let number = item.number {
                    ChannelNumberLabel(number: number)
                }
                ChannelLogoTile(item: item, size: CGSize(width: 58, height: 38), cornerRadius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(item.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.favorite)
                                .accessibilityHidden(true)
                        }
                    }
                    RowProgrammeInfo(item: item)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.live)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.accent.opacity(0.35))
                }
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled && !isCurrent)
        .rowHoverEffect()
        .contextMenu {
            menu(isFavorite: isFavorite)
        }
        .channelDraggable(item)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint(isCurrent ? "" : String(localized: "Plays the channel"))
    }

    /// The panel's own channel menu. Unlike `ChannelContextMenu` it has nothing that presents over the app
    /// (the schedule opens in the panel, guide matching is left out): the player covers the app, or is in a
    /// window of its own.
    @ViewBuilder
    private func menu(isFavorite: Bool) -> some View {
        Text(item.displayName)

        if !isCurrent {
            Button("Play", systemImage: "play.fill", action: play)
                .disabled(!isEnabled)
        }

        if openChannelWindow.isAvailable, item.url != nil {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                openChannelWindow(item)
            }
        }

        if item.url != nil {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star") {
                library.toggleFavorite(item)
            }
        }

        if item.kind == .live, epg.hasGuide {
            Button("Today's Schedule", systemImage: "calendar.day.timeline.left", action: showSchedule)
        }
    }
}

/// Above the Guide tab when it shows another channel than the playing one: which channel, a button that plays
/// it and one that goes back to the playing channel's guide.
private struct PlayerScheduleHeader: View {
    let item: ChannelItem
    let canPlay: Bool
    let play: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ChannelLogoTile(item: item, size: CGSize(width: 48, height: 32), cornerRadius: 7)
            Text(item.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            Button("Watch", systemImage: "play.fill", action: play)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .frame(width: 32, height: 32)
                .contentShape(.circle)
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                .disabled(!canPlay)
                .help("Watch this channel")

            Button("Back to Playing Channel", systemImage: "arrow.uturn.backward", action: close)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .frame(width: 32, height: 32)
                .contentShape(.circle)
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("Show the guide of the playing channel")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }
}

// MARK: - Guide

/// What the playing channel shows now and next, from the TV guide, by day. Upcoming programmes have Remind Me.
private struct PlayerGuideList: View {

    static let limit = 40

    let item: ChannelItem

    @Environment(EPGStore.self) private var epg
    @State private var programmes: [GuideProgramme]?

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .task(id: epg.revision) {
            guard let ref = await epg.guideRef(for: item) else {
                programmes = []
                return
            }
            programmes = await epg.upcoming(for: ref, from: .now, limit: Self.limit)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let programmes {
            if programmes.isEmpty {
                ContentUnavailableView(
                    "No Guide",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("The TV guide has nothing scheduled for this channel.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                        ForEach(days(of: programmes), id: \.day) { day in
                            Section {
                                ForEach(day.programmes) { programme in
                                    PlayerGuideRow(programme: programme, item: item, now: now)
                                }
                            } header: {
                                Text(GuideFormat.day(day.day))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct Day {
        let day: Date
        let programmes: [GuideProgramme]
    }

    private func days(of programmes: [GuideProgramme]) -> [Day] {
        let calendar = Calendar.current
        var result: [Day] = []
        for programme in programmes {
            let day = calendar.startOfDay(for: programme.start)
            if let last = result.last, last.day == day {
                result[result.count - 1] = Day(day: day, programmes: last.programmes + [programme])
            } else {
                result.append(Day(day: day, programmes: [programme]))
            }
        }
        return result
    }
}

private struct PlayerGuideRow: View {
    let programme: GuideProgramme
    let item: ChannelItem
    let now: Date

    @Environment(EPGStore.self) private var epg

    var body: some View {
        let isOnAir = programme.isOnAir(at: now)
        let isReminded = epg.reminders.isScheduled(programme)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            GuideTimeColumnText(date: programme.start)
                .font(.subheadline.monospacedDigit().weight(isOnAir ? .semibold : .regular))
                .foregroundStyle(isOnAir ? AnyShapeStyle(Theme.live) : AnyShapeStyle(.secondary))

            VStack(alignment: .leading, spacing: 4) {
                Text(programme.title)
                    .font(.subheadline.weight(isOnAir ? .semibold : .regular))
                    .lineLimit(2)
                if let detail = programme.detailLine {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isOnAir {
                    HStack(spacing: 8) {
                        ProgrammeProgressBar(progress: programme.progress(at: now), tint: Theme.live, height: 3)
                        Text(GuideFormat.remaining(programme, at: now))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isReminded {
                Image(systemName: "bell.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Reminder set")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if isOnAir {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.08))
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if !isOnAir, ReminderCenter.canRemind(programme, now: now) {
                Button(isReminded ? "Cancel Reminder" : "Remind Me", systemImage: isReminded ? "bell.slash" : "bell") {
                    Task {
                        await epg.reminders.toggle(programme, on: item)
                    }
                }
            }
        }
    }
}

#Preview {
    HStack(spacing: 0) {
        Color.black
        PlayerSidePanel(viewModel: AVPlayerViewModel()) {}
            .frame(width: PlayerSidePanelLayout.width)
    }
    .background(.black)
    .environment(\.colorScheme, .dark)
    .fluxoPreviewEnvironment(GuidePreviewData.container)
}
