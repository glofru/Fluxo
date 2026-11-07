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

// MARK: - Chrome

/// Feedback of icon buttons that sit on a shared glass capsule: a soft circle lights up under the finger.
/// (A glass shape per button cannot be used there: it would not line up with the capsule.)
private struct PlayerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconLabel(configuration: configuration)
    }

    /// A disabled button (e.g. skipping in a live channel, or while a Chromecast plays it) is dimmed.
    private struct IconLabel: View {
        let configuration: Configuration

        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.35)
                .background {
                    Circle()
                        .fill(.white.opacity(configuration.isPressed ? 0.18 : 0))
                        .padding(3)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.2), value: isEnabled)
        }
    }
}

/// A round glass control: the glass is drawn in exactly the button's frame, which is also its hit area.
private struct PlayerCircleButton: View {
    let title: String
    let systemImage: String
    var size: CGFloat = PlayerTopBar.buttonSize
    var font: Font = .body.weight(.semibold)
    var glass: Glass = .regular
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(glass.interactive(), in: .circle)
        .accessibilityLabel(title)
        .largeContentControl(title, systemImage: systemImage)
        .help(help ?? title)
    }
}

private struct PlayerChrome: View {
    let viewModel: AVPlayerViewModel
    @Binding var isScrubbing: Bool
    @Binding var isShowingRecordings: Bool
    /// Shows / hides the side panel; nil when the player is too narrow for it.
    let sidePanel: Binding<Bool>?
    /// The guide control (see `WatchChannelView.showChannelGuide`); nil when the item has no guide.
    let showChannelGuide: (() -> Void)?
    /// False when the transport controls sit in the other pane of a foldable (see `PlayerPaneLayout`).
    var showsBottomBar = true
    /// Set to the heights of the top bar and the bottom bar, as laid out.
    @Binding var clearance: PlayerChromeClearance
    var titleFocus: AccessibilityFocusState<Bool>.Binding
    let interacted: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let scrim = Theme.Player.scrim(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        VStack(spacing: 0) {
            PlayerTopBar(viewModel: viewModel, isShowingRecordings: $isShowingRecordings, sidePanel: sidePanel, showChannelGuide: showChannelGuide, titleFocus: titleFocus, interacted: interacted)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    clearance.top = height
                }
            Spacer(minLength: 0)
            if showsBottomBar {
                PlayerBottomBar(viewModel: viewModel, isScrubbing: $isScrubbing, interacted: interacted)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        clearance.bottom = height
                    }
            }
        }
        .onChange(of: showsBottomBar, initial: true) {
            // In the other pane of a foldable, the controls are not over the video.
            if !showsBottomBar {
                clearance.bottom = 0
            }
        }
        .background {
            // Scrims keep the title and the timeline legible on bright video (stronger without transparency).
            VStack(spacing: 0) {
                LinearGradient(colors: [scrim, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
                Spacer(minLength: 0)
                if showsBottomBar {
                    LinearGradient(colors: [.clear, scrim], startPoint: .top, endPoint: .bottom)
                        .frame(height: 280)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

private struct PlayerTopBar: View {
    static let logoSize = CGSize(width: 56, height: 38)
    static let buttonSize: CGFloat = 44
    static let edgePadding: CGFloat = 16

    let viewModel: AVPlayerViewModel
    @Binding var isShowingRecordings: Bool
    let sidePanel: Binding<Bool>?
    let showChannelGuide: (() -> Void)?
    var titleFocus: AccessibilityFocusState<Bool>.Binding
    let interacted: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.playerSplitControl) private var splitControl
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Room the window's corners need: on iPad, a window shows its controls (close, minimize, full screen) in
    /// a top corner, over the app's content. Zero otherwise.
    @State private var cornerInsets = RectangleCornerInsets()

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                // Phones: the buttons on one row, the channel on the next one, with the whole width for its name.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        closeButton
                        Spacer(minLength: 8)
                        actions
                        stopButton
                    }
                    title(lineLimit: dynamicTypeSize.prefersStackedLayout ? 3 : 2)
                }
            } else {
                HStack(spacing: 12) {
                    closeButton
                    title(lineLimit: 1)
                    Spacer(minLength: 8)
                    actions
                    stopButton
                }
            }
        }
        .font(.body.weight(.medium))
        // The buttons keep their size at the accessibility text sizes (they show in the Large Content Viewer
        // instead); the channel name and its status grow up to AX2.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        // The buttons move aside for the window controls (and the window's rounded corners) rather than sitting
        // under them.
        .padding(.leading, max(Self.edgePadding, cornerInsets.topLeading.width))
        .padding(.trailing, max(Self.edgePadding, cornerInsets.topTrailing.width))
        .padding(.top, 8)
        .onGeometryChange(for: RectangleCornerInsets.self) { proxy in
            proxy.containerCornerInsets
        } action: { insets in
            cornerInsets = insets
        }
    }

    /// Closes the screen; playback continues (in Picture in Picture on iOS, when it can).
    private var closeButton: some View {
        PlayerCircleButton(title: String(localized: "Close Player", comment: "Player button that hides the player; playback continues."), systemImage: "chevron.down", help: closeHelp) {
            viewModel.closePlayer()
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityInputLabels([Text("Close Player"), Text("Close"), Text("Minimize")])
        .accessibilityIdentifier("player.close")
    }

    /// Stops playback and closes the player.
    private var stopButton: some View {
        PlayerCircleButton(title: String(localized: "Stop Playback", comment: "Player button that stops playback and closes the player."), systemImage: "xmark", help: String(localized: "Stop playback and close the player", comment: "Tooltip of the Stop Playback button.")) {
            viewModel.stop()
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityInputLabels([Text("Stop Playback"), Text("Stop")])
        .accessibilityIdentifier("player.stop")
    }

    private var closeHelp: String {
        #if os(macOS)
        return String(localized: "Close the player (playback continues)", comment: "Tooltip of the Close Player button on the Mac.")
        #else
        return String(localized: "Close the player (playback continues in Picture in Picture)", comment: "Tooltip of the Close Player button on iPhone and iPad.")
        #endif
    }

    private func title(lineLimit: Int) -> some View {
        HStack(spacing: 12) {
            if let logo = viewModel.currentChannel?.logo {
                LogoImage(source: logo, size: Self.logoSize) { _ in
                    Color.clear
                }
                .padding(4)
                .background(.white.opacity(0.12), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    // An episode: its series, then its number and title.
                    Text(viewModel.currentItem?.series?.seriesTitle ?? viewModel.currentChannel?.name ?? String(localized: "No channel", comment: "Player title when nothing is playing."))
                        .font(Theme.Typography.playerTitle)
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                    if let episode = viewModel.currentItem?.series {
                        Text(TextParts.line([EpisodeFormat.code(episode), episode.episodeTitle]))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.Player.secondaryLabel)
                            .lineLimit(lineLimit)
                            .accessibilityLabel(Text(TextParts.spoken([EpisodeFormat.spokenCode(episode), episode.episodeTitle])))
                    }
                    PlayerStatusBadges(viewModel: viewModel, timeline: viewModel.timeline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused(titleFocus)
                // Now / next from the TV guide (live channels with a guide only); a tap shows the channel's guide.
                PlayerProgrammeInfo(item: viewModel.currentItem, showGuide: showChannelGuide)
            }
        }
        // A thin, mostly clear glass behind the channel and its guide: the scrim alone fades out before the
        // last lines, which a bright picture then washes out. It hugs the text, so the video stays in view.
        .playerLegibilityPlatter()
    }

    /// The companion panel of a foldable (see `PlayerPaneLayout`), then Picture in Picture, AirPlay, Cast (iOS;
    /// full screen on macOS) and the menu, on one glass capsule.
    private var actions: some View {
        HStack(spacing: 0) {
            if splitControl.isAvailable {
                Button {
                    interacted()
                    splitControl.toggle()
                } label: {
                    Image(systemName: splitControl.isStacked ? "rectangle.split.1x2" : "rectangle.split.2x1")
                        .symbolVariant(splitControl.isShown ? .fill : .none)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(PlayerIconButtonStyle())
                .accessibilityLabel(splitControl.isShown ? "Hide Channels" : "Show Channels")
                .accessibilityIdentifier("player.splitToggle")
                .help(splitControl.isShown ? "Give the whole display to the video" : "Show the channels next to the video")
            }

            if viewModel.isPictureInPictureSupported && !viewModel.isCasting {
                Button {
                    interacted()
                    viewModel.togglePictureInPicture()
                } label: {
                    Image(systemName: viewModel.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(PlayerIconButtonStyle())
                .disabled(!viewModel.isPictureInPicturePossible && !viewModel.isPictureInPictureActive)
                .accessibilityLabel(viewModel.isPictureInPictureActive ? "Exit Picture in Picture" : "Picture in Picture")
                .largeContentControl(viewModel.isPictureInPictureActive ? String(localized: "Exit Picture in Picture") : String(localized: "Picture in Picture"), systemImage: "pip.enter")
                .help("Picture in Picture")
            }

            // Audio tracks and subtitles, when the item has a choice (the receiver's tracks while casting), and
            // subtitle files for movies and episodes.
            MediaSelectionMenu(controller: viewModel.mediaSelection) {
                Image(systemName: "captions.bubble")
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .largeContentControl(String(localized: "Audio and Subtitles"), systemImage: "captions.bubble")
            .accessibilityIdentifier("player.mediaSelection")

            RoutePicker(player: viewModel.player)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .accessibilityLabel("AirPlay")
                .largeContentControl("AirPlay", systemImage: "airplay.video")
                .help("AirPlay")

            // Google Cast (iOS only: there is no Cast sender SDK for macOS).
            CastButton(cast: viewModel.cast, interacted: interacted)

            #if os(macOS)
            Button {
                interacted()
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(PlayerIconButtonStyle())
            .accessibilityLabel("Full Screen")
            .help("Enter or exit full screen")
            #endif

            if let sidePanel {
                // Wide players: the category's channels and the guide next to the video.
                Button {
                    interacted()
                    sidePanel.wrappedValue.toggle()
                } label: {
                    // The panel is on the trailing edge, so the symbol follows the layout direction.
                    Image(systemName: "sidebar.trailing")
                        .symbolVariant(sidePanel.wrappedValue ? .fill : .none)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(PlayerIconButtonStyle())
                .accessibilityLabel(sidePanel.wrappedValue ? "Hide Channel List" : "Show Channel List")
                .help("Channels and guide")
            }

            Menu {
                Button(viewModel.fillsScreen ? "Fit to Screen" : "Fill Screen", systemImage: viewModel.fillsScreen ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward") {
                    viewModel.toggleFillsScreen()
                }
                if let showChannelGuide {
                    Button("Channel Guide", systemImage: "calendar.day.timeline.left", action: showChannelGuide)
                }
                Button("Recordings", systemImage: "film.stack") {
                    isShowingRecordings = true
                }
                if viewModel.cast.isSupported && !viewModel.cast.showsCastButton {
                    // The cast button hides while no Cast device is found; this keeps the way to the picker
                    // (and its tips, such as allowing Local Network access).
                    Button("Cast to a Device…", systemImage: "tv.badge.wifi") {
                        viewModel.cast.presentPicker()
                    }
                }
                // The stream link of the playlist entry (not of a recording).
                if let item = viewModel.currentItem, StreamLink(item.url) != nil {
                    Divider()
                    ChannelLinkMenuItems(item: item)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(.circle)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("More")
            .largeContentControl(String(localized: "More"), systemImage: "ellipsis")
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Connection, buffering, error, paused and live status under the title. Live / time-shift position and
/// the recording indicator live in the bottom controls when time-shift is available.
private struct PlayerStatusBadges: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline

    var body: some View {
        status
            .font(Theme.Typography.playerStatus.monospacedDigit())
    }

    @ViewBuilder
    private var status: some View {
        switch viewModel.playbackState {
        case .connecting:
            busyBadge(String(localized: "Connecting…", comment: "Player status: opening the stream."))
        case .buffering:
            busyBadge(String(localized: "Buffering…", comment: "Player status: waiting for media data."))
        case .reconnecting:
            PlayerBadge(text: viewModel.playbackState.label, systemImage: "wifi.exclamationmark", tint: Theme.warning)
        case .failed where viewModel.isWaitingForNetwork:
            PlayerBadge(text: String(localized: "Offline", comment: "Player status badge: the device has no network connection, so the stream waits for it."), systemImage: "wifi.slash", tint: Theme.warning)
        case .failed:
            PlayerBadge(text: String(localized: "Error", comment: "Player status badge: playback failed."), systemImage: "exclamationmark.triangle.fill", tint: Theme.error)
        case .ended:
            PlayerBadge(text: String(localized: "Ended", comment: "Player status: the stream or video finished."), systemImage: "checkmark.circle", tint: Theme.secondaryText)
        case .idle:
            PlayerBadge(text: String(localized: "Idle", comment: "Player status: nothing is loaded."), systemImage: nil, tint: Theme.secondaryText)
        case .playing, .paused:
            if viewModel.playbackState == .paused {
                PlayerBadge(text: String(localized: "Paused", comment: "Player status."), systemImage: "pause.fill", tint: Theme.secondaryText)
            } else if viewModel.isTimeShiftAvailable {
                // The bottom live control shows LIVE or the time behind live.
                if let group = viewModel.currentItem?.groupName, !group.isEmpty {
                    PlayerBadge(text: group, systemImage: nil, tint: Theme.secondaryText)
                }
            } else if isLive {
                LiveBadge()
            } else {
                PlayerBadge(text: String(localized: "Playing", comment: "Player status."), systemImage: "play.fill", tint: Theme.secondaryText)
            }
        }
    }

    private var isLive: Bool {
        viewModel.isCurrentChannelLiveContent || (timeline.duration == 0 && !viewModel.canSeek)
    }

    private func busyBadge(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(text)
        }
        .foregroundStyle(Theme.secondaryText)
    }
}

private struct PlayerBadge: View {
    let text: String
    let systemImage: String?
    let tint: Color

    var body: some View {
        if let systemImage {
            Label(text, systemImage: systemImage)
                .foregroundStyle(tint)
                .lineLimit(1)
        } else {
            Text(text)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

// MARK: - Bottom bar

/// The floating glass controls: record on the leading side, the transport in the middle and the live
/// control on the trailing side. They share one `GlassEffectContainer`, so the glass morphs when the state
/// changes: play / pause retints, the record button stretches into the recording timer, the LIVE indicator
/// turns into "Go Live" when the stream is time-shifted, and the skip capsules grow to take the channel buttons.
private struct PlayerBottomBar: View {
    let viewModel: AVPlayerViewModel
    @Binding var isScrubbing: Bool
    let interacted: () -> Void

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The app's direction: the timeline runs left to right in every language, what it shows as text does not.
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        VStack(spacing: 14) {
            if let error = viewModel.recordingError {
                Button {
                    viewModel.clearRecordingError()
                } label: {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.error)
                        .lineLimit(2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityHint("Dismisses the message")
                .transition(.opacity)
            }

            if let error = viewModel.castError {
                Button {
                    viewModel.clearCastError()
                } label: {
                    Label {
                        Text(error)
                    } icon: {
                        CastIcon(connection: .disconnected, size: 16)
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                .accessibilityHint("Dismisses the message")
                .accessibilityIdentifier("cast.error")
                .transition(.opacity)
            }

            // Media timelines and transport run left to right in every language (as in the system players): only
            // their placement mirrors in right-to-left layouts.
            PlayerTimelineBar(viewModel: viewModel, timeline: viewModel.timeline, isScrubbing: $isScrubbing,
                              textDirection: layoutDirection, interacted: interacted)
                .environment(\.layoutDirection, .leftToRight)

            GlassEffectContainer(spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    // Wide: secondary actions on both sides of the transport.
                    HStack(spacing: 16) {
                        RecordControl(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                            .frame(minWidth: 170, alignment: .leading)
                        Spacer(minLength: 0)
                        PlayerTransport(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                            .environment(\.layoutDirection, .leftToRight)
                        Spacer(minLength: 0)
                        LiveControl(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                            .frame(minWidth: 170, alignment: .trailing)
                    }

                    // Compact: the transport on its own row.
                    VStack(spacing: 14) {
                        PlayerTransport(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                            .environment(\.layoutDirection, .leftToRight)
                        HStack {
                            RecordControl(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                            Spacer(minLength: 0)
                            LiveControl(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                        }
                    }
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: MorphState(viewModel))
            // The controls keep their size from here on: at the accessibility text sizes a long press shows them
            // in the Large Content Viewer.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .font(.body.weight(.medium))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    /// What the glass morphs on (the time-shift position is animated by `LiveControl` itself).
    private struct MorphState: Equatable {
        let isPaused: Bool
        let isRecording: Bool
        let canRecord: Bool
        let canZap: Bool
        let isTimeShiftAvailable: Bool
        let hasRecordingError: Bool
        let hasCastError: Bool

        @MainActor
        init(_ viewModel: AVPlayerViewModel) {
            isPaused = PlayerTransport.isPaused(viewModel.playbackState)
            isRecording = viewModel.isRecording
            canRecord = viewModel.canRecord
            canZap = viewModel.canZap
            isTimeShiftAvailable = viewModel.isTimeShiftAvailable
            hasRecordingError = viewModel.recordingError != nil
            hasCastError = viewModel.castError != nil
        }
    }
}

/// Position in an on-demand item, or in the time-shift window of a live stream, with a scrubber that follows
/// the finger. Observes the timeline, which changes twice a second.
///
/// The scrubber is drawn here rather than with `Slider`: its drag has priority over the player's swipe-down,
/// starts on touch (a tap seeks), has a 44 pt tall hit area around a thin track, and freezes the range while
/// it is dragged, so the live edge moving forward never pulls the knob away from the finger.
///
/// The knob and the times belong to the finger while it drags (never to the player's clock), and then to where
/// the seek goes (`PlayerSeeker.target`) until playback is there, so the bar never jumps back to the old position
/// while the player gets to the new one. Above the knob: the time under the finger and a frame preview while
/// dragging (movies AVPlayer plays itself; a local file moves the video itself), and Try Again when the seek could
/// not play. (While it loads, the spinner is in the middle of the video, `PlayerStatusOverlay`.)
private struct PlayerTimelineBar: View {
    static let hitHeight: CGFloat = 44

    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    @Binding var isScrubbing: Bool
    /// The app's direction (the bar is left to right in every language), for the text over the knob.
    let textDirection: LayoutDirection
    let interacted: () -> Void

    @State private var scrubPosition: Double = 0
    /// The range at the start of the drag.
    @State private var scrubRange: ClosedRange<Double>?
    /// The finger reached an end of the bar (a haptic tick each time it does).
    @State private var edgeHits = 0
    @State private var isAtEdge = false
    /// The width of the bar (where the callout over the knob goes).
    @State private var barWidth: CGFloat = 0
    /// The drag is in progress: false again when it ends or is cancelled (cancelled drags never call `onEnded`).
    @GestureState private var isDragging = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if viewModel.canSeek {
            let isLive = viewModel.isTimeShiftAvailable
            // A time-shifted live stream ends at its live point (where "Go Live" seeks, the live latency before
            // the end of what is buffered), so the knob sits at the end of the bar while playing live.
            let end = isLive ? timeline.seekableEnd - timeline.liveLatency : timeline.seekableEnd
            let liveRange = timeline.seekableStart...max(timeline.seekableStart + 1, end)
            let range = isScrubbing ? (scrubRange ?? liveRange) : liveRange
            let seeker = viewModel.seeker
            let shown = isScrubbing ? scrubPosition : (seeker.target ?? timeline.currentTime)
            let position = min(max(shown, range.lowerBound), range.upperBound)
            let lower = range.lowerBound
            let upper = range.upperBound
            // Behind the live point, as "-m:ss Go Live" shows it (0 while the LIVE indicator shows).
            let behindLive = isScrubbing || seeker.target != nil
                ? max(0, upper - position)
                : (timeline.isAtLiveEdge ? 0 : timeline.timeBehindLive)

            HStack(spacing: 12) {
                Text(isLive ? "-\(PlayerTime.format(behindLive))" : PlayerTime.format(position))
                    .frame(minWidth: 52, alignment: .leading)
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)

                scrubber(position: position, range: range, isLive: isLive)
                    .accessibilityRepresentation {
                        Slider(
                            value: Binding(get: { position }, set: { value in
                                interacted()
                                viewModel.seek(toSeconds: value)
                            }),
                            in: range
                        )
                        .accessibilityLabel(isLive ? "Time-shift position" : "Playback position")
                        .accessibilityValue(isLive ? "\(PlayerTime.spoken(behindLive)) behind live" : "\(PlayerTime.spoken(position)) of \(PlayerTime.spoken(upper))")
                        .accessibilityHint(seekHint)
                    }
                    .accessibilityIdentifier("player.scrubber")
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
                    // Outside the representation above, which replaces everything inside it for assistive
                    // technologies: Try Again must stay reachable with VoiceOver and Full Keyboard Access.
                    .overlay(alignment: .bottomLeading) {
                        let span = max(0.001, upper - lower)
                        let fraction = min(1, max(0, (position - lower) / span))
                        ScrubCallout(viewModel: viewModel, preview: viewModel.scrubPreview, isScrubbing: isScrubbing,
                                     position: position, upper: upper, isLive: isLive, barWidth: barWidth, knobX: barWidth * fraction,
                                     textDirection: textDirection, interacted: interacted)
                            // Above the knob (22 pt tall while dragging, centered in the hit area).
                            .offset(y: -(Self.hitHeight / 2 + 16))
                    }

                Text(isLive ? PlayerTime.format(upper - lower) : String(localized: "-\(PlayerTime.format(upper - position))", comment: "Time remaining in the player, as in -12:34."))
                    .frame(minWidth: 52, alignment: .trailing)
                    .contentTransition(.numericText())
                    .accessibilityLabel(isLive ? "Time-shift buffer \(PlayerTime.spoken(upper - lower))" : "\(PlayerTime.spoken(upper - position)) remaining")
            }
            .font(Theme.Typography.timecode)
            .foregroundStyle(Theme.Player.secondaryLabel)
            #if DEBUG
            .onChange(of: viewModel.debugScrubHold) { _, hold in
                // The harness's `scrub-hold:` / `scrub-release`: what the drag gesture does.
                if let hold {
                    beginScrub(in: range)
                    scrubPosition = min(max(hold, range.lowerBound), range.upperBound)
                    viewModel.scrub(toSeconds: scrubPosition)
                    interacted()
                } else {
                    endScrub()
                }
            }
            #endif
        }
    }

    /// What VoiceOver says after the position while a seek loads or could not play.
    private var seekHint: Text {
        switch viewModel.seeker.phase {
        case .failed:
            Text(PlayerSeekText.failedHint)
        case .seeking, .loading:
            Text(PlayerSeekText.loading)
        case .idle:
            Text(verbatim: "")
        }
    }

    /// The finger touched the bar: the range freezes and the frame previews start.
    private func beginScrub(in range: ClosedRange<Double>) {
        guard !isScrubbing else {
            return
        }
        scrubRange = range
        isScrubbing = true
        viewModel.setScrubbing(true)
    }

    /// The finger left the bar, or the drag was cancelled (by the system, another gesture): the seek goes to where
    /// it was, then the bar shows its target (not the old position).
    private func endScrub() {
        guard isScrubbing else {
            return
        }
        viewModel.seek(toSeconds: scrubPosition)
        viewModel.setScrubbing(false)
        isScrubbing = false
        scrubRange = nil
        isAtEdge = false
        interacted()
    }

    private func scrubber(position: Double, range: ClosedRange<Double>, isLive: Bool) -> some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let span = max(0.001, range.upperBound - range.lowerBound)
            let fraction = min(1, max(0, (position - range.lowerBound) / span))
            let trackHeight: CGFloat = isScrubbing ? 8 : 5
            let knob: CGFloat = isScrubbing ? 22 : 14

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Player.track)
                    .frame(height: trackHeight)
                // The streams of the icon, revealed up to the position.
                Capsule()
                    .fill(Theme.streamGradient)
                    .frame(height: trackHeight)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: width * fraction)
                    }
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: width * fraction - knob / 2)
            }
            .frame(width: width, height: Self.hitHeight)
            .contentShape(.rect)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, dragging, _ in
                        dragging = true
                    }
                    .onChanged { value in
                        beginScrub(in: range)
                        let frozen = scrubRange ?? range
                        let location = min(max(0, value.location.x), width) / width
                        let atEdge = location <= 0 || location >= 1
                        if atEdge && !isAtEdge {
                            edgeHits += 1
                        }
                        isAtEdge = atEdge
                        scrubPosition = frozen.lowerBound + location * (frozen.upperBound - frozen.lowerBound)
                        viewModel.scrub(toSeconds: scrubPosition)
                        interacted()
                    }
                    .onEnded { _ in
                        endScrub()
                    }
            )
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isScrubbing)
        }
        .frame(height: Self.hitHeight)
        .onChange(of: isDragging) { _, dragging in
            guard !dragging else {
                return
            }
            // A drag that ended calls onEnded (which may come after this); a cancelled one never does. Afterwards,
            // a scrub still going on was cancelled: it ends the same way.
            Task { @MainActor in
                endScrub()
            }
        }
        .sensoryFeedback(.selection, trigger: isScrubbing)
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.7), trigger: edgeHits)
    }
}

/// What floats over the knob of the scrubber: while dragging, the time under the finger (with a frame preview
/// when there is one); Try Again when the seek could not play.
private struct ScrubCallout: View {
    let viewModel: AVPlayerViewModel
    let preview: ScrubPreviewProvider
    let isScrubbing: Bool
    let position: Double
    let upper: Double
    let isLive: Bool
    let barWidth: CGFloat
    let knobX: CGFloat
    /// The app's direction (the bar itself is left to right): Try Again's icon and text follow it.
    let textDirection: LayoutDirection
    let interacted: () -> Void

    @State private var size: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Wider over a wide bar (an iPad, a Mac window), within the bar.
    private var previewWidth: CGFloat {
        min(max(160, barWidth * 0.28), 260)
    }

    var body: some View {
        content
            // Its own height, not the bar's (the overlay offers it the bar's 44 pt); as wide as it needs within the
            // bar, so that a long translation wraps instead of running past it.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            // Centered over the knob, kept within the bar.
            .offset(x: min(max(0, knobX - size.width / 2), max(0, barWidth - size.width)))
            .allowsHitTesting(viewModel.seeker.phase == .failed && !isScrubbing)
    }

    @ViewBuilder
    private var content: some View {
        if isScrubbing {
            VStack(spacing: 6) {
                if let image = preview.image {
                    // Dimmed while it shows another place than the finger (the frame there is on its way).
                    let isCurrent = preview.matches(position)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: previewWidth)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                        }
                        .opacity(isCurrent ? 1 : 0.45)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isCurrent)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                }
                Text(isLive ? "-\(PlayerTime.format(max(0, upper - position)))" : PlayerTime.format(position))
                    .font(Theme.Typography.timecode.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }
            .accessibilityHidden(true)
        } else if viewModel.seeker.phase == .failed {
            Button {
                interacted()
                viewModel.retrySeek()
            } label: {
                VStack(spacing: 2) {
                    Text(PlayerSeekText.failed)
                        .font(.caption)
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(.rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Theme.error.opacity(0.5)).interactive(), in: .rect(cornerRadius: 16))
            // "Try Again", then why (its own sentence).
            .accessibilityLabel(Text("Try Again"))
            .accessibilityHint(Text(PlayerSeekText.failed))
            .accessibilityIdentifier("player.seekRetry")
            .environment(\.layoutDirection, textDirection)
        }
    }
}

/// The words of a seek that loads or could not play: over the timeline, on the scrubber for VoiceOver and in the
/// announcements (`PlayerAnnouncer`).
/// Channel down / up, skip back / forward and play / pause. Channel and skip buttons share one glass capsule
/// on each side; play / pause is a larger circle, tinted with the accent color while paused.
private struct PlayerTransport: View {
    static let buttonSize: CGFloat = 48
    static let playSize: CGFloat = 66

    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    let namespace: Namespace.ID
    let interacted: () -> Void

    @State private var playPauseTaps = 0
    /// Skip taps (a light tick each; quick taps add up into one seek, see `AVPlayerViewModel.skip(by:)`).
    @State private var skipTaps = 0

    static func isPaused(_ state: AVPlayerViewModel.PlaybackState) -> Bool {
        switch state {
        case .paused, .ended, .failed, .idle:
            return true
        default:
            return false
        }
    }

    var body: some View {
        let back = Int(AVPlayerViewModel.skipBackwardInterval)
        let forward = Int(AVPlayerViewModel.skipForwardInterval)
        let isPaused = Self.isPaused(viewModel.playbackState)

        HStack(spacing: 14) {
            HStack(spacing: 0) {
                if viewModel.canZap {
                    transportButton(String(localized: "Previous Channel", comment: "Player button."), systemImage: "backward.end.fill", help: String(localized: "Previous channel in this group", comment: "Tooltip of the Previous Channel button.")) {
                        viewModel.previousChannel()
                    }
                }

                transportButton(String(localized: "Back \(back) seconds", comment: "Player button that skips back; the number is how many seconds."), systemImage: "gobackward.\(back)", help: String(localized: "Back \(back) seconds", comment: "Player button that skips back; the number is how many seconds.")) {
                    skipTaps += 1
                    viewModel.skipBackward()
                }
                .disabled(!viewModel.canSeek)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("transport.back", in: namespace)

            Button {
                interacted()
                playPauseTaps += 1
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.title.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: Self.playSize, height: Self.playSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(isPaused && !viewModel.isWaitingForNetwork ? .regular.tint(Theme.accentFill).interactive() : .regular.interactive(), in: .circle)
            .glassEffectID("transport.play", in: namespace)
            // Offline, nothing can start until the network returns (it then starts by itself).
            .disabled(viewModel.isWaitingForNetwork)
            .sensoryFeedback(.impact(weight: .light), trigger: playPauseTaps)
            .accessibilityLabel(isPaused ? "Play" : "Pause")
            .accessibilityInputLabels(isPaused ? [Text("Play"), Text("Resume")] : [Text("Pause")])
            .largeContentControl(isPaused ? String(localized: "Play") : String(localized: "Pause"), systemImage: isPaused ? "play.fill" : "pause.fill")
            .help(isPaused ? "Play" : "Pause")

            HStack(spacing: 0) {
                transportButton(String(localized: "Forward \(forward) seconds", comment: "Player button that skips forward; the number is how many seconds."), systemImage: "goforward.\(forward)", help: String(localized: "Forward \(forward) seconds", comment: "Player button that skips forward; the number is how many seconds.")) {
                    skipTaps += 1
                    viewModel.skipForward()
                }
                .disabled(!viewModel.canSeek || (viewModel.isTimeShiftAvailable && timeline.isAtLiveEdge))

                if viewModel.canZap {
                    transportButton(String(localized: "Next Channel", comment: "Player button."), systemImage: "forward.end.fill", help: String(localized: "Next channel in this group", comment: "Tooltip of the Next Channel button.")) {
                        viewModel.nextChannel()
                    }
                }
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("transport.forward", in: namespace)
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: skipTaps)
    }

    private func transportButton(_ label: String, systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            interacted()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(.circle)
        }
        .buttonStyle(PlayerIconButtonStyle())
        .accessibilityLabel(label)
        .largeContentControl(label, systemImage: systemImage)
        .help(help)
    }
}

/// Record: a glass capsule that stretches into a red-tinted "REC m:ss" timer with a pulsing dot while
/// recording, and back when the recording stops.
private struct RecordControl: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    let namespace: Namespace.ID
    let interacted: () -> Void


    var body: some View {
        if viewModel.isRecording {
            Button {
                interacted()
                viewModel.toggleRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(Theme.recording)
                        .ambientSymbolEffect(.pulse)
                    Text("REC \(PlayerTime.format(timeline.recordingDuration))")
                        .monospacedDigit()
                    Image(systemName: "stop.fill")
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .frame(height: PlayerTransport.buttonSize)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Theme.recording.opacity(0.45)).interactive(), in: .capsule)
            .glassEffectID("record", in: namespace)
            .accessibilityLabel("Stop Recording")
            .accessibilityValue(PlayerTime.spoken(timeline.recordingDuration))
            .accessibilityInputLabels([Text("Stop Recording"), Text("Stop Record")])
            .largeContentControl(String(localized: "Stop Recording"), systemImage: "stop.fill")
            .help("Stop recording")
        } else if viewModel.canRecord {
            Button {
                interacted()
                viewModel.toggleRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(Theme.recording)
                    Text("Record")
                }
                .padding(.horizontal, 16)
                .frame(height: PlayerTransport.buttonSize)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("record", in: namespace)
            .accessibilityLabel("Record")
            .accessibilityHint("Records this channel to Recordings")
            .largeContentControl(String(localized: "Record"), systemImage: "record.circle")
            .help("Record this channel")
        }
    }
}

/// Time-shifted live streams: a LIVE indicator in the live color at the live edge, which morphs into a
/// "-m:ss · Go Live" button when playback is behind live.
private struct LiveControl: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    let namespace: Namespace.ID
    let interacted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var goLiveTaps = 0

    var body: some View {
        // Live unless paused: buffering at the live point is still live (it never shows "-0:00 Go Live").
        let isAtLive = timeline.isAtLiveEdge && viewModel.playbackState != .paused
        Group {
            // Not after a failure: there is no live edge to go back to until the channel plays again.
            if viewModel.isTimeShiftAvailable, !Self.hasFailed(viewModel.playbackState) {
                if isAtLive {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .ambientSymbolEffect(.variableColor.iterative)
                        Text("LIVE")
                            .font(.callout.weight(.heavy))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: PlayerTransport.buttonSize)
                    .glassEffect(.regular.tint(Theme.live.opacity(0.6)), in: .capsule)
                    .glassEffectID("live", in: namespace)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Live")
                    .accessibilityAddTraits(.isStaticText)
                } else {
                    Button {
                        interacted()
                        goLiveTaps += 1
                        viewModel.goLive()
                    } label: {
                        HStack(spacing: 8) {
                            Text("-\(PlayerTime.format(timeline.timeBehindLive))")
                                .monospacedDigit()
                                .foregroundStyle(Theme.timeShift)
                            Text("Go Live")
                            Image(systemName: "forward.end.alt.fill")
                                .font(.caption)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: PlayerTransport.buttonSize)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("live", in: namespace)
                    .accessibilityLabel("Go Live")
                    .accessibilityValue("\(PlayerTime.spoken(timeline.timeBehindLive)) behind live")
                    .largeContentControl(String(localized: "Go Live"), systemImage: "forward.end.alt.fill")
                    .help("Jump to the live edge")
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: isAtLive)
        .sensoryFeedback(.impact(weight: .medium), trigger: goLiveTaps)
    }

    private static func hasFailed(_ state: AVPlayerViewModel.PlaybackState) -> Bool {
        if case .failed = state {
            return true
        }
        return false
    }
}

// MARK: - Status overlay

/// The spinner in the middle of the video while a seek loads, on the player's thin glass platter so that it stays
/// visible over a bright picture. It shows after a moment only, so that a seek that is over at once (a local file,
/// media already buffered) does not flash it; a seek that takes long (a slow network) adds where it goes.
private struct SeekLoadingIndicator: View {
    let isSeeking: Bool
    /// Where the seek goes (`PlayerSeeker.target`).
    let target: TimeInterval?
    /// Time-shift of a live channel: the target is no time of a movie to show.
    let isLive: Bool

    static let slowDelay: Duration = .seconds(3)

    @State private var isShown = false
    @State private var isSlow = false

    var body: some View {
        let isVisible = isShown && isSeeking
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            if isSlow, !isLive, let target {
                Text(PlayerSeekText.loading(at: target))
                    .font(Theme.Typography.timecode)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(4)
        .playerLegibilityPlatter()
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(PlayerSeekText.loading))
        .accessibilityHidden(!isVisible)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            isShown = true
        }
        .task(id: target) {
            // Every new target (another skip) starts the wait over.
            isSlow = false
            try? await Task.sleep(for: Self.slowDelay)
            if !Task.isCancelled {
                isSlow = true
            }
        }
    }
}

/// Connection, buffering, error and end-of-stream feedback in the middle of the video.
private struct PlayerStatusOverlay: View {
    let viewModel: AVPlayerViewModel
    /// The controls' room around the message cards (zero while they are hidden).
    var clearance = PlayerChromeClearance()

    private static func isFailure(_ state: AVPlayerViewModel.PlaybackState) -> Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    var body: some View {
        switch viewModel.playbackState {
        case let state where viewModel.seeker.phase == .failed && !viewModel.isCasting && !Self.isFailure(state) && state != .ended:
            // A seek that could not play (the item itself still plays): its retry is over the scrubber
            // (`ScrubCallout`), the middle stays clear.
            EmptyView()
        case let state where viewModel.seeker.isBusy && !viewModel.isCasting && !Self.isFailure(state) && state != .ended:
            // A seek on its way (also while AVPlayer still says it plays, or paused): the one loading indicator.
            SeekLoadingIndicator(isSeeking: viewModel.seeker.phase == .seeking || state != .playing, target: viewModel.seeker.target,
                                 isLive: viewModel.isTimeShiftAvailable)
        case .connecting where viewModel.isCasting, .buffering where viewModel.isCasting:
            // The casting backdrop shows it.
            EmptyView()
        case .connecting, .buffering:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .allowsHitTesting(false)
                .accessibilityLabel(viewModel.playbackState.label)
        case .reconnecting:
            Label(viewModel.playbackState.label, systemImage: "wifi.exclamationmark")
                .font(.callout.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .allowsHitTesting(false)
        case .failed(let message) where viewModel.isWaitingForNetwork:
            // Not an error: it starts by itself when the network returns.
            PlayerMessageCard(
                systemImage: "wifi.slash",
                tint: Theme.warning,
                title: viewModel.currentItem?.kind == .live || viewModel.currentItem == nil
                    ? String(localized: "Waiting for a Connection", comment: "Player message title: the device is offline; the live channel starts when the network returns.")
                    : String(localized: "Not Available Offline", comment: "Player message title: the device is offline and this movie or episode is not downloaded."),
                message: message,
                clearance: clearance
            ) {
                PlayerMessageButton(title: String(localized: "Try Again"), systemImage: "arrow.clockwise", isProminent: false) {
                    viewModel.retry()
                }
            }
        case .failed(let message):
            PlayerMessageCard(
                systemImage: "exclamationmark.triangle.fill",
                tint: Theme.error,
                title: failureTitle,
                message: message,
                clearance: clearance
            ) {
                PlayerMessageButton(title: String(localized: "Try Again"), systemImage: "arrow.clockwise") {
                    viewModel.retry()
                }
                if viewModel.isCasting {
                    PlayerMessageButton(title: String(localized: "Play on This Device"), systemImage: "iphone", isProminent: false) {
                        viewModel.stopCasting()
                    }
                }
            }
        case .ended where NextEpisodeResolver.handlesEnd(of: viewModel):
            // `NextEpisodeOverlay` shows the next episode instead.
            EmptyView()
        case .ended:
            PlayerMessageCard(
                systemImage: "checkmark.circle.fill",
                tint: Theme.secondaryText,
                title: viewModel.isTimeShiftAvailable
                    ? String(localized: "The Stream Ended", comment: "Player message: the live stream ended.")
                    : String(localized: "Playback Ended", comment: "Player message: the video finished."),
                message: nil,
                clearance: clearance
            ) {
                if viewModel.canSeek {
                    PlayerMessageButton(title: String(localized: "Play Again"), systemImage: "arrow.counterclockwise") {
                        viewModel.play()
                    }
                } else {
                    PlayerMessageButton(title: String(localized: "Try Again"), systemImage: "arrow.clockwise") {
                        viewModel.retry()
                    }
                }
            }
        default:
            EmptyView()
        }
    }
}

extension PlayerStatusOverlay {
    private var failureTitle: String {
        if viewModel.isCasting, let device = viewModel.cast.connectedDevice {
            return String(localized: "Can't Play on \(device.name)")
        }
        return String(localized: "Can't Play This Channel")
    }
}

/// A button of a message card (`PlayerMessageCard`). Its title is always one line, never wrapped into a tall pill
/// ("Erneut" over "versuchen"): it shrinks a little to fit where the card is narrow, and a long press shows it whole in
/// the Large Content Viewer.
private struct PlayerMessageButton: View {
    let title: String
    let systemImage: String
    /// The card's main action (filled), or another one (glass).
    var isProminent = true
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .largeContentControl(title, systemImage: systemImage)
        if isProminent {
            button
                .buttonStyle(.glassProminent)
                .tint(Theme.accentFill)
        } else {
            button
                .buttonStyle(.glass)
        }
    }
}

/// A message in the middle of the video (an error, offline, the end) with its buttons, between the top bar and the
/// controls as they are measured (`PlayerChromeClearance`), never under them. Its title and buttons always show: when
/// the card does not fit (large text, a phone in landscape), only the message scrolls inside it; where the player is
/// wide and low, the buttons go next to the text instead of under it.
private struct PlayerMessageCard<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String?
    /// The controls' room, zero while they are hidden.
    let clearance: PlayerChromeClearance
    @ViewBuilder let actions: () -> Actions

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Space between the card and the controls, and at the edges of the video while they are hidden.
    private static var margin: CGFloat {
        12
    }

    /// From this width of the free area, the buttons may go next to the text, and the stacked card is wider at the
    /// accessibility text sizes.
    private static var sideBySideWidth: CGFloat {
        560
    }

    /// Below this height of the free area (a phone in landscape with the controls showing), the card's text stops
    /// growing at `.accessibility1` rather than `.accessibility3`, so its whole title and its buttons fit together.
    private static var lowHeight: CGFloat {
        240
    }

    @State private var availableSize: CGSize = .zero
    /// The height of the whole scrolling message, as last laid out (nil before).
    @State private var messageContentHeight: CGFloat?
    /// The height of the scrolling message's view, as last laid out (nil before): whole lines of it.
    @State private var messageVisibleHeight: CGFloat?
    /// The height of the message's first line and the distance between its lines, as the text is laid out at the
    /// card's text size (zero before).
    @State private var messageLines = MessageLineMetrics()

    private var messageOverflows: Bool {
        guard let messageContentHeight, let messageVisibleHeight else {
            return false
        }
        return messageContentHeight > messageVisibleHeight + 0.5
    }

    /// How many whole lines of the scrolling message show at once.
    private var visibleMessageLines: Int {
        messageLines.lines(fittingIn: messageVisibleHeight ?? 0)
    }

    /// The message scrolls and not even one line of it fits under the title (a phone in landscape with the controls
    /// showing): it is left out of the card, and VoiceOver reads it with the title.
    private var hidesMessage: Bool {
        messageOverflows && messageLines.isMeasured && visibleMessageLines == 0
    }

    /// The scrolling message fades out over its last visible line when there is more to read under it; with a
    /// single line in view, that line stays whole and only the scroll indicator shows that there is more.
    private var fadesMessage: Bool {
        messageOverflows && visibleMessageLines >= 2
    }

    var body: some View {
        let isWide = availableSize.width >= Self.sideBySideWidth
        let isLow = availableSize.height > 0 && availableSize.height < Self.lowHeight
        ViewThatFits(in: .vertical) {
            stackedCard(scrollsText: false, isWide: isWide)
            if isWide {
                sideBySideCard(scrollsText: false)
            }
            // Neither fits: the message scrolls inside the card, the title and the buttons stay in view.
            if isWide {
                sideBySideCard(scrollsText: true)
            } else {
                stackedCard(scrollsText: true, isWide: isWide)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            availableSize = size
        }
        .padding(.top, clearance.top + Self.margin)
        .padding(.bottom, clearance.bottom + Self.margin)
        .padding(.horizontal)
        .dynamicTypeSize(...(isLow ? DynamicTypeSize.accessibility1 : .accessibility3))
    }

    private func stackedCard(scrollsText: Bool, isWide: Bool) -> some View {
        VStack(spacing: scrollsText ? 12 : 16) {
            text(scrolls: scrollsText, alignment: .center)
                .layoutPriority(1)
            // Side by side when both fit, so the card stays low.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    actions()
                }
                VStack(spacing: 10) {
                    actions()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(scrollsText ? 16 : 24)
        // Wider where there is room for it at the accessibility text sizes (an iPad), so that the title and the
        // buttons' titles keep their size rather than wrapping in a narrow card in the middle of a large screen.
        .frame(maxWidth: isWide && dynamicTypeSize.isAccessibilitySize ? Self.sideBySideWidth : 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func sideBySideCard(scrollsText: Bool) -> some View {
        HStack(spacing: scrollsText ? 16 : 20) {
            // The text takes the width the buttons leave, the buttons keep their size.
            text(scrolls: scrollsText, alignment: .leading)
                .layoutPriority(1)
            VStack(spacing: 10) {
                actions()
            }
            .fixedSize()
        }
        .padding(scrollsText ? 16 : 24)
        .frame(maxWidth: scrollsText ? 760 : 640)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    @ViewBuilder
    private func text(scrolls: Bool, alignment: HorizontalAlignment) -> some View {
        if scrolls {
            // The title never scrolls: it is what the card says. It is laid out before the message, and shrinks a
            // little rather than being cut if even it alone does not fit.
            VStack(alignment: alignment, spacing: 6) {
                header(alignment: alignment, isCompact: true, includesMessage: hidesMessage)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                if let message {
                    scrollingMessage(message, alignment: alignment)
                }
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
        } else {
            VStack(alignment: alignment, spacing: 12) {
                header(alignment: alignment, isCompact: false, includesMessage: false)
                if let message {
                    messageText(message, alignment: alignment)
                }
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The message under the title when the card does not fit: always a whole number of lines tall (never a line cut
    /// through its glyphs), scrolling, and fading out over its last line when there is more under it.
    private func scrollingMessage(_ message: String, alignment: HorizontalAlignment) -> some View {
        WholeLinesLayout(lines: messageLines, contentHeight: messageContentHeight) {
            ScrollView {
                messageText(message, alignment: alignment)
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            }
            .scrollBounceBehavior(.basedOnSize)
            // Shows that there is more to read.
            .scrollIndicatorsFlash(onAppear: true)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, height in
                messageContentHeight = height
            }
            // One empty line after the last one, so that it scrolls clear of the fade, and the lines in view stay
            // whole at the end too.
            .contentMargins(.bottom, fadesMessage ? messageLines.pitch : 0, for: .scrollContent)
        }
        // Measured outside the scroll view: its container size leaves out the bottom margin, which depends on it.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            messageVisibleHeight = height
        }
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, fadesMessage ? .clear : .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: fadesMessage ? messageLines.pitch : 0)
            }
        }
        .background {
            // The message's line metrics at the card's text size, from one and two lines of its own text (its
            // script decides the line height): hidden, never read.
            let line = message.replacing("\n", with: " ")
            ZStack {
                messageText(line, alignment: alignment)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        messageLines.firstLine = height
                    }
                messageText(line + "\n" + line, alignment: alignment)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        messageLines.twoLines = height
                    }
            }
            .hidden()
            .accessibilityHidden(true)
        }
        .opacity(hidesMessage ? 0 : 1)
        .accessibilityHidden(hidesMessage)
    }

    /// The symbol and the title. Compact (the message scrolls): a smaller symbol; next to a leading title (the buttons
    /// beside the text), above a centered one. `includesMessage`: the message is not shown, VoiceOver reads it here.
    @ViewBuilder
    private func header(alignment: HorizontalAlignment, isCompact: Bool, includesMessage: Bool) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        let symbol = Image(systemName: systemImage)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
        let titleText = Text(title)
            .font(.headline)
            .multilineTextAlignment(textAlignment)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(includesMessage ? message ?? "" : "")
        if isCompact && alignment != .center {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                symbol
                    .font(.headline)
                titleText
            }
        } else {
            VStack(alignment: alignment, spacing: isCompact ? 6 : 12) {
                symbol
                    .font(isCompact ? .title2 : .largeTitle)
                titleText
            }
        }
    }

    private func messageText(_ message: String, alignment: HorizontalAlignment) -> some View {
        Text(message)
            .font(.callout)
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .foregroundStyle(Theme.secondaryText)
    }
}

/// The line metrics of a message card's text (`PlayerMessageCard`), as laid out.
private struct MessageLineMetrics: Equatable {
    /// Height of one line.
    var firstLine: CGFloat = 0
    /// Height of two lines.
    var twoLines: CGFloat = 0

    var isMeasured: Bool {
        firstLine > 0 && twoLines > firstLine
    }

    /// Distance from one line to the next.
    var pitch: CGFloat {
        isMeasured ? twoLines - firstLine : 0
    }

    /// How many whole lines fit in `height`.
    func lines(fittingIn height: CGFloat) -> Int {
        guard isMeasured, height + 0.5 >= firstLine else {
            return 0
        }
        return Int(((height + 0.5 - firstLine) / pitch).rounded(.down)) + 1
    }

    /// The tallest height of whole lines that fits in `height`.
    func wholeLinesHeight(fittingIn height: CGFloat) -> CGFloat {
        let count = lines(fittingIn: height)
        return count == 0 ? 0 : firstLine + CGFloat(count - 1) * pitch
    }
}

/// Lays out its one subview (the scrolling message of a message card) as tall as its content when that fits, else
/// as tall as the whole lines that fit in the height offered, so that no line in view is cut through its glyphs.
private struct WholeLinesLayout: Layout {
    let lines: MessageLineMetrics
    /// The height of the whole message, once it is known.
    let contentHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else {
            return .zero
        }
        let height = height(offered: proposal.height, subview: subview)
        // As wide as the scroll view would be (it takes the width offered).
        let width = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: height)).width
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }

    private func height(offered: CGFloat?, subview: LayoutSubview) -> CGFloat {
        guard let offered, offered.isFinite else {
            // Its ideal height: the whole message.
            return contentHeight ?? subview.sizeThatFits(.unspecified).height
        }
        if let contentHeight, contentHeight <= offered + 0.5 {
            return contentHeight
        }
        guard lines.isMeasured else {
            return offered
        }
        return lines.wholeLinesHeight(fittingIn: offered)
    }
}

// MARK: - AirPlay

#if os(macOS)
private struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.player = player
    }
}
#else
private struct RoutePicker: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
    }
}
#endif

#Preview {
    WatchChannelView(viewModel: AVPlayerViewModel())
}
#endif
