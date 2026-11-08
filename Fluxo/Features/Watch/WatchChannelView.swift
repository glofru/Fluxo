//
//  WatchChannelView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

// The touch and pointer player screen (iPhone, iPad, Mac). Apple TV plays in the system's player, whose transport bar the Siri Remote drives (Fluxo/TV).
#if !os(tvOS)
import AVKit
import SwiftUI

/// Full player screen: the video edge to edge, with controls that fade out while the video plays.
///
/// - Top bar: close (the chevron: playback continues, on iOS in Picture in Picture), Picture in Picture,
///   AirPlay, a menu (fill / fit, recordings) and stop (the X, top right), then the channel logo and name and
///   its status (connecting / buffering / live / time-shifted / recording). On compact widths the name gets a
///   row of its own, so it stays readable on small iPhones.
/// - Bottom bar: the timeline (on-demand position or time-shift window), channel down / up within the group,
///   skip back / forward, play / pause, Go Live and record.
///
/// Controls hide after a few seconds of playback without interaction; a tap (or moving the mouse on macOS)
/// shows them again. They never hide while paused, failed, scrubbing or with VoiceOver running. On iOS the status
/// bar (time, battery) shows and hides with them, see `PlayerStatusBar.swift`.
///
/// On a foldable iPhone that is open, the video and a companion panel (the category's channels and the
/// schedule) can share the display, one on each side of the fold, see `PlayerPaneLayout`.
struct WatchChannelView: View {
    static let autoHideDelay: Duration = .seconds(4)
    /// The controls fade out in 0.25 s; the status bar hides after them.
    static let statusBarHideDelay: Duration = .milliseconds(300)
    /// How far loaded subtitles rise at least while the controls (the timeline and transport at the bottom) show;
    /// more when the bottom bar is taller (`PlayerChromeClearance`).
    static let subtitleControlsInset: CGFloat = 150

    let viewModel: AVPlayerViewModel

    @State private var controlsVisible = true
    /// Bumped by every interaction; restarts the auto-hide countdown.
    @State private var interactionCount = 0
    @State private var isScrubbing = false
    @State private var isShowingRecordings = false
    /// The room the top bar and the bottom bar take, as last laid out (the message cards stay between them).
    @State private var chromeClearance = PlayerChromeClearance()
    /// The playing channel's guide in a sheet over the video (players with no room for a panel next to it).
    @State private var isShowingChannelGuide = false
    /// Full Guide was chosen in that sheet: the app's guide shows this channel once the sheet is gone.
    @State private var pendingFullGuide: ChannelItem?
    /// Bumped when the guide control is used with the side panel already on its Guide tab: back to now.
    @State private var sidePanelGuideRequest = 0
    /// What a foldable's companion pane shows (the guide control switches it to the schedule).
    @State private var companionSection: PlayerCompanionPanel.Section = .channels
    @State private var hoverThrottle = HoverThrottle()
    /// Follows `controlsVisible`, but hides only once the controls have faded out (see `statusBarStyle`).
    @State private var isStatusBarHidden = false
    #if os(iOS)
    @State private var topSafeArea = PlayerTopSafeArea()
    #endif
    #if DEBUG
    /// Debug harness (`player-controls:show`): the controls stay on screen for screenshots.
    @State private var debugPinsControls = false
    /// Debug harness (`player-guide`): bumped to use the guide control.
    @State private var debugShowsChannelGuide = 0
    #endif
    /// The channel list / guide next to the video in a wide player (iPad in landscape); remembered.
    @AppStorage(PlayerSidePanelLayout.storageKey) private var showsSidePanel = false
    @AppStorage(PlayerSidePanelLayout.tabStorageKey) private var sidePanelTab: PlayerSidePanelTab = .channels
    @Environment(EPGStore.self) private var epg
    @Environment(\.openChannelGuide) private var openChannelGuide

