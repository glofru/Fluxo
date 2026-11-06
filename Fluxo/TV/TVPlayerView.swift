//
//  TVPlayerView.swift
//  Fluxo
//
//  The player on Apple TV: the system's `AVPlayerViewController` on the app's single `AVPlayer` (`TVSystemPlayer`),
//  for every route: HLS AVPlayer plays directly, the remux engine's on-demand and live HLS on the loopback address,
//  the time-shift window of live channels, recordings and downloads. Its transport bar is the one Apple TV users
//  know: the clickpad scrubs and skips, Play/Pause, the Audio and Subtitles menus, Picture in Picture, the info
//  panel on a swipe down. Everything else (routing, reconnection, time shift, recording, watch progress and resume)
//  is the shared `AVPlayerViewModel`.
//
//  This view describes what the system player shows besides the video, from the app's state (`TVPlayerChrome`):
//  - the transport bar: Record / Stop Recording (live channels through the engine) and Picture (fit or fill);
//  - the info panel: the Info tab (the programme on now from the TV guide, or the movie or episode, with its
//    artwork), Add to Favorites and Start Over, and the tabs Channels, Guide and Episodes (`TVPlayerPanels`);
//  - contextual actions over the video: Go Live when behind the live edge, Next Episode during the end credits,
//    Try Again after a seek that could not play;
//  and draws what the system does not (`TVPlayerOverlays`): the channel before the first frame, failures and the end
//  of a video (with the next episode's countdown), which take the focus, and the channel banner, Reconnecting… and
//  the recording while the transport bar is hidden. Menu while recording asks first (Stop Recording or Keep
//  Recording), since closing the player stops the recording.
//

#if os(tvOS)
import AVKit
import SwiftData
import SwiftUI

struct TVPlayerView: View {

    let viewModel: AVPlayerViewModel

    @Environment(ChannelLibrary.self) private var library
    @Environment(EPGStore.self) private var epg
    @Environment(\.modelContext) private var modelContext
    @Environment(\.playChannel) private var playChannel
    @Environment(\.accessibilityEnabled) private var isAssistiveTechnologyEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @State private var resolver = NextEpisodeResolver.shared
    @State private var systemPlayer = TVSystemPlayer.shared
    /// The episode whose next-episode countdown was cancelled: it shows its end screen instead.
    @State private var cancelledCountdownFor: ChannelItem?
    /// The channel switched to while the player is up, shown in the banner for a few seconds.
    @State private var bannerItem: ChannelItem?
    /// The channel whose first picture showed (or that played a few seconds without one: audio only). Until then the
    /// preroll covers the black screen; after it, buffering (a seek, a stall, an item replaced to recover a seek)
    /// shows the system's spinner over the picture.
    @State private var startedChannel: PlayableChannel.ID?
    /// Go Live shows over the video for a few seconds (see `GoLiveKey`).
    @State private var offersGoLive = false
    /// The channel Go Live showed for since playback fell behind with the transport bar hidden.
    @State private var goLiveOfferedFor: PlayableChannel.ID?

