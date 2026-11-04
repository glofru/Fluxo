//
//  PlayerCompanionPanel.swift
//  Fluxo
//
//  The second pane of the player on a foldable iPhone (see `DisplayPosture` and `PlayerPaneLayout`): while the
//  video plays on one half of the display, the other half shows what is playing, the other channels of its
//  category (a tap switches to one, without leaving the player) and the channel's schedule from the TV guide.
//

import SwiftData
import SwiftUI

/// The player's top bar button that shows or hides the second pane; set by `WatchChannelView`.
struct PlayerSplitControl {
    /// The display divides (a foldable iPhone, open): the button shows.
    var isAvailable = false
    var isShown = false
    /// The panes are one above the other (the phone stands like a laptop).
    var isStacked = false
    var toggle: () -> Void = {}
}

extension EnvironmentValues {
    @Entry var playerSplitControl = PlayerSplitControl()
}

struct PlayerCompanionPanel: View {

    enum Section: String, CaseIterable, Identifiable {
        case channels
        case schedule

        var id: String {
            rawValue
        }
    }

    /// The surface of the panel (and of the lower half of the stacked player).
    static let background = Color(white: 0.08)

    let viewModel: AVPlayerViewModel
    /// The channel, its programme and its category on top (off when the controls sit right above the panel).
    var showsHeader = true
    /// Which side of the video the panel is on: the button that swaps them points the other way.
    var videoEdge: HorizontalEdge = .leading
    var onSwapSides: (() -> Void)?

