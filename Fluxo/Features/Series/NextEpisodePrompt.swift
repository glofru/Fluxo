//
//  NextEpisodePrompt.swift
//  Fluxo
//
//  "Next Episode" in the player, for an episode of a series:
//  - during the end credits (the last 3 %, at most a minute, of an episode longer than 5 minutes) a glass
//    button plays the next episode at once;
//  - when the episode ends, a card counts down and plays it (Cancel stays on the ended episode, Play Again
//    starts it over). With VoiceOver or Switch Control on, nothing starts by itself: the card says what is next
//    and waits.
//  The next episode is looked up once per episode (`NextEpisodeResolver`), off the main actor.
//

import Observation
import SwiftData
import SwiftUI

/// The next episode of what the player plays, resolved once per episode.
@MainActor
@Observable
final class NextEpisodeResolver {

    static let shared = NextEpisodeResolver()

    /// The episode the lookup was for, and its result (nil: the last episode, or not found).
    private(set) var episode: ChannelItem?
    private(set) var next: ChannelItem?

    @ObservationIgnored
    private var task: Task<Void, Never>?

    /// The next episode after `item` when it has been resolved.
    func next(after item: ChannelItem?) -> ChannelItem? {
        guard let item, item == episode else {
            return nil
        }
        return next
    }

    func resolve(after item: ChannelItem?, container: ModelContainer) {
        guard item != episode else {
            return
        }
        task?.cancel()
        episode = item
        next = nil
        guard let item, item.series != nil else {
            return
        }
        task = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                SeriesLookup.nextEpisode(after: item, in: container)
            }.value
            guard !Task.isCancelled, let self, self.episode == item else {
                return
            }
            self.next = found
        }
    }

    /// Whether the player's end-of-video card is replaced by the next-episode card.
    static func handlesEnd(of viewModel: AVPlayerViewModel) -> Bool {
        shared.next(after: viewModel.currentItem) != nil && !viewModel.isTimeShiftAvailable
    }
}

/// The player's next-episode button and end card (see the file comment). Put it over the video, under the
/// controls' layer.
struct NextEpisodeOverlay: View {

    static let countdown = 8

