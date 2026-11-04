//
//  WatchChannelView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

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

    let viewModel: AVPlayerViewModel

    @State private var controlsVisible = true
    /// Bumped by every interaction; restarts the auto-hide countdown.
    @State private var interactionCount = 0
    @State private var isScrubbing = false
    @State private var isShowingRecordings = false
    @State private var hoverThrottle = HoverThrottle()
    /// Follows `controlsVisible`, but hides only once the controls have faded out (see `statusBarStyle`).
    @State private var isStatusBarHidden = false
    #if os(iOS)
    @State private var topSafeArea = PlayerTopSafeArea()
    #endif
    #if DEBUG
    /// Debug harness (`player-controls:show`): the controls stay on screen for screenshots.
    @State private var debugPinsControls = false
    #endif
    /// The channel list / guide next to the video in a wide player (iPad in landscape); remembered.
    @AppStorage(PlayerSidePanelLayout.storageKey) private var showsSidePanel = false

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
                stage(layout: layout, isSidePanelAvailable: isSidePanelAvailable)
                    .frame(width: layout.video.width, height: layout.video.height)
                    .position(x: layout.video.midX, y: layout.video.midY)

                if let panel = layout.panel {
                    panelPane(layout: layout)
                        .frame(width: panel.width, height: panel.height)
                        .position(x: panel.midX, y: panel.midY)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                if let sidePanel = layout.sidePanel {
                    PlayerSidePanel(viewModel: viewModel) {
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
    private func stage(layout: PlayerPaneLayout, isSidePanelAvailable: Bool) -> some View {
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

            PlayerStatusOverlay(viewModel: viewModel)

            if controlsVisible {
                PlayerChrome(
                    viewModel: viewModel,
                    isScrubbing: $isScrubbing,
                    isShowingRecordings: $isShowingRecordings,
                    sidePanel: isSidePanelAvailable ? $showsSidePanel : nil,
                    showsBottomBar: !layout.isStacked,
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
    }

    /// The other half of a foldable's display: the companion panel beside the video, or the controls (and the
    /// panel) below it.
    @ViewBuilder
    private func panelPane(layout: PlayerPaneLayout) -> some View {
        switch layout.mode {
        case .full:
            EmptyView()
        case .sideBySide:
            PlayerCompanionPanel(viewModel: viewModel, videoEdge: layout.videoEdge) {
                videoOnTrailingSide.toggle()
            }
        case .stacked:
            VStack(spacing: 0) {
                PlayerBottomBar(viewModel: viewModel, isScrubbing: $isScrubbing, interacted: registerInteraction)
                    .padding(.top, 14)
                if layout.showsPanelList {
                    PlayerCompanionPanel(viewModel: viewModel, showsHeader: false)
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
        return controlsVisible && viewModel.playbackState == .playing && !isScrubbing && !isShowingRecordings && !isAssistiveTechnologyEnabled
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
    /// False when the transport controls sit in the other pane of a foldable (see `PlayerPaneLayout`).
    var showsBottomBar = true
    var titleFocus: AccessibilityFocusState<Bool>.Binding
    let interacted: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let scrim = Theme.Player.scrim(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        VStack(spacing: 0) {
            PlayerTopBar(viewModel: viewModel, isShowingRecordings: $isShowingRecordings, sidePanel: sidePanel, titleFocus: titleFocus, interacted: interacted)
            Spacer(minLength: 0)
            if showsBottomBar {
                PlayerBottomBar(viewModel: viewModel, isScrubbing: $isScrubbing, interacted: interacted)
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
                VStack(alignment: .leading, spacing: 14) {
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
                    Text(viewModel.currentChannel?.name ?? String(localized: "No channel", comment: "Player title when nothing is playing."))
                        .font(Theme.Typography.playerTitle)
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                    PlayerStatusBadges(viewModel: viewModel, timeline: viewModel.timeline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused(titleFocus)
                // Now / next from the TV guide (live channels with a guide only).
                PlayerProgrammeInfo(item: viewModel.currentItem)
            }
        }
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

            // Audio tracks and subtitles, when the item has a choice (not while a Chromecast plays it).
            if !viewModel.isCasting {
                MediaSelectionMenu(controller: viewModel.mediaSelection) {
                    Image(systemName: "captions.bubble")
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .largeContentControl(String(localized: "Audio and Subtitles"), systemImage: "captions.bubble")
                .accessibilityIdentifier("player.mediaSelection")
            }

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
        viewModel.currentChannel?.isLiveContent == true || (timeline.duration == 0 && !viewModel.canSeek)
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
            PlayerTimelineBar(viewModel: viewModel, timeline: viewModel.timeline, isScrubbing: $isScrubbing, interacted: interacted)
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
private struct PlayerTimelineBar: View {
    static let hitHeight: CGFloat = 44

    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    @Binding var isScrubbing: Bool
    let interacted: () -> Void

    @State private var scrubPosition: Double = 0
    /// The range at the start of the drag.
    @State private var scrubRange: ClosedRange<Double>?

    var body: some View {
        if viewModel.canSeek {
            let isLive = viewModel.isTimeShiftAvailable
            // A time-shifted live stream ends at its live point (where "Go Live" seeks, the live latency before
            // the end of what is buffered), so the knob sits at the end of the bar while playing live.
            let end = isLive ? timeline.seekableEnd - timeline.liveLatency : timeline.seekableEnd
            let liveRange = timeline.seekableStart...max(timeline.seekableStart + 1, end)
            let range = isScrubbing ? (scrubRange ?? liveRange) : liveRange
            let position = isScrubbing ? scrubPosition : min(max(timeline.currentTime, range.lowerBound), range.upperBound)
            let lower = range.lowerBound
            let upper = range.upperBound
            // Behind the live point, as "-m:ss Go Live" shows it (0 while the LIVE indicator shows).
            let behindLive = isScrubbing
                ? max(0, upper - position)
                : (timeline.isAtLiveEdge ? 0 : timeline.timeBehindLive)

            HStack(spacing: 12) {
                Text(isLive ? "-\(PlayerTime.format(behindLive))" : PlayerTime.format(position))
                    .frame(minWidth: 52, alignment: .leading)
                    .accessibilityHidden(true)

                scrubber(position: position, range: range)
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
                    }
                    .accessibilityIdentifier("player.scrubber")

                Text(isLive ? PlayerTime.format(upper - lower) : String(localized: "-\(PlayerTime.format(upper - position))", comment: "Time remaining in the player, as in -12:34."))
                    .frame(minWidth: 52, alignment: .trailing)
                    .accessibilityLabel(isLive ? "Time-shift buffer \(PlayerTime.spoken(upper - lower))" : "\(PlayerTime.spoken(upper - position)) remaining")
            }
            .font(Theme.Typography.timecode)
            .foregroundStyle(Theme.Player.secondaryLabel)
        }
    }

    private func scrubber(position: Double, range: ClosedRange<Double>) -> some View {
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
                    .onChanged { value in
                        if !isScrubbing {
                            scrubRange = range
                            isScrubbing = true
                        }
                        let frozen = scrubRange ?? range
                        let location = min(max(0, value.location.x), width) / width
                        scrubPosition = frozen.lowerBound + location * (frozen.upperBound - frozen.lowerBound)
                        interacted()
                    }
                    .onEnded { _ in
                        viewModel.seek(toSeconds: scrubPosition)
                        isScrubbing = false
                        scrubRange = nil
                        interacted()
                    }
            )
            .animation(.snappy(duration: 0.2), value: isScrubbing)
        }
        .frame(height: Self.hitHeight)
        .sensoryFeedback(.selection, trigger: isScrubbing)
    }
}

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
            .glassEffect(isPaused ? .regular.tint(Theme.accentFill).interactive() : .regular.interactive(), in: .circle)
            .glassEffectID("transport.play", in: namespace)
            .sensoryFeedback(.impact(weight: .light), trigger: playPauseTaps)
            .accessibilityLabel(isPaused ? "Play" : "Pause")
            .accessibilityInputLabels(isPaused ? [Text("Play"), Text("Resume")] : [Text("Pause")])
            .largeContentControl(isPaused ? String(localized: "Play") : String(localized: "Pause"), systemImage: isPaused ? "play.fill" : "pause.fill")
            .help(isPaused ? "Play" : "Pause")

            HStack(spacing: 0) {
                transportButton(String(localized: "Forward \(forward) seconds", comment: "Player button that skips forward; the number is how many seconds."), systemImage: "goforward.\(forward)", help: String(localized: "Forward \(forward) seconds", comment: "Player button that skips forward; the number is how many seconds.")) {
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if viewModel.isRecording {
            Button {
                interacted()
                viewModel.toggleRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(Theme.recording)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
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
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
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

/// Connection, buffering, error and end-of-stream feedback in the middle of the video.
private struct PlayerStatusOverlay: View {
    let viewModel: AVPlayerViewModel

    var body: some View {
        switch viewModel.playbackState {
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
        case .failed(let message):
            PlayerMessageCard(
                systemImage: "exclamationmark.triangle.fill",
                tint: Theme.error,
                title: failureTitle,
                message: message
            ) {
                Button("Try Again", systemImage: "arrow.clockwise") {
                    viewModel.retry()
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accentFill)
                if viewModel.isCasting {
                    Button("Play on This Device", systemImage: "iphone") {
                        viewModel.stopCasting()
                    }
                    .buttonStyle(.glass)
                }
            }
        case .ended:
            PlayerMessageCard(
                systemImage: "checkmark.circle.fill",
                tint: Theme.secondaryText,
                title: viewModel.isTimeShiftAvailable
                    ? String(localized: "The Stream Ended", comment: "Player message: the live stream ended.")
                    : String(localized: "Playback Ended", comment: "Player message: the video finished."),
                message: nil
            ) {
                if viewModel.canSeek {
                    Button("Play Again", systemImage: "arrow.counterclockwise") {
                        viewModel.play()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentFill)
                } else {
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        viewModel.retry()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentFill)
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

private struct PlayerMessageCard<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        // Between the top and bottom controls; at large text sizes the card scrolls rather than running under them.
        ViewThatFits(in: .vertical) {
            card
            ScrollView {
                card
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.vertical, Self.chromeClearance)
    }

    /// Room left for the top bar and the transport controls around the card.
    private static var chromeClearance: CGFloat {
        #if os(macOS)
        return 90
        #else
        return 150
        #endif
    }

    private var card: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.secondaryText)
            }
            actions()
        }
        .padding(24)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
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

// MARK: - Formatting

enum PlayerTime {
    /// "m:ss" or "h:mm:ss", with the digits and separators of the current locale.
    static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// Spoken form for VoiceOver, e.g. "2 minutes, 5 seconds".
    static func spoken(_ interval: TimeInterval) -> String {
        Duration.seconds(max(0, interval).rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

#Preview {
    WatchChannelView(viewModel: AVPlayerViewModel())
}