    @Environment(EPGStore.self) private var epg
    @State private var section: Section = .channels

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                PlayerCompanionHeader(viewModel: viewModel, videoEdge: videoEdge, onSwapSides: onSwapSides)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }

            if showsSchedule {
                Picker("Show", selection: $section) {
                    Text(channelsTitle).tag(Section.channels)
                    Text("Schedule").tag(Section.schedule)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else {
                Text(channelsTitle)
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
            }

            switch showsSchedule ? section : .channels {
            case .channels:
                PlayerCompanionChannelList(viewModel: viewModel)
            case .schedule:
                if let item = viewModel.currentItem {
                    PlayerCompanionSchedule(item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Self.background
                .ignoresSafeArea()
        }
        .onChange(of: showsSchedule) { _, shows in
            if !shows {
                section = .channels
            }
        }
    }

    /// Live channels with a guide have a schedule.
    private var showsSchedule: Bool {
        viewModel.currentItem?.kind == .live && epg.hasGuide
    }

    private var channelsTitle: LocalizedStringKey {
        viewModel.currentItem?.kind == .live ? "Channels" : "More in This Category"
    }
}

// MARK: - Header

private struct PlayerCompanionHeader: View {
    let viewModel: AVPlayerViewModel
    let videoEdge: HorizontalEdge
    let onSwapSides: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let item = viewModel.currentItem {
                ChannelLogoTile(item: item, size: CGSize(width: 64, height: item.kind.usesPosterArtwork ? 96 : 42), cornerRadius: 10)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Now Playing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.lilac)
                    .textCase(.uppercase)
                Text(viewModel.currentChannel?.name ?? String(localized: "No channel"))
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let group = viewModel.currentItem?.groupName, !group.isEmpty {
                    Text(group)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                PlayerProgrammeInfo(item: viewModel.currentItem)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("player.companion.nowPlaying")

            if let onSwapSides {
                Button(action: onSwapSides) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(videoEdge == .leading ? "Move Video to the Right" : "Move Video to the Left")
                .help("Swap the video and this panel")
            }
        }
    }
}

// MARK: - Channels

/// The channels of the playing channel's category, in playlist order, the playing one marked. A tap plays one
/// in the player (like channel up / down); while recording, switching is disabled (it would end the recording).
private struct PlayerCompanionChannelList: View {
    let viewModel: AVPlayerViewModel

    @Environment(\.modelContext) private var modelContext
    @Environment(ChannelLibrary.self) private var library
    @State private var model = CategoryChannelsModel()

    var body: some View {
        Group {
            if let item = viewModel.currentItem {
                list(current: item)
                    .task(id: RequestKey(playlistID: item.playlistID, groupName: item.groupName)) {
                        await load(item)
                    }
            } else {
                ContentUnavailableView("Not in a Playlist", systemImage: "list.bullet", description: Text("Channels of the same category show here when you play one from a playlist."))
            }
        }
    }

    private struct RequestKey: Hashable {
        let playlistID: UUID
        let groupName: String
    }

    @ViewBuilder
    private func list(current: ChannelItem) -> some View {
        if model.isLoaded {
            ScrollViewReader { proxy in
                List {
                    if viewModel.isRecording {
                        Label("Stop recording to switch channel.", systemImage: "record.circle")
                            .font(.footnote)
                            .foregroundStyle(Theme.recording)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(model.items) { item in
                        PlayerCompanionChannelRow(item: item, isCurrent: Self.isSame(item, current), isEnabled: !viewModel.isRecording) {
                            library.recordWatch(item)
                            viewModel.play(item, present: false)
                        }
                        .id(item.id)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowSeparator(.hidden)
                        .onAppear {
                            if item.id == model.items.last?.id {
                                Task {
                                    await model.loadMore(container: modelContext.container)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("player.companion.channels")
                .onAppear {
                    scrollToCurrent(current, proxy: proxy, animated: false)
                }
                .onChange(of: current.id) {
                    scrollToCurrent(current, proxy: proxy, animated: true)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func scrollToCurrent(_ current: ChannelItem, proxy: ScrollViewProxy, animated: Bool) {
        guard let match = model.items.first(where: { Self.isSame($0, current) }) else {
            return
        }
        if animated {
            withAnimation(.smooth) {
                proxy.scrollTo(match.id, anchor: .center)
            }
        } else {
            proxy.scrollTo(match.id, anchor: .center)
        }
    }

    /// Favorites and the history keep the row UUID they were made from, which a refresh replaces: the stream
    /// URL identifies the channel too.
    private static func isSame(_ lhs: ChannelItem, _ rhs: ChannelItem) -> Bool {
        lhs.id == rhs.id || (lhs.url != nil && lhs.url == rhs.url && lhs.playlistID == rhs.playlistID)
    }

    private func load(_ item: ChannelItem) async {
        let container = modelContext.container
        guard let importID = try? modelContext.fetch(HomeQueries.playlist(uuid: item.playlistID)).first?.currentImportID else {
            return
        }
        let request = CategoryChannelsModel.Request(importID: importID, playlistID: item.playlistID, groupName: item.groupName, order: .playlist, term: "")
        guard model.request != request else {
            return
        }
        await model.load(request, container: container)
        // The playing channel may be further down than the first page.
        if let number = item.number, number > model.items.count {
            await model.ensureLoaded(offset: min(number, model.items.count + 2 * CategoryChannelsModel.pageSize), container: container)
        }
    }
}

private struct PlayerCompanionChannelRow: View {
    let item: ChannelItem
    let isCurrent: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if !isCurrent {
                action()
            }
        } label: {
            HStack(spacing: 12) {
                if let number = item.number {
                    ChannelNumberLabel(number: number)
                }
                ChannelLogoTile(item: item, size: item.kind.usesPosterArtwork ? CGSize(width: 36, height: 54) : CGSize(width: 60, height: 40), cornerRadius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if item.kind == .live {
                        RowProgrammeInfo(item: item)
                    } else {
                        WatchProgressLine(item: item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.lilac)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accent.opacity(0.28))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.lilac.opacity(0.45))
                        }
                }
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        // The playing row stays at full strength (a disabled button would be dimmed); a tap on it does nothing.
        .disabled(!isEnabled && !isCurrent)
        .opacity(isEnabled || isCurrent ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.companion.channel")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint(isCurrent ? "" : String(localized: "Plays this channel"))
    }
}

// MARK: - Schedule

/// The next programmes of the playing channel; a tap shows a programme's details (and its reminder).
private struct PlayerCompanionSchedule: View {
    static let programmeLimit = 30

    let item: ChannelItem

    @Environment(EPGStore.self) private var epg
    @State private var ref: GuideChannelRef?
    @State private var programmes: [GuideProgramme]?
    @State private var detail: GuideProgramme?

    var body: some View {
        Group {
            if let programmes {
                if programmes.isEmpty {
                    ContentUnavailableView("No Programmes", systemImage: "calendar.badge.exclamationmark", description: Text("The TV guide has nothing scheduled for this channel."))
                } else {
                    TimelineView(.everyMinute) { context in
                        List(programmes) { programme in
                            row(programme, now: context.date)
                                .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ScheduleKey(item: item, revision: epg.revision)) {
            let ref = await epg.guideRef(for: item)
            self.ref = ref
            if let ref {
                programmes = await epg.upcoming(for: ref, from: .now, limit: Self.programmeLimit)
            } else {
                programmes = []
            }
        }
        .sheet(item: $detail) { programme in
            ProgrammeDetailView(programme: programme, channel: item, ref: ref)
        }
    }

    private struct ScheduleKey: Equatable {
        let item: ChannelItem
        let revision: Int
    }

    private func row(_ programme: GuideProgramme, now: Date) -> some View {
        let isOnAir = programme.isOnAir(at: now)
        return Button {
            detail = programme
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // As wide as the widest time, so the titles line up.
                GuideTimeColumnText(date: programme.start)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isOnAir ? AnyShapeStyle(Theme.live) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if isOnAir {
                            LiveBadge(compact: true)
                        }
                        Text(programme.title)
                            .font(.subheadline.weight(isOnAir ? .semibold : .regular))
                            .lineLimit(2)
                    }
                    if isOnAir {
                        ProgrammeProgressBar(progress: programme.progress(at: now), tint: Theme.live, height: 3)
                    } else if let detailLine = programme.detailLine {
                        Text(detailLine)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if epg.reminders.isScheduled(programme) {
                    Image(systemName: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.lilac)
                        .accessibilityLabel("Reminder set")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Companion panel") {
    PlayerCompanionPanel(viewModel: AVPlayerViewModel(), onSwapSides: {})
        .frame(width: 470, height: 660)
        .environment(\.colorScheme, .dark)
        .fluxoPreviewEnvironment()
}