    let viewModel: AVPlayerViewModel
    /// The controls are on screen: the button sits above the bottom bar.
    let controlsVisible: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.playChannel) private var playChannel
    @Environment(\.accessibilityEnabled) private var isAssistiveTechnologyEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resolver = NextEpisodeResolver.shared
    /// The episode the viewer cancelled the countdown for.
    @State private var cancelledFor: ChannelItem?

    var body: some View {
        let current = viewModel.currentItem
        let next = resolver.next(after: current)
        ZStack {
            if let next, let current, current.series != nil {
                if viewModel.playbackState == .ended && !viewModel.isTimeShiftAvailable {
                    NextEpisodeEndCard(
                        next: next,
                        autoplays: cancelledFor != current && !isAssistiveTechnologyEnabled,
                        play: { play(next) },
                        playAgain: { viewModel.play() },
                        cancel: { cancelledFor = current }
                    )
                    .id(current)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                } else {
                    CreditsButton(viewModel: viewModel, next: next) {
                        play(next)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, controlsVisible ? Self.controlsClearance : 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: viewModel.playbackState == .ended)
        .onChange(of: viewModel.currentItem, initial: true) { _, item in
            resolver.resolve(after: item, container: modelContext.container)
        }
    }

    /// Room for the bottom bar (timeline and transport).
    private static var controlsClearance: CGFloat {
        #if os(macOS)
        return 110
        #else
        return 150
        #endif
    }

    private func play(_ next: ChannelItem) {
        if let ref = next.series {
            AccessibilityAnnouncer.announce(String(localized: "Playing \(EpisodeFormat.spokenCode(ref))", comment: "VoiceOver: the next episode starts; the placeholder is its season and episode, as in 'Season 1, episode 4'."))
        }
        playChannel(next)
    }
}

/// "Next Episode" during the end credits. Only its own view follows the timeline (twice a second).
private struct CreditsButton: View {

    /// Episodes shorter than this have no credits worth skipping.
    static let minimumDuration: TimeInterval = 300

    let viewModel: AVPlayerViewModel
    let next: ChannelItem
    let action: () -> Void

    var body: some View {
        let timeline = viewModel.timeline
        let duration = timeline.duration
        let remaining = duration - timeline.currentTime
        let window = min(60, duration * 0.03)
        if duration >= Self.minimumDuration, remaining > 1, remaining <= window, viewModel.playbackState == .playing || viewModel.playbackState == .paused {
            Button(action: action) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Next Episode")
                            .font(.headline)
                        if let ref = next.series {
                            Text(TextParts.line([EpisodeFormat.code(ref), ref.episodeTitle]))
                                .font(.caption)
                                .foregroundStyle(Theme.Player.secondaryLabel)
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: "forward.end.fill")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            // Glass buttons draw their label in the tint (the app's accent otherwise).
            .tint(.white)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityLabel(Text("Next Episode"))
            .accessibilityValue(Text(next.series.map { TextParts.spoken([EpisodeFormat.spokenCode($0), $0.episodeTitle]) } ?? ""))
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }
}

/// The end of an episode: what comes next, a countdown ring, Play Now, Play Again and Cancel.
private struct NextEpisodeEndCard: View {

    let next: ChannelItem
    let autoplays: Bool
    let play: () -> Void
    let playAgain: () -> Void
    let cancel: () -> Void

    @State private var secondsLeft = NextEpisodeOverlay.countdown

    var body: some View {
        VStack(spacing: 14) {
            Text("Up Next", comment: "Label of the episode of a series to watch next (Continue Watching, the series page, the player).")
                .font(.caption.weight(.heavy))
                .textCase(.uppercase)
                .foregroundStyle(Theme.Player.secondaryLabel)
            HStack(spacing: 14) {
                ChannelLogoTile(item: next, size: CGSize(width: 54, height: 81), cornerRadius: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(next.series?.seriesTitle ?? next.displayName)
                        .font(.headline)
                        .lineLimit(2)
                    if let ref = next.series {
                        Text(TextParts.line([EpisodeFormat.code(ref), EpisodeFormat.title(ref)]))
                            .font(.subheadline)
                            .foregroundStyle(Theme.Player.secondaryLabel)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: play) {
                        Label {
                            if autoplays {
                                Text("Play in \(secondsLeft) s", comment: "Player: the next episode starts after a countdown; the number is the seconds left.")
                                    .monospacedDigit()
                                    .contentTransition(.numericText(countsDown: true))
                            } else {
                                Text("Play Next Episode")
                            }
                        } icon: {
                            Image(systemName: "play.fill")
                        }
                        .font(.headline)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentFill)

                    if autoplays {
                        Button("Cancel", action: cancel)
                            .buttonStyle(.glass)
                            // Glass buttons draw their label in the tint (the app's accent otherwise).
                            .tint(.white)
                    } else {
                        Button("Play Again", systemImage: "arrow.counterclockwise", action: playAgain)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(maxWidth: 400)
        // Darkened, so the text stays readable over bright video (the tint of the glass alone stays too light).
        .background(.black.opacity(0.45), in: .rect(cornerRadius: 24))
        .glassEffect(.regular.tint(.black.opacity(0.4)), in: .rect(cornerRadius: 24))
        .padding(.horizontal)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .task(id: autoplays) {
            guard autoplays else {
                return
            }
            AccessibilityAnnouncer.announce(String(localized: "Next episode in \(NextEpisodeOverlay.countdown) seconds", comment: "VoiceOver: the next episode starts after a countdown."))
            secondsLeft = NextEpisodeOverlay.countdown
            while secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else {
                    return
                }
                withAnimation {
                    secondsLeft -= 1
                }
            }
            play()
        }
    }
}
