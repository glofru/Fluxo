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
/// - Top bar: close, channel logo and name, status (connecting / buffering / live / time-shifted / recording),
///   Picture in Picture, AirPlay and a menu (fill / fit, recordings, stop).
/// - Bottom bar: the timeline (on-demand position or time-shift window), channel down / up within the group,
///   skip back / forward, play / pause, Go Live and record.
///
/// Controls hide after a few seconds of playback without interaction; a tap (or moving the mouse on macOS)
/// shows them again. They never hide while paused, failed, scrubbing or with VoiceOver running.
struct WatchChannelView: View {

    static let autoHideDelay: Duration = .seconds(4)

    let viewModel: AVPlayerViewModel

    @State private var controlsVisible = true
    /// Bumped by every interaction; restarts the auto-hide countdown.
    @State private var interactionCount = 0
    @State private var isScrubbing = false
    @State private var isShowingRecordings = false
    @State private var hoverThrottle = HoverThrottle()

    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            AVVideoPlayer(surface: viewModel.surface)
                .ignoresSafeArea()
                .onAppear {
                    viewModel.playerViewDidAppear()
                }
                .onDisappear {
                    viewModel.playerViewDidDisappear()
                }
                .accessibilityHidden(true)

            tapTarget

            // Escape closes the player even while the controls are hidden.
            Button("Close Player") {
                viewModel.isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            PlayerStatusOverlay(viewModel: viewModel)

            if controlsVisible {
                PlayerChrome(
                    viewModel: viewModel,
                    isScrubbing: $isScrubbing,
                    isShowingRecordings: $isShowingRecordings,
                    interacted: registerInteraction
                )
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        #if os(macOS)
        // The player is an overlay inside the main window: only its own subtree goes dark, so the window
        // (and the browser underneath) keeps the system appearance.
        .environment(\.colorScheme, .dark)
        #else
        .preferredColorScheme(.dark)
        #endif
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
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
        .onChange(of: viewModel.currentChannel?.id) {
            // Zapped to another channel: show its name and status.
            showControls()
        }
        .onChange(of: viewModel.playbackState) { _, state in
            if state != .playing {
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
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        #endif
        .sensoryFeedback(.selection, trigger: viewModel.currentChannel?.id)
        .sensoryFeedback(trigger: viewModel.isRecording) { _, isRecording in
            isRecording ? .impact(weight: .medium) : .success
        }
        .sheet(isPresented: $isShowingRecordings) {
            RecordingsView(store: viewModel.recordings, isRecordingActive: viewModel.isRecording) { recording in
                isShowingRecordings = false
                viewModel.playRecording(recording)
            }
            .presentationDetents([.medium, .large])
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

    private var canAutoHide: Bool {
        controlsVisible && viewModel.playbackState == .playing && !isScrubbing && !isShowingRecordings && !isVoiceOverEnabled
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

/// Glass for the player's floating controls: interactive, identified in the cluster's namespace so it morphs
/// when a control appears, disappears or changes state, and optionally merged with its neighbours.
private extension View {
    func playerGlass(_ glass: Glass = .regular, in shape: some Shape = Circle(), id: String, union: String? = nil, namespace: Namespace.ID) -> some View {
        self
            .glassEffect(glass.interactive(), in: shape)
            .glassEffectUnion(id: union, namespace: namespace)
            .glassEffectID(id, in: namespace)
    }
}

private struct PlayerChrome: View {
    let viewModel: AVPlayerViewModel
    @Binding var isScrubbing: Bool
    @Binding var isShowingRecordings: Bool
    let interacted: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            PlayerTopBar(viewModel: viewModel, isShowingRecordings: $isShowingRecordings, interacted: interacted)
            Spacer(minLength: 0)
            PlayerBottomBar(viewModel: viewModel, isScrubbing: $isScrubbing, interacted: interacted)
        }
        .background {
            // Scrims keep the title and the timeline legible on bright video (stronger without transparency).
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(reduceTransparency ? 0.9 : 0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(reduceTransparency ? 0.92 : 0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

private struct PlayerTopBar: View {
    static let logoSize = CGSize(width: 56, height: 38)
    static let buttonSize: CGFloat = 44

    let viewModel: AVPlayerViewModel
    @Binding var isShowingRecordings: Bool
    let interacted: () -> Void

    @Namespace private var glassNamespace

    var body: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.isPresented = false
            } label: {
                Image(systemName: closeSymbol)
                    .font(.body.weight(.semibold))
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close Player")
            .help("Close the player (playback continues)")

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
                    Text(viewModel.currentChannel?.name ?? "No channel")
                        .font(.headline)
                        .lineLimit(1)
                    PlayerStatusBadges(viewModel: viewModel, timeline: viewModel.timeline)
                }
                .accessibilityElement(children: .combine)
                // Now / next from the TV guide (live channels with a guide only).
                PlayerProgrammeInfo(item: viewModel.currentItem)
            }

            Spacer(minLength: 8)

            // One glass capsule for the secondary actions.
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 0) {
                    if viewModel.isPictureInPictureSupported {
                        Button {
                            interacted()
                            viewModel.togglePictureInPicture()
                        } label: {
                            Image(systemName: viewModel.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: Self.buttonSize, height: Self.buttonSize)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.isPictureInPicturePossible && !viewModel.isPictureInPictureActive)
                        .playerGlass(id: "top.pip", union: "top.actions", namespace: glassNamespace)
                        .accessibilityLabel(viewModel.isPictureInPictureActive ? "Exit Picture in Picture" : "Picture in Picture")
                        .help("Picture in Picture")
                    }

                    RoutePicker(player: viewModel.player)
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                        .playerGlass(id: "top.airplay", union: "top.actions", namespace: glassNamespace)
                        .accessibilityLabel("AirPlay")
                        .help("AirPlay")

                    #if os(macOS)
                    Button {
                        interacted()
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: Self.buttonSize, height: Self.buttonSize)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .playerGlass(id: "top.fullscreen", union: "top.actions", namespace: glassNamespace)
                    .accessibilityLabel("Full Screen")
                    .help("Enter or exit full screen")
                    #endif

                    Menu {
                        Button(viewModel.fillsScreen ? "Fit to Screen" : "Fill Screen", systemImage: viewModel.fillsScreen ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward") {
                            viewModel.toggleFillsScreen()
                        }
                        Button("Recordings", systemImage: "film.stack") {
                            isShowingRecordings = true
                        }
                        Divider()
                        Button("Stop Playback", systemImage: "stop.fill", role: .destructive) {
                            viewModel.stop()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: Self.buttonSize, height: Self.buttonSize)
                            .contentShape(.circle)
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .playerGlass(id: "top.more", union: "top.actions", namespace: glassNamespace)
                    .accessibilityLabel("More")
                }
            }
        }
        .font(.body.weight(.medium))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var closeSymbol: String {
        #if os(macOS)
        return "xmark"
        #else
        return "chevron.down"
        #endif
    }
}

/// Connection, buffering, error, paused and live status under the title. Live / time-shift position and
/// the recording indicator live in the bottom controls when time-shift is available.
private struct PlayerStatusBadges: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline

    var body: some View {
        status
            .font(.caption.weight(.semibold).monospacedDigit())
    }

    @ViewBuilder
    private var status: some View {
        switch viewModel.playbackState {
        case .connecting:
            busyBadge("Connecting…")
        case .buffering:
            busyBadge("Buffering…")
        case .reconnecting:
            PlayerBadge(text: viewModel.playbackState.label, systemImage: "wifi.exclamationmark", tint: .orange)
        case .failed:
            PlayerBadge(text: "Error", systemImage: "exclamationmark.triangle.fill", tint: .yellow)
        case .ended:
            PlayerBadge(text: "Ended", systemImage: "checkmark.circle", tint: .secondary)
        case .idle:
            PlayerBadge(text: "Idle", systemImage: nil, tint: .secondary)
        case .playing, .paused:
            if viewModel.playbackState == .paused {
                PlayerBadge(text: "Paused", systemImage: "pause.fill", tint: .secondary)
            } else if viewModel.isTimeShiftAvailable {
                // The bottom live control shows LIVE or the time behind live.
                if let group = viewModel.currentItem?.groupName, !group.isEmpty {
                    PlayerBadge(text: group, systemImage: nil, tint: .secondary)
                }
            } else if isLive {
                LiveBadge()
            } else {
                PlayerBadge(text: "Playing", systemImage: "play.fill", tint: .secondary)
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
        .foregroundStyle(.secondary)
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

private struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.red, in: .capsule)
            .foregroundStyle(.white)
            .accessibilityLabel("Live")
    }
}

// MARK: - Bottom bar

/// The floating glass controls: record on the leading side, the transport in the middle and the live
/// control on the trailing side. They share one `GlassEffectContainer`, so the glass morphs when the state
/// changes: play / pause retints, the record button stretches into the recording timer, the LIVE indicator
/// turns into "Go Live" when the stream is time-shifted, and the channel buttons merge into the skip capsules.
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
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityHint("Dismisses the message")
                .transition(.opacity)
            }

            PlayerTimelineBar(viewModel: viewModel, timeline: viewModel.timeline, isScrubbing: $isScrubbing, interacted: interacted)

            GlassEffectContainer(spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    // Wide: secondary actions on both sides of the transport.
                    HStack(spacing: 16) {
                        RecordControl(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                            .frame(minWidth: 170, alignment: .leading)
                        Spacer(minLength: 0)
                        PlayerTransport(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                        Spacer(minLength: 0)
                        LiveControl(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                            .frame(minWidth: 170, alignment: .trailing)
                    }

                    // Compact: the transport on its own row.
                    VStack(spacing: 14) {
                        PlayerTransport(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                        HStack {
                            RecordControl(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                            Spacer(minLength: 0)
                            LiveControl(viewModel: viewModel, timeline: viewModel.timeline, namespace: glassNamespace, interacted: interacted)
                        }
                    }
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: MorphState(viewModel))
        }
        .font(.body.weight(.medium))
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

        @MainActor
        init(_ viewModel: AVPlayerViewModel) {
            isPaused = PlayerTransport.isPaused(viewModel.playbackState)
            isRecording = viewModel.isRecording
            canRecord = viewModel.canRecord
            canZap = viewModel.canZap
            isTimeShiftAvailable = viewModel.isTimeShiftAvailable
            hasRecordingError = viewModel.recordingError != nil
        }
    }
}

/// Position in an on-demand item, or in the time-shift window of a live stream.
/// Observes the timeline, which changes twice a second.
private struct PlayerTimelineBar: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    @Binding var isScrubbing: Bool
    let interacted: () -> Void

    @State private var scrubPosition: Double = 0

    var body: some View {
        if viewModel.canSeek {
            let lower = timeline.seekableStart
            let upper = max(lower + 1, timeline.seekableEnd)
            let position = isScrubbing ? scrubPosition : min(max(timeline.currentTime, lower), upper)
            let isLive = viewModel.isTimeShiftAvailable

            HStack(spacing: 12) {
                Text(isLive ? "-\(PlayerTime.format(upper - position))" : PlayerTime.format(position))
                    .frame(minWidth: 52, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { position },
                        set: { value in
                            scrubPosition = value
                            interacted()
                            if !isScrubbing {
                                // Keyboard and accessibility adjustments have no editing phase.
                                viewModel.seek(toSeconds: value)
                            }
                        }
                    ),
                    in: lower...upper
                ) { editing in
                    if editing {
                        scrubPosition = position
                        isScrubbing = true
                    } else {
                        viewModel.seek(toSeconds: scrubPosition)
                        isScrubbing = false
                    }
                }
                .tint(isLive ? .red : .white)
                .accessibilityLabel(isLive ? "Time-shift position" : "Playback position")
                .accessibilityValue(isLive ? "\(PlayerTime.spoken(upper - position)) behind live" : "\(PlayerTime.spoken(position)) of \(PlayerTime.spoken(upper))")

                Text(isLive ? PlayerTime.format(upper - lower) : "-\(PlayerTime.format(upper - position))")
                    .frame(minWidth: 52, alignment: .trailing)
                    .accessibilityLabel(isLive ? "Time-shift buffer \(PlayerTime.spoken(upper - lower))" : "\(PlayerTime.spoken(upper - position)) remaining")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// Channel down / up, skip back / forward and play / pause. Channel and skip buttons merge into one glass
/// capsule on each side; play / pause is a larger circle, tinted with the accent color while paused.
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
                    transportButton("Previous Channel", systemImage: "backward.end.fill", help: "Previous channel in this group", id: "transport.previous", union: "transport.back") {
                        viewModel.previousChannel()
                    }
                }

                transportButton("Back \(back) seconds", systemImage: "gobackward.\(back)", help: "Back \(back) seconds", id: "transport.back", union: "transport.back") {
                    viewModel.skipBackward()
                }
                .disabled(!viewModel.canSeek)
            }

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
            .playerGlass(isPaused ? .regular.tint(.accentColor) : .regular, id: "transport.play", namespace: namespace)
            .sensoryFeedback(.impact(weight: .light), trigger: playPauseTaps)
            .accessibilityLabel(isPaused ? "Play" : "Pause")
            .help(isPaused ? "Play" : "Pause")

            HStack(spacing: 0) {
                transportButton("Forward \(forward) seconds", systemImage: "goforward.\(forward)", help: "Forward \(forward) seconds", id: "transport.forward", union: "transport.forward") {
                    viewModel.skipForward()
                }
                .disabled(!viewModel.canSeek || (viewModel.isTimeShiftAvailable && timeline.isAtLiveEdge))

                if viewModel.canZap {
                    transportButton("Next Channel", systemImage: "forward.end.fill", help: "Next channel in this group", id: "transport.next", union: "transport.forward") {
                        viewModel.nextChannel()
                    }
                }
            }
        }
    }

    private func transportButton(_ label: String, systemImage: String, help: String, id: String, union: String, action: @escaping () -> Void) -> some View {
        Button {
            interacted()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .playerGlass(id: id, union: union, namespace: namespace)
        .accessibilityLabel(label)
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
                        .foregroundStyle(.red)
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
            .playerGlass(.regular.tint(.red.opacity(0.45)), in: .capsule, id: "record", namespace: namespace)
            .accessibilityLabel("Stop Recording")
            .accessibilityValue(PlayerTime.spoken(timeline.recordingDuration))
            .help("Stop recording")
        } else if viewModel.canRecord {
            Button {
                interacted()
                viewModel.toggleRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                    Text("Record")
                }
                .padding(.horizontal, 16)
                .frame(height: PlayerTransport.buttonSize)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .playerGlass(in: .capsule, id: "record", namespace: namespace)
            .accessibilityLabel("Record")
            .help("Record this channel")
        }
    }
}

/// Time-shifted live streams: a red-tinted LIVE indicator at the live edge, which morphs into a
/// "-m:ss · Go Live" button when playback is behind live.
private struct LiveControl: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    let namespace: Namespace.ID
    let interacted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var goLiveTaps = 0

    var body: some View {
        let isAtLive = timeline.isAtLiveEdge && viewModel.playbackState == .playing
        Group {
            if viewModel.isTimeShiftAvailable {
                if isAtLive {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                        Text("LIVE")
                            .font(.callout.weight(.heavy))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: PlayerTransport.buttonSize)
                    .glassEffect(.regular.tint(.red.opacity(0.55)), in: .capsule)
                    .glassEffectID("live", in: namespace)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Live")
                } else {
                    Button {
                        interacted()
                        goLiveTaps += 1
                        viewModel.goLive()
                    } label: {
                        HStack(spacing: 8) {
                            Text("-\(PlayerTime.format(timeline.timeBehindLive))")
                                .monospacedDigit()
                                .foregroundStyle(.yellow)
                            Text("Go Live")
                            Image(systemName: "forward.end.alt.fill")
                                .font(.caption)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: PlayerTransport.buttonSize)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .playerGlass(in: .capsule, id: "live", namespace: namespace)
                    .accessibilityLabel("Go Live")
                    .accessibilityValue("\(PlayerTime.spoken(timeline.timeBehindLive)) behind live")
                    .help("Jump to the live edge")
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: isAtLive)
        .sensoryFeedback(.impact(weight: .medium), trigger: goLiveTaps)
    }
}

// MARK: - Status overlay

/// Connection, buffering, error and end-of-stream feedback in the middle of the video.
private struct PlayerStatusOverlay: View {
    let viewModel: AVPlayerViewModel

    var body: some View {
        switch viewModel.playbackState {
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
                tint: .yellow,
                title: "Can't Play This Channel",
                message: message
            ) {
                Button("Try Again", systemImage: "arrow.clockwise") {
                    viewModel.retry()
                }
                .buttonStyle(.glassProminent)
            }
        case .ended:
            PlayerMessageCard(
                systemImage: "checkmark.circle.fill",
                tint: .secondary,
                title: viewModel.isTimeShiftAvailable ? "The Stream Ended" : "Playback Ended",
                message: nil
            ) {
                if viewModel.canSeek {
                    Button("Play Again", systemImage: "arrow.counterclockwise") {
                        viewModel.play()
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        viewModel.retry()
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        default:
            EmptyView()
        }
    }
}

private struct PlayerMessageCard<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            actions()
        }
        .padding(24)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding()
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
        view.activeTintColor = .systemBlue
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
    }
}
#endif

// MARK: - Formatting

enum PlayerTime {
    /// "m:ss" or "h:mm:ss".
    static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    /// Spoken form for VoiceOver, e.g. "2 minutes, 5 seconds".
    static func spoken(_ interval: TimeInterval) -> String {
        Duration.seconds(max(0, interval).rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

#Preview {
    WatchChannelView(viewModel: AVPlayerViewModel())
}
