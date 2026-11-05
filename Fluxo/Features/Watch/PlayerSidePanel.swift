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

// The touch and pointer player screen (iPhone, iPad, Mac). Apple TV plays in the system's player, whose transport bar the Siri Remote drives (Fluxo/TV).
#if !os(tvOS)
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
    /// Bumped by the player's guide control: the Guide tab goes back to the playing channel, at now.
    var guideRequest = 0
    let close: () -> Void

    @AppStorage(PlayerSidePanelLayout.tabStorageKey) private var tab: PlayerSidePanelTab = .channels
    /// The channel whose schedule the Guide tab shows instead of the playing one ("Today's Schedule" in the menu
    /// of a channel row). The schedule opens here, in the panel: the app's schedule sheet and inspector are under
    /// the player, or in another window.
    @State private var scheduleItem: ChannelItem?
    /// A programme of the Guide tab whose details show.
    @State private var detail: PlayerScheduleSelection?
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
                    } else {
                        PlayerGuideTabHeader(item: item)
                    }
                    let guideItem = scheduleItem ?? item
                    PlayerChannelSchedule(item: guideItem, scrollToNowRequest: guideRequest) { selection in
                        detail = selection
                    }
                    .id(guideItem.id)
                    .sheet(item: $detail) { selection in
                        ProgrammeDetailView(programme: selection.programme, channel: guideItem, ref: selection.ref)
                    }
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
        .onChange(of: guideRequest) {
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
                        .foregroundStyle(Theme.secondaryText)
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
                            .foregroundStyle(Theme.secondaryText)
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
        if item.series != nil {
            // An episode: the other episodes of its series.
            await model.loadEpisodes(of: item, container: modelContext.container)
            return
        }
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
                        .ambientSymbolEffect(.variableColor.iterative)
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

        if StreamLink(item.url) != nil {
            Divider()
            ChannelLinkMenuItems(item: item)
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
                .glassEffect(.regular.tint(Theme.accentFill).interactive(), in: .circle)
                .disabled(!canPlay)
                .help("Watch this channel")

            PlayerFullGuideButton(item: item, iconOnly: true)

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

/// Above the Guide tab for the playing channel: its name, and Full Guide (the app's TV guide at this channel).
private struct PlayerGuideTabHeader: View {
    let item: ChannelItem

    var body: some View {
        HStack(spacing: 10) {
            Text(item.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            PlayerFullGuideButton(item: item)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
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
#endif
