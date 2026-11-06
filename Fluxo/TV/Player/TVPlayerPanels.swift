//
//  TVPlayerPanels.swift
//  Fluxo
//
//  What the Apple TV player adds to the system's info panel (a swipe down on the clickpad shows its tabs, next to
//  the system's Info tab), and the full-screen card of a channel change:
//  - Channels: the other channels of the playing channel's category, each with what it shows now; selecting one
//    switches to it (not while recording: that would end the recording);
//  - Guide: what is on the playing channel now (with its progress) and next, from the TV guide; selecting a programme
//    still to come sets or removes its reminder, selecting the one on now goes back live or plays it from its start
//    (when the time-shift window allows);
//  - Episodes: the other episodes of the playing episode's series; selecting one plays it.
//  Rows are shelves of focusable cards, sized for the 10-foot UI and readable over the panel's dark material.
//

#if os(tvOS)
import SwiftData
import SwiftUI

/// The content of one tab of the info panel.
struct TVPlayerTabContent: View {

    let tab: TVPlayerChrome.Tab
    let viewModel: AVPlayerViewModel

    /// The height of the tab (the info panel limits it).
    static func height(of tab: TVPlayerChrome.Tab) -> CGFloat {
        switch tab {
        case .channels, .episodes:
            return 380
        case .guide:
            return 360
        }
    }