    /// Any assistive technology (VoiceOver, Switch Control, Voice Control, Full Keyboard Access): the controls
    /// stay on screen, since a control that hides while the user moves to it cannot be reached.
    @Environment(\.accessibilityEnabled) private var isAssistiveTechnologyEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayPosture) private var posture
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(FoldablePlayerPreferences.panelWhenPartlyOpenKey) private var showsPanelWhenPartlyOpen = true
    @AppStorage(FoldablePlayerPreferences.panelWhenFlatKey) private var showsPanelWhenFlat = false
    @AppStorage(FoldablePlayerPreferences.videoOnTrailingSideKey) private var videoOnTrailingSide = false
    /// VoiceOver lands on the channel name when the player opens.
    @AccessibilityFocusState private var isTitleFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let paneLayout = PlayerPaneLayout.make(
                posture: posture,
                size: proxy.size,
                insets: proxy.safeAreaInsets,
                showsPanelWhenPartlyOpen: showsPanelWhenPartlyOpen,
                showsPanelWhenFlat: showsPanelWhenFlat,
                videoOnTrailingSide: videoOnTrailingSide
            )
            // Wide players (iPad in landscape, the Mac) can show the channel list and guide next to the video. A
            // foldable's own two-pane layout takes precedence (and is never wide enough for it anyway).
            let isSidePanelAvailable = paneLayout.mode == .full
                && PlayerSidePanelLayout.isAvailable(size: proxy.size, item: viewModel.currentItem)
            let layout = isSidePanelAvailable && showsSidePanel
                ? paneLayout.reservingTrailingSidePanel(width: PlayerSidePanelLayout.width, in: proxy.size)
                : paneLayout
            ZStack(alignment: .topLeading) {
                Color.black
                    .ignoresSafeArea()

                // Always the first view, whatever the layout: the video view keeps its identity (and the
                // playback its layer) when the posture changes or the side panel opens.
                stage(layout: layout, isSidePanelAvailable: isSidePanelAvailable, bottomSafeArea: proxy.safeAreaInsets.bottom)
                    .frame(width: layout.video.width, height: layout.video.height)
                    .position(x: layout.video.midX, y: layout.video.midY)

                if let panel = layout.panel {
                    panelPane(layout: layout)
                        .frame(width: panel.width, height: panel.height)
                        .position(x: panel.midX, y: panel.midY)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                if let sidePanel = layout.sidePanel {
                    PlayerSidePanel(viewModel: viewModel, guideRequest: sidePanelGuideRequest) {
                        showsSidePanel = false
                    }
                    .frame(width: sidePanel.width, height: sidePanel.height)
                    .position(x: sidePanel.midX, y: sidePanel.midY)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .environment(\.playerSplitControl, splitControl(for: layout))
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.45), value: layout)
        }
        #if os(iOS)
        // The status bar shows and hides with the controls; on iPad that changes the top safe area, which must
        // not move the controls (see `PlayerTopSafeArea`).
        .playerSteadyTopSafeArea($topSafeArea)
        #endif
        // The player is a layer over the app (see `PlayerPresentation`): only its own subtree goes dark, so the
        // app underneath keeps the system appearance (it shows while the player is dragged down).
        .environment(\.colorScheme, .dark)
        // The player covers the app: VoiceOver stays inside it, a two-finger double tap (Magic Tap) plays or
        // pauses, and the escape gesture (a two-finger Z) closes it.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        #if os(iOS)
        .accessibilityAction(.magicTap) {
            viewModel.togglePlayPause()
        }
        #else
        .accessibilityAction(.escape) {
            viewModel.closePlayer()
        }
        #endif
        .onAppear {
            AccessibilityAnnouncer.screenChanged()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                isTitleFocused = true
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: viewModel.isCasting)
        .task(id: AutoHide(interaction: interactionCount, canHide: canAutoHide)) {
            guard canAutoHide else {
                return
            }
            try? await Task.sleep(for: Self.autoHideDelay)
            guard !Task.isCancelled, canAutoHide else {
                return
            }
            controlsVisible = false
            #if os(macOS)
            NSCursor.setHiddenUntilMouseMoves(true)
            #endif
        }
        .task(id: controlsVisible) {
            guard !controlsVisible else {
                isStatusBarHidden = false
                return
            }
            try? await Task.sleep(for: Self.statusBarHideDelay)
            if !Task.isCancelled {
                isStatusBarHidden = true
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugPlayerGuide)) { notification in
            // Debug harness (`player-guide`): the guide control, or Full Guide in its sheet.
            if (notification.object as? String) == "full", let item = viewModel.currentItem {
                if isShowingChannelGuide {
                    pendingFullGuide = item
                    isShowingChannelGuide = false
                } else {
                    openChannelGuide(item)
                }
            } else {
                debugShowsChannelGuide += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugPlayerControls)) { notification in
            // Debug harness: shows (and keeps) or hides the controls, as a tap on the video would.
            guard let show = notification.object as? Bool else {
                return
            }
            debugPinsControls = show
            if show {
                showControls()
            } else {
                controlsVisible = false
            }
        }
        #endif
        .onChange(of: viewModel.currentChannel?.id) {
            // Zapped to another channel: show its name and status.
            showControls()
        }
        .onChange(of: viewModel.playbackState) { _, state in
            if state != .playing {
                showControls()
            }
        }
        // Back on screen from Picture in Picture (or reopened while handing the video to it, when this screen
        // stays mounted off screen): show the controls, they may have hidden during the hand-off.
        .onChange(of: viewModel.isClosingIntoPictureInPicture) { _, isClosing in
            if !isClosing {
                showControls()
            }
        }
        .onChange(of: viewModel.isPictureInPictureActive) { _, isActive in
            if !isActive {
                showControls()
            }
        }
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase, hoverThrottle.shouldReport() {
                showControls()
            }
        }
        #else
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        #endif
        // The status bar (time, battery) shows with the controls, in light content, and hides once they faded
        // out; the view that hosts the player sets it (see `PlayerStatusBar.swift`). Handing the video to Picture
        // in Picture gives it back to the app at once.
        .preference(key: PlayerStatusBarPreferenceKey.self, value: statusBarStyle)
        .sensoryFeedback(.selection, trigger: viewModel.currentChannel?.id)
        .sensoryFeedback(trigger: viewModel.isRecording) { _, isRecording in
            isRecording ? .impact(weight: .medium) : .success
        }
        // "Load Subtitle File…" of the Audio and Subtitles menu (the menu itself may hide with the controls).
        .subtitleFileImporter(viewModel.mediaSelection)
        .sheet(isPresented: $isShowingChannelGuide, onDismiss: openPendingFullGuide) {
            if let item = viewModel.currentItem {
                PlayerChannelGuideSheet(item: item) {
                    pendingFullGuide = item
                    isShowingChannelGuide = false
                }
                .playerChannelGuideSheetPresentation()
                // Dark like the player it covers (the sheet would otherwise follow the app's appearance).
                .preferredColorScheme(.dark)
            }
        }
        .onChange(of: viewModel.currentItem?.id) {
            // Zapped to a channel without a guide (or to a movie): its sheet has nothing to show.
            if isShowingChannelGuide && !canShowChannelGuide {
                isShowingChannelGuide = false
            }
        }
        .sheet(isPresented: $isShowingRecordings) {
            RecordingsView(store: viewModel.recordings, isRecordingActive: viewModel.isRecording) { recording in
                isShowingRecordings = false
                viewModel.playRecording(recording)
            }
            .mediumAndLargeDetentsAdaptingToTextSize()
        }
    }

    /// The video, the tap target, the status overlay and the controls that fade. The side panel (wide players)
    /// and a foldable's other pane sit next to it.
    private func stage(layout: PlayerPaneLayout, isSidePanelAvailable: Bool, bottomSafeArea: CGFloat) -> some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            AVVideoPlayer(surface: viewModel.surface)
                .ignoresSafeArea()
                // Video keeps its real colors under Smart Invert.
                .artworkIgnoresInvertColors()
                .onAppear {
                    viewModel.playerViewDidAppear()
                }
                .onDisappear {
                    viewModel.playerViewDidDisappear()
                }
                .accessibilityHidden(true)

            if viewModel.isCasting {
                // A Chromecast plays the channel: where, and its volume, instead of the (stopped) video.
                CastingBackdrop(viewModel: viewModel)
                    .transition(.opacity)
            } else if let subtitles = viewModel.mediaSelection.externalPlayback {
                // A subtitle file the user loaded, on the picture, above the controls while they show. (Subtitles
                // inside the stream are drawn by the video layer itself.)
                SubtitleOverlay(
                    playback: subtitles,
                    videoSize: viewModel.mediaSelection.presentationSize,
                    fillsScreen: viewModel.fillsScreen,
                    // Above the bottom bar as it is laid out (it grows with the text size), from the bottom of
                    // the screen.
                    bottomInset: controlsVisible && !layout.isStacked
                        ? max(Self.subtitleControlsInset, chromeClearance.bottom + bottomSafeArea)
                        : 0
                )
                .ignoresSafeArea()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: controlsVisible)
            }

            tapTarget

            // Escape closes the player even while the controls are hidden.
            Button("Close Player") {
                viewModel.closePlayer()
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if isSidePanelAvailable {
                // ⇧⌘L shows and hides the side panel even while the controls are hidden.
                Button(showsSidePanel ? "Hide Channel List" : "Show Channel List") {
                    showsSidePanel.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            PlayerStatusOverlay(viewModel: viewModel, clearance: controlsVisible ? chromeClearance : PlayerChromeClearance())

            // Series: "Next Episode" during the credits, and the countdown card when an episode ends.
            NextEpisodeOverlay(viewModel: viewModel, clearance: controlsVisible ? chromeClearance : PlayerChromeClearance())

            if controlsVisible {
                PlayerChrome(
                    viewModel: viewModel,
                    isScrubbing: $isScrubbing,
                    isShowingRecordings: $isShowingRecordings,
                    sidePanel: isSidePanelAvailable ? $showsSidePanel : nil,
                    showChannelGuide: canShowChannelGuide ? { showChannelGuide(layout: layout, isSidePanelAvailable: isSidePanelAvailable) } : nil,
                    showsBottomBar: !layout.isStacked,
                    clearance: $chromeClearance,
                    titleFocus: $isTitleFocused,
                    interacted: registerInteraction
                )
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                // Above the video while it fades out too: without it the removed controls ended up under the video
                // view, so they disappeared at once instead of fading out with the status bar.
                .zIndex(1)
            }
        }
        // Half of a foldable's display is phone-sized: the top bar uses its phone layout there. (A value, not a
        // conditional modifier, so the video view is never recreated.)
        .environment(\.horizontalSizeClass, layout.mode == .sideBySide ? .compact : horizontalSizeClass)
        #if DEBUG
        .onChange(of: debugShowsChannelGuide) {
            if canShowChannelGuide {
                showChannelGuide(layout: layout, isSidePanelAvailable: isSidePanelAvailable)
            }
        }
        #endif
    }

    // MARK: - Channel guide

    /// A live channel with a TV guide: the guide control (what is on now, Channel Guide in the menu) shows.
    private var canShowChannelGuide: Bool {
        viewModel.currentItem?.kind == .live && epg.hasGuide
    }

    /// The guide control: the playing channel's schedule, at now, where the player has room for it. The side panel
    /// of a wide player opens on its Guide tab; an open foldable shows it in its other pane; elsewhere it is a sheet
    /// over the video. The video keeps playing in all of them.
    private func showChannelGuide(layout: PlayerPaneLayout, isSidePanelAvailable: Bool) {
        registerInteraction()
        if isSidePanelAvailable {
            sidePanelTab = .guide
            showsSidePanel = true
            // Back to the playing channel and to now, if the panel already showed something else.
            sidePanelGuideRequest &+= 1
        } else if layout.canSplit {
            companionSection = .schedule
            let control = splitControl(for: layout)
            if !control.isShown {
                control.toggle()
            }
        } else {
            isShowingChannelGuide = true
        }
    }

    private func openPendingFullGuide() {
        guard let item = pendingFullGuide else {
            return
        }
        pendingFullGuide = nil
        openChannelGuide(item)
    }

    /// The other half of a foldable's display: the companion panel beside the video, or the controls (and the
    /// panel) below it.
    @ViewBuilder
    private func panelPane(layout: PlayerPaneLayout) -> some View {
        switch layout.mode {
        case .full:
            EmptyView()
        case .sideBySide:
            PlayerCompanionPanel(viewModel: viewModel, section: $companionSection, videoEdge: layout.videoEdge) {
                videoOnTrailingSide.toggle()
            }
        case .stacked:
            VStack(spacing: 0) {
                PlayerBottomBar(viewModel: viewModel, isScrubbing: $isScrubbing, interacted: registerInteraction)
                    .padding(.top, 14)
                if layout.showsPanelList {
                    PlayerCompanionPanel(viewModel: viewModel, section: $companionSection, showsHeader: false)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                PlayerCompanionPanel.background
                    .ignoresSafeArea()
            }
        }
    }

    private func splitControl(for layout: PlayerPaneLayout) -> PlayerSplitControl {
        PlayerSplitControl(
            isAvailable: layout.canSplit,
            isShown: layout.isStacked ? layout.showsPanelList : layout.mode == .sideBySide,
            isStacked: layout.isStacked || (posture.split()?.axis == .vertical)
        ) {
            if posture.isPartiallyOpen {
                showsPanelWhenPartlyOpen.toggle()
            } else {
                showsPanelWhenFlat.toggle()
            }
        }
    }

    /// Taps on the video toggle the controls; on macOS a double click toggles full screen.
    private var tapTarget: some View {
        Color.clear
            .contentShape(.rect)
            .ignoresSafeArea()
            #if os(macOS)
            .onTapGesture(count: 2) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            #endif
            .onTapGesture {
                if controlsVisible {
                    controlsVisible = false
                } else {
                    showControls()
                }
            }
            .accessibilityHidden(true)
    }

    /// The status bar shows with the controls, and hides right after they faded out (`statusBarHideDelay`), not
    /// with them: on iPad hiding it shrinks the top safe area, and the controls, while they fade out, would
    /// follow it up instead of staying where they are.
    private var statusBarStyle: PlayerStatusBarStyle {
        if viewModel.isClosingIntoPictureInPicture {
            return .app
        }
        return controlsVisible || !isStatusBarHidden ? .overVideo : .hidden
    }

    private var canAutoHide: Bool {
        #if DEBUG
        if debugPinsControls {
            return false
        }
        #endif
        // Not while casting: there is no video to uncover, and the controls drive the Chromecast.
        return controlsVisible && viewModel.playbackState == .playing && !isScrubbing && !isShowingRecordings && !isShowingChannelGuide
            && !isAssistiveTechnologyEnabled
            && !viewModel.isCasting
    }

    private func showControls() {
        if !controlsVisible {
            controlsVisible = true
        }
        interactionCount &+= 1
    }

    private func registerInteraction() {
        interactionCount &+= 1
    }

    private struct AutoHide: Equatable {
        let interaction: Int
        let canHide: Bool
    }
}

/// Limits mouse-move handling to a few calls per second (it fires on every mouse move).
/// A reference type so that updating it does not re-render the view.
private final class HoverThrottle {
    private var last = Date.distantPast

    func shouldReport() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(last) > 0.4 else {
            return false
        }
        last = now
        return true
    }
}

#Preview {
    WatchChannelView(viewModel: AVPlayerViewModel())
}
#endif