    var body: some View {
        NowNextReader(item: viewModel.currentItem) { nowNext in
            let overlay = overlay
            SystemPlayer(
                viewModel: viewModel,
                services: TVPlayerServices(library: library, epg: epg, modelContainer: modelContext.container, playChannel: playChannel),
                chrome: chrome(nowNext: nowNext, overlay: overlay)
            )
            .ignoresSafeArea()
            .overlay {
                overlayView(overlay, nowNext: nowNext)
                    .transition(.opacity)
            }
            .overlay(alignment: .topLeading) {
                if let bannerItem, !systemPlayer.isTransportBarVisible, overlay == .none {
                    TVChannelBanner(item: bannerItem, nowNext: bannerItem == viewModel.currentItem ? nowNext : nil)
                        .padding(.leading, 80)
                        .padding(.top, 60)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                statusPills(overlay)
                    .padding(.trailing, 80)
                    .padding(.top, 60)
            }
            .animation(.easeInOut(duration: 0.3), value: overlay)
            .animation(.easeInOut(duration: 0.3), value: bannerItem)
            .animation(.easeInOut(duration: 0.25), value: systemPlayer.isTransportBarVisible)
        }
        // Menu while recording (`TVSystemPlayer.isConfirmingClose`): closing the player would stop the recording.
        .alert(String(localized: "TV.player.stopRecording.title", defaultValue: "Stop Recording?", comment: "Apple TV player: title of the alert when Menu is pressed to close the player while the live channel is being recorded."), isPresented: confirmsClose) {
            Button(String(localized: "Stop Recording")) {
                // The viewer is the one moving: nothing is kept for them (as Menu in `TVContentView`).
                navigation?.releaseKeptTab()
                // Closing stops playback; the recording is finished and saved in Library.
                viewModel.closePlayer()
            }
            Button(String(localized: "TV.player.keepRecording", defaultValue: "Keep Recording", comment: "Apple TV player: the button of the Stop Recording? alert that goes back to the player and keeps recording."), role: .cancel) {}
        } message: {
            Text(String(localized: "TV.player.stopRecording.message", defaultValue: "Closing the player stops the recording. What was recorded so far is saved in Library.", comment: "Apple TV player: message of the alert when Menu is pressed while the live channel is being recorded."))
        }
        .onChange(of: viewModel.isRecording) { _, isRecording in
            // The recording ended by itself (the stream failed, the disk is full): nothing to confirm any more.
            if !isRecording {
                systemPlayer.isConfirmingClose = false
            }
        }
        .onChange(of: viewModel.currentItem, initial: true) { old, item in
            resolver.resolve(after: item, container: modelContext.container)
            // A channel change inside the player (the Channels tab, channel up / down): its banner.
            if let item, item.kind == .live, old != nil, old != item {
                bannerItem = item
            }
        }
        .onChange(of: systemPlayer.readyForDisplayCount, initial: true) {
            // Each first frame (of every item, however fast after the last one: the count moves on even when SwiftUI
            // sees "ready" before and after). Initially: the picture already showing (back from Picture in Picture).
            if systemPlayer.isReadyForDisplay, viewModel.player.currentItem != nil {
                startedChannel = viewModel.currentChannel?.id
            }
        }
        .task(id: StartKey(channel: viewModel.currentChannel?.id, isPlaying: viewModel.playbackState == .playing)) {
            // Playing for a few seconds without a first frame seen: audio only, or a picture AVKit did not report.
            // The preroll gives way anyway, whatever the readiness says: it never covers what plays for long.
            guard viewModel.playbackState == .playing, startedChannel != viewModel.currentChannel?.id else {
                return
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else {
                return
            }
            startedChannel = viewModel.currentChannel?.id
        }
        .task(id: goLiveKey) {
            // A contextual action takes the focus: Select would go live and the info panel would not open for as long
            // as it shows. So, like Skip Intro in the TV app, it shows for a few seconds once playback runs behind
            // the live edge with the transport bar hidden, not while paused, and once only until the bar shows again
            // or playback catches up (a stall of a flaky stream, buffering then playing, does not bring it back). The
            // Guide tab's programme on now goes live at any time.
            let key = goLiveKey
            guard key.isBehind, !key.isTransportBarVisible else {
                // The next time the bar hides behind the live edge, it shows again.
                offersGoLive = false
                goLiveOfferedFor = nil
                return
            }
            guard key.isRunning, goLiveOfferedFor != key.channel else {
                offersGoLive = false
                return
            }
            goLiveOfferedFor = key.channel
            offersGoLive = true
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else {
                return
            }
            offersGoLive = false
        }
        .task(id: BannerKey(item: bannerItem, isPlaying: viewModel.playbackState == .playing)) {
            // Five seconds over the new channel's first pictures (not while it still connects).
            guard bannerItem != nil, viewModel.playbackState == .playing else {
                return
            }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else {
                return
            }
            bannerItem = nil
        }
    }

    // MARK: - State

    private var confirmsClose: Binding<Bool> {
        Binding {
            systemPlayer.isConfirmingClose
        } set: { isPresented in
            systemPlayer.isConfirmingClose = isPresented
        }
    }

    private struct StartKey: Equatable {
        let channel: PlayableChannel.ID?
        let isPlaying: Bool
    }

    private struct GoLiveKey: Equatable {
        let channel: PlayableChannel.ID?
        let isBehind: Bool
        /// Playing, or about to again (buffering, reconnecting): not paused, stopped or failed.
        let isRunning: Bool
        let isTransportBarVisible: Bool
    }

    private var goLiveKey: GoLiveKey {
        let isRunning = switch viewModel.playbackState {
        case .playing, .buffering, .reconnecting:
            true
        case .idle, .connecting, .paused, .ended, .failed:
            false
        }
        return GoLiveKey(
            channel: viewModel.currentChannel?.id,
            isBehind: viewModel.timeBehindLiveEdge > 10,
            isRunning: isRunning,
            isTransportBarVisible: systemPlayer.isTransportBarVisible
        )
    }

    private struct BannerKey: Equatable {
        let item: ChannelItem?
        let isPlaying: Bool
    }

    /// What the player draws over the video.
    private enum Overlay: Equatable {
        case none
        /// Nothing plays yet: the channel and the player's state.
        case preroll
        /// The reason shown, and the player item's error when it is that reason (see `TVPlayerFailureText`).
        case failed(String, error: NSError?)
        /// A movie, episode or recording played to its end.
        case ended
        /// An episode ended and the next one counts down.
        case nextEpisode(ChannelItem)

        /// It has buttons: the focus moves to them and the transport bar is off.
        var takesFocus: Bool {
            switch self {
            case .failed, .ended, .nextEpisode:
                return true
            case .none, .preroll:
                return false
            }
        }
    }

    private var overlay: Overlay {
        // Until the first picture: the item may be attached (and AVPlayer may already play), but the screen is black.
        let isBeforeFirstPicture = viewModel.player.currentItem == nil || startedChannel != viewModel.currentChannel?.id
        switch viewModel.playbackState {
        case .idle, .connecting:
            return .preroll
        case .buffering where isBeforeFirstPicture, .playing where isBeforeFirstPicture:
            return .preroll
        case .failed(let message):
            let reason = viewModel.streamError ?? message
            // The item's error only while it is the reason shown (a later error replaces the message).
            return .failed(reason, error: reason == message ? viewModel.itemFailureError : nil)
        case .ended:
            if viewModel.isTimeShiftAvailable || viewModel.isCurrentChannelLiveContent {
                // A live broadcast that stopped: it may come back.
                return .failed(String(localized: "The broadcast ended.", comment: "Apple TV player: a live channel stopped sending video."), error: nil)
            }
            if let current = viewModel.currentItem, let next = resolver.next(after: current), current.series != nil, cancelledCountdownFor != current {
                return .nextEpisode(next)
            }
            return .ended
        case .buffering, .playing, .paused, .reconnecting:
            return .none
        }
    }

    private func chrome(nowNext: NowNext?, overlay: Overlay) -> TVPlayerChrome {
        let item = viewModel.currentItem
        let isLive = viewModel.isCurrentChannelLiveContent
        var chrome = TVPlayerChrome()
        chrome.showsPlaybackControls = !overlay.takesFocus
        chrome.fillsScreen = viewModel.fillsScreen
        chrome.allowsPictureInPicture = AVPictureInPictureController.isPictureInPictureSupported()
        chrome.canRecord = viewModel.canRecord
        chrome.isRecording = viewModel.isRecording
        chrome.isFavorite = item.map(library.isFavorite)
        chrome.offersStartOver = !isLive && viewModel.canSeek
        if let item {
            if item.kind == .live {
                chrome.tabs = epg.hasGuide ? [.guide, .channels] : [.channels]
            } else if item.series != nil {
                chrome.tabs = [.episodes]
            }
        }
        // More than a few seconds behind the live edge, for a few seconds (the transport bar shows the edge itself).
        chrome.offersGoLive = offersGoLive && viewModel.timeBehindLiveEdge > 10
        chrome.offersSeekRetry = viewModel.seeker.phase == .failed
        if let item, item.series != nil, !viewModel.isTimeShiftAvailable, isInEndCredits {
            chrome.nextEpisode = resolver.next(after: item)
        }
        chrome.metadata = metadata(nowNext: nowNext)
        return chrome
    }

    /// The last 3 % of an episode longer than 5 minutes (at most a minute), while it plays.
    private var isInEndCredits: Bool {
        let timeline = viewModel.timeline
        let duration = timeline.duration
        let remaining = duration - timeline.currentTime
        guard duration >= 300, viewModel.playbackState == .playing || viewModel.playbackState == .paused else {
            return false
        }
        return remaining > 1 && remaining <= min(60, duration * 0.03)
    }

    /// The title names the show and the subtitle what of it plays, since the subtitle is the Info tab's headline
    /// (see `TVPlayerChrome.Metadata`):
    /// - a live channel: "2 · Channel" over "Quiz Night · 8:00–9:00 PM · S4 E9" (the channel alone without a guide);
    /// - an episode: "Orbit" over "S1 E2 · Encore" (and "Orbit" in the Info tab's line of details);
    /// - a movie, a recording or a stream outside the library: its name alone (a recording says when it was made in
    ///   its description).
    private func metadata(nowNext: NowNext?) -> TVPlayerChrome.Metadata {
        var metadata = TVPlayerChrome.Metadata()
        guard let item = viewModel.currentItem else {
            // A recording or a stream outside the library.
            metadata.title = viewModel.currentChannel?.name ?? ""
            if let recording = TVPlayerTitle.recording(of: viewModel) {
                metadata.summary = TVPlayerTitle.recordedLine(recording)
            }
            return metadata
        }
        metadata.artwork = item.logo
        metadata.artworkIsPoster = item.kind.usesPosterArtwork
        if item.kind == .live {
            metadata.title = item.number.map { TextParts.line([EpisodeFormat.number($0), item.displayName]) } ?? item.displayName
            if let current = nowNext?.current {
                metadata.subtitle = TextParts.line([current.title, GuideFormat.timeRange(current), current.detailLine])
                var summary = current.summary
                if let next = nowNext?.next {
                    let upNext = String(localized: "Next at \(GuideFormat.time(next.start)): \(next.title)", comment: "Apple TV player, info panel: the programme after the one on now; the placeholders are its start time and title.")
                    summary = summary.isEmpty ? upNext : summary + "\n\n" + upNext
                }
                metadata.summary = summary
                // Joined with the comma of the language (、 in Japanese, ، in Arabic): AVKit separates the details of
                // this line with its own ·. Isolated, as any line that is shown.
                metadata.genre = TextParts.list(Array(current.categories.prefix(2)))
            }
        } else if let ref = item.series {
            metadata.title = ref.seriesTitle
            metadata.subtitle = TextParts.line([EpisodeFormat.code(ref), ref.episodeTitle])
            // The Info tab shows the subtitle as its headline, not the title: its line of details (with the duration)
            // names the show, as the TV app's does.
            metadata.genre = ref.seriesTitle
        } else {
            metadata.title = item.displayName
        }
        return metadata
    }

    // MARK: - Overlays

    @ViewBuilder
    private func overlayView(_ overlay: Overlay, nowNext: NowNext?) -> some View {
        switch overlay {
        case .none:
            EmptyView()
        case .preroll:
            TVPlayerPreroll(viewModel: viewModel, nowNext: nowNext)
        case .failed(let message, let error):
            TVPlayerFailureView(viewModel: viewModel, message: message, error: error)
        case .ended:
            TVPlayerEndView(viewModel: viewModel, next: resolver.next(after: viewModel.currentItem)) { next in
                playChannel(next)
            }
        case .nextEpisode(let next):
            TVNextEpisodeCard(
                next: next,
                autoplays: !isAssistiveTechnologyEnabled,
                play: {
                    if let ref = next.series {
                        AccessibilityAnnouncer.announce(String(localized: "Playing \(EpisodeFormat.spokenCode(ref))", comment: "VoiceOver: the next episode starts; the placeholder is its season and episode, as in 'Season 1, episode 4'."))
                    }
                    playChannel(next)
                },
                cancel: {
                    cancelledCountdownFor = viewModel.currentItem
                }
            )
            .id(next.id)
        }
    }

    /// A seek that could not play (its Try Again is a contextual action, which the system shows while the transport
    /// bar is hidden), and Reconnecting… and the recording while the transport bar is hidden (it shows the state).
    @ViewBuilder
    private func statusPills(_ overlay: Overlay) -> some View {
        if overlay == .none {
            VStack(alignment: .trailing, spacing: 16) {
                if viewModel.seeker.phase == .failed {
                    TVPlayerStatusPill(label: PlayerSeekText.failed, systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                }
                if !systemPlayer.isTransportBarVisible {
                    transportStatusPills
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var transportStatusPills: some View {
        Group {
            if case .reconnecting = viewModel.playbackState {
                TVPlayerStatusPill(label: viewModel.playbackState.label, showsProgress: true)
            }
            if viewModel.isRecording {
                // The duration as the iPhone, iPad and Mac badge writes it (h:mm:ss after an hour) and speaks it.
                TVPlayerStatusPill(
                    label: String(localized: "REC \(PlayerTime.format(viewModel.timeline.recordingDuration))", comment: "Apple TV player: the live channel is being recorded; the placeholder is how long, as in 12:34."),
                    systemImage: "record.circle.fill",
                    tint: Theme.recording
                )
                .accessibilityLabel(Text("Recording"))
                .accessibilityValue(Text(PlayerTime.spoken(viewModel.timeline.recordingDuration)))
            }
        }
    }
}

/// `AVPlayerViewController` (through its container, `TVSystemPlayer`) on the app's player. The controller outlives
/// the view: it keeps playing in Picture in Picture after the player screen closed.
private struct SystemPlayer: UIViewControllerRepresentable {
    let viewModel: AVPlayerViewModel
    let services: TVPlayerServices
    let chrome: TVPlayerChrome

    func makeUIViewController(context: Context) -> TVPlayerContainerController {
        let player = TVSystemPlayer.shared
        player.attach(viewModel, services: services)
        player.apply(chrome)
        let container = player.container
        if container.parent != nil {
            // Still in the screen of a presentation that is going away.
            container.willMove(toParent: nil)
            container.view.removeFromSuperview()
            container.removeFromParent()
        }
        return container
    }

    func updateUIViewController(_ controller: TVPlayerContainerController, context: Context) {
        let player = TVSystemPlayer.shared
        player.attach(viewModel, services: services)
        player.apply(chrome)
    }

    static func dismantleUIViewController(_ controller: TVPlayerContainerController, coordinator: ()) {
        TVSystemPlayer.shared.screenWasDismantled()
    }
}
#endif