    var body: some View {
        Group {
            if let item = viewModel.currentItem {
                switch tab {
                case .channels:
                    TVPlayerChannelsShelf(viewModel: viewModel, item: item)
                        .id(GroupKey(playlistID: item.playlistID, groupName: item.groupName))
                case .episodes:
                    TVPlayerChannelsShelf(viewModel: viewModel, item: item)
                        .id(item.series?.seriesKey)
                case .guide:
                    TVPlayerGuideShelf(viewModel: viewModel, item: item)
                        .id(item.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct GroupKey: Hashable {
        let playlistID: UUID
        let groupName: String
    }
}

// MARK: - Channels and episodes

/// The channels of the playing channel's category, or the episodes of its series, as a shelf scrolled to the one
/// that plays.
private struct TVPlayerChannelsShelf: View {

    let viewModel: AVPlayerViewModel
    let item: ChannelItem

    @Environment(\.modelContext) private var modelContext
    @Environment(ChannelLibrary.self) private var library
    @State private var model = CategoryChannelsModel()
    /// The panel opens on the card of what plays.
    @FocusState private var focusedID: UUID?

    private var isEpisodes: Bool {
        item.series != nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(model.items) { channel in
                        TVPlayerChannelCard(
                            item: channel,
                            isCurrent: channel.id == viewModel.currentItem?.id,
                            isEnabled: !viewModel.isRecording
                        ) {
                            library.recordWatch(channel)
                            viewModel.play(channel, present: false)
                        }
                        .id(channel.id)
                        .focused($focusedID, equals: channel.id)
                        .onAppear {
                            if channel.id == model.items.last?.id {
                                Task {
                                    await model.loadMore(container: modelContext.container)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .defaultFocus($focusedID, viewModel.currentItem?.id)
            .overlay {
                if !model.isLoaded {
                    ProgressView()
                } else if model.items.isEmpty {
                    Text(isEpisodes
                        ? String(localized: "No other episodes.", comment: "Apple TV player, Episodes tab: the series has no other episode.")
                        : String(localized: "No other channels in this category.", comment: "Apple TV player, Channels tab (and the channel change card): the category has no other channel."))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if viewModel.isRecording && !isEpisodes {
                    Label("Stop recording to switch channel.", systemImage: "record.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 90)
                        .padding(.bottom, 6)
                }
            }
            .task {
                await load()
                if let id = viewModel.currentItem?.id {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: viewModel.currentItem?.id) { _, id in
                if let id {
                    withAnimation(.smooth) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .focusSection()
    }

    private func load() async {
        if isEpisodes {
            await model.loadEpisodes(of: item, container: modelContext.container)
            return
        }
        guard let importID = try? modelContext.fetch(HomeQueries.playlist(uuid: item.playlistID)).first?.currentImportID else {
            return
        }
        let request = CategoryChannelsModel.Request(importID: importID, playlistID: item.playlistID, groupName: item.groupName, order: .playlist, term: "")
        await model.load(request, container: modelContext.container)
        // Long categories: load pages until the playing channel is in the shelf, so it can be scrolled to.
        var pages = 0
        while !model.items.contains(where: { $0.id == item.id }), !model.reachedEnd, pages < 20 {
            await model.loadMore(container: modelContext.container)
            pages += 1
        }
    }
}

/// A channel (its logo and what is on now) or an episode (its artwork and code) of the shelf.
private struct TVPlayerChannelCard: View {

    static let artworkSize = CGSize(width: 352, height: 198)

    let item: ChannelItem
    let isCurrent: Bool
    let isEnabled: Bool
    let play: () -> Void

    var body: some View {
        NowNextReader(item: item.kind == .live ? item : nil) { nowNext in
            Button(action: play) {
                VStack(alignment: .leading, spacing: 0) {
                    TVLandscapeArtwork(item: item, size: Self.artworkSize)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            if isCurrent {
                                Image(systemName: "waveform")
                                    .foregroundStyle(Theme.cyan)
                                    .symbolEffect(.variableColor.iterative, options: .repeating)
                                    .accessibilityHidden(true)
                            }
                            Text(title)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                        }
                        if let line = subtitle(nowNext) {
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let programme = nowNext?.current {
                            TimelineView(.everyMinute) { context in
                                ProgressView(value: programme.progress(at: context.date))
                                    .tint(Theme.live)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .frame(width: Self.artworkSize.width - 32, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    // Readable over any picture: the info panel's material lets bright video through.
                    .background(.black.opacity(0.5))
                }
            }
            .buttonStyle(.card)
            .disabled(!isEnabled && !isCurrent)
            .accessibilityLabel(Text(TextParts.line([title, subtitle(nowNext)])))
            .accessibilityValue(isCurrent ? Text("Now Playing") : Text(verbatim: ""))
            .accessibilityHint(isCurrent ? Text(verbatim: "") : Text(TVText.playsHint(for: item)))
        }
    }

    private var title: String {
        if let ref = item.series {
            return TextParts.line([EpisodeFormat.code(ref), ref.episodeTitle])
        }
        if let number = item.number {
            return TextParts.line([String(number), item.displayName])
        }
        return item.displayName
    }

    private func subtitle(_ nowNext: NowNext?) -> String? {
        if let current = nowNext?.current {
            return current.title
        }
        if item.series != nil {
            return item.series?.seriesTitle
        }
        return nil
    }
}

// MARK: - Guide

/// What is on the playing channel now and next.
private struct TVPlayerGuideShelf: View {

    static let upcomingLimit = 12

    let viewModel: AVPlayerViewModel
    let item: ChannelItem

    @Environment(EPGStore.self) private var epg
    @State private var programmes: [GuideProgramme]?

    private struct LoadKey: Equatable {
        let item: ChannelItem
        let revision: Int
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .task(id: LoadKey(item: item, revision: epg.revision)) {
            guard let ref = await epg.guideRef(for: item) else {
                programmes = []
                return
            }
            programmes = await epg.upcoming(for: ref, from: .now, limit: Self.upcomingLimit)
        }
        .focusSection()
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let programmes {
            let shown = programmes.filter { $0.stop > now }
            if shown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Programmes")
                        .font(.headline)
                    Text("The TV guide has nothing scheduled for this channel.")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 40)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(shown) { programme in
                            TVPlayerProgrammeCard(viewModel: viewModel, programme: programme, item: item, now: now)
                        }
                    }
                    .padding(.horizontal, 90)
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A programme of the guide shelf: when, what, and its description. One still to come sets or removes its
/// reminder when selected. The one on now goes back to the live broadcast when playback is behind it, or plays it from
/// its start when the time-shift window reaches back that far; with neither, selecting it does nothing (it still takes
/// the focus).
private struct TVPlayerProgrammeCard: View {

    static let size = CGSize(width: 560, height: 236)

    let viewModel: AVPlayerViewModel
    let programme: GuideProgramme
    let item: ChannelItem
    let now: Date

    @Environment(EPGStore.self) private var epg

    /// What selecting the card does.
    private enum Action {
        case reminder(isSet: Bool)
        case goLive
        case watchFromStart
    }

    private var action: Action? {
        guard programme.isOnAir(at: now) else {
            return .reminder(isSet: epg.reminders.isScheduled(programme))
        }
        // More than a few seconds behind the live edge, as for the Go Live button over the video.
        if viewModel.timeBehindLiveEdge > 10 {
            return .goLive
        }
        // Not when it started moments ago: the live picture is its start.
        if now.timeIntervalSince(programme.start) > 60, viewModel.canWatchLive(from: programme.start) {
            return .watchFromStart
        }
        return nil
    }

    var body: some View {
        let action = action
        // Always a card that takes the focus, even when selecting it does nothing (the programme on now at the live
        // edge): after Go Live the focus stays on it instead of jumping to the next programme, and the shelf reads the
        // same whichever programme plays.
        Button {
            if let action {
                perform(action)
            }
        } label: {
            card(action: action)
        }
        .buttonStyle(.card)
        .accessibilityElement(children: .combine)
        .accessibilityRemoveTraits(action == nil ? .isButton : [])
        .accessibilityHint(action.map(hint) ?? Text(verbatim: ""))
        .accessibilityLabel(Text(TextParts.line([programme.title, programme.isOnAir(at: now) ? String(localized: "On now") : GuideFormat.timeRange(programme)])))
        .accessibilityValue(epg.reminders.isScheduled(programme) ? Text("Reminder set") : Text(verbatim: ""))
    }

    private func card(action: Action?) -> some View {
        let isOnAir = programme.isOnAir(at: now)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if isOnAir {
                    Text("Now")
                        .font(.caption.weight(.heavy))
                        .textCase(.uppercase)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Theme.liveFill, in: .capsule)
                        .foregroundStyle(.white)
                }
                Text(isOnAir ? GuideFormat.remaining(programme, at: now) : GuideFormat.timeRange(programme))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                switch action {
                case .reminder(isSet: true):
                    Image(systemName: "bell.fill")
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                case .goLive:
                    Label("Go Live", systemImage: "forward.end.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                case .watchFromStart:
                    Label {
                        Text("From the Start", comment: "Apple TV player, Guide tab: on the card of the programme on now, selecting it plays the programme from its start (time-shifted live channels).")
                    } icon: {
                        Image(systemName: "backward.end.fill")
                    }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                case .reminder(isSet: false), nil:
                    EmptyView()
                }
            }
            Text(programme.title)
                .font(.headline)
                .lineLimit(1)
            if let line = programme.detailLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !programme.summary.isEmpty {
                Text(programme.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if isOnAir {
                TVProgrammeProgress(
                    live: programme.progress(at: now),
                    // Behind the live edge (time shift): where the picture is, over how far the broadcast is.
                    playhead: viewModel.timeBehindLiveEdge > 10 ? programme.progress(at: now.addingTimeInterval(-viewModel.timeBehindLiveEdge)) : nil
                )
            }
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        // Readable over any picture: the info panel's material lets bright video through.
        .background(.black.opacity(0.5))
    }

    private func perform(_ action: Action) {
        switch action {
        case .reminder:
            Task {
                await epg.reminders.toggle(programme, on: item)
            }
        case .goLive:
            viewModel.goLive()
        case .watchFromStart:
            viewModel.watchLive(from: programme.start)
        }
    }

    private func hint(_ action: Action) -> Text {
        switch action {
        case .reminder(isSet: true):
            return Text("Removes the reminder", comment: "VoiceOver hint of a programme still to come in the Apple TV player's Guide tab, when its reminder is set.")
        case .reminder(isSet: false):
            return Text("Sets a reminder", comment: "VoiceOver hint of a programme still to come in the Apple TV player's Guide tab.")
        case .goLive:
            return Text("Returns to the live broadcast", comment: "VoiceOver hint of the programme on now in the Apple TV player's Guide tab, when playback is behind the live broadcast.")
        case .watchFromStart:
            return Text("Plays the programme from its start", comment: "VoiceOver hint of the programme on now in the Apple TV player's Guide tab, when the channel's time-shift window reaches its start.")
        }
    }
}

// MARK: - Channel change

/// The full-screen card AVKit shows while the channel changes (channel up / down), until the new channel plays: its
/// logo, number and name, and what it shows now.
struct TVChannelInterstitial: View {

    /// nil: there is no channel to go to.
    let item: ChannelItem?
    let isRecording: Bool

    var body: some View {
        ZStack {
            Color.black
            Theme.brandGradient
                .opacity(0.35)
            if let item {
                NowNextReader(item: item) { nowNext in
                    VStack(spacing: 28) {
                        TVLandscapeArtwork(item: item, size: CGSize(width: 480, height: 270))
                            .clipShape(.rect(cornerRadius: 24, style: .continuous))
                            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                        VStack(spacing: 10) {
                            Text(item.number.map { TextParts.line([String($0), item.displayName]) } ?? item.displayName)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                            if let current = nowNext?.current {
                                Text(TextParts.line([current.title, GuideFormat.timeRange(current)]))
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            } else if !item.groupName.isEmpty {
                                Text(item.groupName)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                    .padding(80)
                    .frame(maxWidth: 1_200)
                    .accessibilityElement(children: .combine)
                }
            } else {
                Label(isRecording ? String(localized: "Stop recording to switch channel.") : String(localized: "No other channels in this category.", comment: "Apple TV player, Channels tab (and the channel change card): the category has no other channel."), systemImage: isRecording ? "record.circle" : "tv.slash")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}
/// The progress of the programme on now: how far the broadcast is, and, behind the live edge, how far the picture is
/// (brighter, over the broadcast's), as the transport bar of a time-shifted channel shows them.
private struct TVProgrammeProgress: View {
    let live: Double
    let playhead: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                Capsule()
                    .fill(playhead == nil ? AnyShapeStyle(Theme.live) : AnyShapeStyle(.white.opacity(0.4)))
                    .frame(width: proxy.size.width * live)
                if let playhead {
                    Capsule()
                        .fill(Theme.live)
                        .frame(width: proxy.size.width * playhead)
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
#endif
