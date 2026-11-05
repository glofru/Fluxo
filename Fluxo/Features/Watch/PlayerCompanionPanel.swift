//
//  PlayerCompanionPanel.swift
//  Fluxo
//
//  The second pane of the player on a foldable iPhone (see `DisplayPosture` and `PlayerPaneLayout`): while the
//  video plays on one half of the display, the other half shows what is playing, the other channels of its
//  category (a tap switches to one, without leaving the player) and the channel's schedule from the TV guide.
//

// The touch and pointer player screen (iPhone, iPad, Mac). Apple TV plays in the system's player, whose transport bar the Siri Remote drives (Fluxo/TV).
#if !os(tvOS)
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
    /// Channels or schedule; owned by the player, whose guide control switches it to the schedule.
    @Binding var section: Section
    /// The channel, its programme and its category on top (off when the controls sit right above the panel).
    var showsHeader = true
    /// Which side of the video the panel is on: the button that swaps them points the other way.
    var videoEdge: HorizontalEdge = .leading
    var onSwapSides: (() -> Void)?

    @Environment(EPGStore.self) private var epg

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
                    HStack {
                        Spacer(minLength: 0)
                        PlayerFullGuideButton(item: item)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    PlayerCompanionSchedule(item: item)
                        .id(item.id)
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

    @Environment(\.layoutDirection) private var layoutDirection

    /// Whether the video is on the left of the screen: the panes are placed by leading / trailing edge, which
    /// is the right in a right-to-left language.
    private var isVideoOnTheLeft: Bool {
        (videoEdge == .leading) == (layoutDirection == .leftToRight)
    }

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
                .accessibilityLabel(isVideoOnTheLeft ? "Move Video to the Right" : "Move Video to the Left")
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
        if item.series != nil {
            // An episode: the other episodes of its series.
            if model.request?.groupName != "series|\(item.series?.seriesKey ?? "")" {
                await model.loadEpisodes(of: item, container: container)
            }
            return
        }
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
                        .ambientSymbolEffect(.variableColor.iterative)
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

/// The schedule of the playing channel, at now; a tap shows a programme's details (and its reminder).
private struct PlayerCompanionSchedule: View {
    let item: ChannelItem

    @State private var detail: PlayerScheduleSelection?

    var body: some View {
        PlayerChannelSchedule(item: item) { selection in
            detail = selection
        }
        .sheet(item: $detail) { selection in
            ProgrammeDetailView(programme: selection.programme, channel: item, ref: selection.ref)
        }
    }
}

#Preview("Companion panel") {
    @Previewable @State var section = PlayerCompanionPanel.Section.channels
    PlayerCompanionPanel(viewModel: AVPlayerViewModel(), section: $section, onSwapSides: {})
        .frame(width: 470, height: 660)
        .environment(\.colorScheme, .dark)
        .fluxoPreviewEnvironment()
}
#endif
