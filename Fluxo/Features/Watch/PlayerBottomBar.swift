//
//  PlayerBottomBar.swift
//  Fluxo
//
//  The bottom controls of the player screen (WatchChannelView): the timeline and its scrubber, the transport,
//  record and live.
//

import AVKit
import SwiftUI

#if !os(tvOS)
// MARK: - Bottom bar

/// The floating glass controls: record on the leading side, the transport in the middle and the live
/// control on the trailing side. They share one `GlassEffectContainer`, so the glass morphs when the state
/// changes: play / pause retints, the record button stretches into the recording timer, the LIVE indicator
/// turns into "Go Live" when the stream is time-shifted, and the skip capsules grow to take the channel buttons.
struct PlayerBottomBar: View {
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
#endif
