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
                .transition(.opacity)
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

private struct PlayerChrome: View {
    let viewModel: AVPlayerViewModel
    @Binding var isScrubbing: Bool
    @Binding var isShowingRecordings: Bool
    let interacted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PlayerTopBar(viewModel: viewModel, timeline: viewModel.timeline, isShowingRecordings: $isShowingRecordings, interacted: interacted)
            Spacer(minLength: 0)
            PlayerBottomBar(viewModel: viewModel, isScrubbing: $isScrubbing, interacted: interacted)
        }
        .background {
            // Scrims keep white controls legible on bright video.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 240)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

private struct PlayerTopBar: View {
    static let logoSize = CGSize(width: 56, height: 38)

    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    @Binding var isShowingRecordings: Bool
    let interacted: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.isPresented = false
            } label: {
                Image(systemName: closeSymbol)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
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
                Text(viewModel.currentChannel?.name ?? "No channel")
                    .font(.headline)
                    .lineLimit(1)
                PlayerStatusBadges(viewModel: viewModel, timeline: timeline)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if viewModel.isPictureInPictureSupported {
                Button {
                    interacted()
                    viewModel.togglePictureInPicture()
                } label: {
                    Image(systemName: viewModel.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(!viewModel.isPictureInPicturePossible && !viewModel.isPictureInPictureActive)
                .accessibilityLabel(viewModel.isPictureInPictureActive ? "Exit Picture in Picture" : "Picture in Picture")
                .help("Picture in Picture")
            }

            RoutePicker(player: viewModel.player)
                .frame(width: 36, height: 36)
                .accessibilityLabel("AirPlay")
                .help("AirPlay")

            #if os(macOS)
            Button {
                interacted()
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
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
                    .frame(width: 22, height: 22)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("More")
        }
        .controlSize(.large)
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

/// Live / time-shift / buffering status and the recording indicator.
private struct PlayerStatusBadges: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline

    var body: some View {
        HStack(spacing: 8) {
            status

            if viewModel.isRecording {
                RecordingBadge(duration: timeline.recordingDuration)
            }
        }
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
            if viewModel.isTimeShiftAvailable && !(timeline.isAtLiveEdge && viewModel.playbackState == .playing) {
                PlayerBadge(text: "-\(PlayerTime.format(timeline.timeBehindLive))", systemImage: "clock.arrow.circlepath", tint: .yellow)
                    .accessibilityLabel("\(PlayerTime.spoken(timeline.timeBehindLive)) behind live")
            } else if isLive && viewModel.playbackState == .playing {
                LiveBadge()
            } else if viewModel.playbackState == .paused {
                PlayerBadge(text: "Paused", systemImage: "pause.fill", tint: .secondary)
            } else {
                PlayerBadge(text: "Playing", systemImage: "play.fill", tint: .secondary)
            }
        }
    }

    private var isLive: Bool {
        viewModel.isTimeShiftAvailable || viewModel.currentChannel?.isLiveContent == true || (timeline.duration == 0 && !viewModel.canSeek)
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
        } else {
            Text(text)
                .foregroundStyle(tint)
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

private struct RecordingBadge: View {
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.3]) { dot, opacity in
                    dot.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.8)
                }
            Text("REC \(PlayerTime.format(duration))")
        }
        .foregroundStyle(.red)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(PlayerTime.spoken(duration))")
    }
}

// MARK: - Bottom bar

private struct PlayerBottomBar: View {
    let viewModel: AVPlayerViewModel
    @Binding var isScrubbing: Bool
    let interacted: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let error = viewModel.recordingError {
                Button {
                    viewModel.clearRecordingError()
                } label: {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                .buttonStyle(.glass)
                .accessibilityHint("Dismisses the message")
            }

            PlayerTimelineBar(viewModel: viewModel, timeline: viewModel.timeline, isScrubbing: $isScrubbing, interacted: interacted)

            ViewThatFits(in: .horizontal) {
                // Wide: secondary actions on both sides of the transport.
                HStack(spacing: 16) {
                    RecordButton(viewModel: viewModel, interacted: interacted)
                        .frame(minWidth: 150, alignment: .leading)
                    Spacer(minLength: 0)
                    PlayerTransport(viewModel: viewModel, timeline: viewModel.timeline, interacted: interacted)
                    Spacer(minLength: 0)
                    GoLiveButton(viewModel: viewModel, timeline: viewModel.timeline, interacted: interacted)
                        .frame(minWidth: 150, alignment: .trailing)
                }

                // Compact: the transport on its own row.
                VStack(spacing: 12) {
                    PlayerTransport(viewModel: viewModel, timeline: viewModel.timeline, interacted: interacted)
                    HStack {
                        RecordButton(viewModel: viewModel, interacted: interacted)
                        Spacer(minLength: 0)
                        GoLiveButton(viewModel: viewModel, timeline: viewModel.timeline, interacted: interacted)
                    }
                }
            }
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.bottom, 12)
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

/// Channel down / up, skip back / forward and play / pause.
private struct PlayerTransport: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    let interacted: () -> Void

    var body: some View {
        let back = Int(AVPlayerViewModel.skipBackwardInterval)
        let forward = Int(AVPlayerViewModel.skipForwardInterval)

        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                if viewModel.canZap {
                    transportButton("Previous Channel", systemImage: "backward.end.fill", help: "Previous channel in this group") {
                        viewModel.previousChannel()
                    }
                }

                transportButton("Back \(back) seconds", systemImage: "gobackward.\(back)", help: "Back \(back) seconds") {
                    viewModel.skipBackward()
                }
                .disabled(!viewModel.canSeek)

                Button {
                    interacted()
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .accessibilityLabel(isPaused ? "Play" : "Pause")
                .help(isPaused ? "Play" : "Pause")

                transportButton("Forward \(forward) seconds", systemImage: "goforward.\(forward)", help: "Forward \(forward) seconds") {
                    viewModel.skipForward()
                }
                .disabled(!viewModel.canSeek || (viewModel.isTimeShiftAvailable && timeline.isAtLiveEdge))

                if viewModel.canZap {
                    transportButton("Next Channel", systemImage: "forward.end.fill", help: "Next channel in this group") {
                        viewModel.nextChannel()
                    }
                }
            }
        }
    }

    private var isPaused: Bool {
        switch viewModel.playbackState {
        case .paused, .ended, .failed, .idle:
            return true
        default:
            return false
        }
    }

    private func transportButton(_ label: String, systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            interacted()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
        .help(help)
    }
}

private struct RecordButton: View {
    let viewModel: AVPlayerViewModel
    let interacted: () -> Void

    var body: some View {
        if viewModel.canRecord || viewModel.isRecording {
            Button {
                interacted()
                viewModel.toggleRecording()
            } label: {
                Label(viewModel.isRecording ? "Stop" : "Record", systemImage: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.glass)
            .accessibilityLabel(viewModel.isRecording ? "Stop Recording" : "Record")
            .help(viewModel.isRecording ? "Stop recording" : "Record this channel")
        }
    }
}

private struct GoLiveButton: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    let interacted: () -> Void

    var body: some View {
        if viewModel.isTimeShiftAvailable {
            Button {
                interacted()
                viewModel.goLive()
            } label: {
                Label("Go Live", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(timeline.isAtLiveEdge ? Color.secondary : Color.red)
            }
            .buttonStyle(.glass)
            .disabled(timeline.isAtLiveEdge)
            .help("Jump to the live edge")
        }
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
