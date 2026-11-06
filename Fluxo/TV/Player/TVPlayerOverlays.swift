//
//  TVPlayerOverlays.swift
//  Fluxo
//
//  What the Apple TV player draws over the system's player, sized to be read from the couch:
//  - before the first frame: the channel (logo, number and name, what is on now) and what the player does, around
//    an activity indicator in the middle of the screen;
//  - a failure: what went wrong in plain words, with Try Again and Close (the focus moves to them; the transport bar
//    is off meanwhile, so the clickpad drives them);
//  - the end of a movie or episode: Play Again and Close, or the next episode of a series with a countdown (Play
//    Now, Cancel). With VoiceOver or Switch Control on, nothing starts by itself;
//  - while the transport bar is hidden: the channel that was just switched to, Reconnecting…, and the recording.
//

#if os(tvOS)
import SwiftUI

// MARK: - Before the first frame

/// The channel and the player's state while nothing plays yet (it covers the system player, black until then).
struct TVPlayerPreroll: View {

    let viewModel: AVPlayerViewModel
    let nowNext: NowNext?

    var body: some View {
        GeometryReader { proxy in
            let item = viewModel.currentItem
            ZStack {
                Color.black
                if let item {
                    TVLandscapeArtwork(item: item, size: CGSize(width: 400, height: 225))
                        .clipShape(.rect(cornerRadius: 20, style: .continuous))
                        // Above the activity indicator, in the middle of the screen.
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2 - 230)
                }
                // The system draws no activity indicator under this screen.
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                VStack(spacing: 14) {
                    Text(TVPlayerTitle.title(of: viewModel))
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let subtitle = TVPlayerTitle.subtitle(of: viewModel) {
                        Text(subtitle)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let current = nowNext?.current {
                        Text(TextParts.line([current.title, GuideFormat.timeRange(current)]))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // Playing before the first picture is still loading, as far as the screen shows.
                    Text(viewModel.playbackState == .playing ? AVPlayerViewModel.PlaybackState.buffering.label : viewModel.playbackState.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 120)
                .frame(maxWidth: 1_300)
                // Below the activity indicator.
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2 + 150)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// The name of what plays, as the screens of the player write it: a channel with its number, an episode as its series
/// and code ("Orbit · S1 E2", not the playlist's raw "Orbit S01E02") with its title under it, a movie by its name, a
/// recording or a stream outside the library by the name it was played with.
@MainActor
enum TVPlayerTitle {

    static func title(of viewModel: AVPlayerViewModel) -> String {
        guard let item = viewModel.currentItem else {
            return viewModel.currentChannel?.name ?? ""
        }
        if let ref = item.series {
            return TextParts.line([ref.seriesTitle, EpisodeFormat.code(ref)])
        }
        if item.kind == .live, let number = item.number {
            return TextParts.line([String(number), item.displayName])
        }
        return item.displayName
    }

    /// The line under the title: an episode's own title ("Encore" under "Orbit · S1 E2"), or when a recording was
    /// made; nil for anything else.
    static func subtitle(of viewModel: AVPlayerViewModel) -> String? {
        if let item = viewModel.currentItem {
            return item.series.map(EpisodeFormat.title)
        }
        return recording(of: viewModel).map(recordedLine)
    }

    /// The recording that plays (recordings play as streams outside the library, by their file).
    static func recording(of viewModel: AVPlayerViewModel) -> Recording? {
        guard viewModel.currentItem == nil, let url = viewModel.currentChannel?.url, url.isFileURL else {
            return nil
        }
        return viewModel.recordings.recordings.first { $0.url == url }
    }

    /// "Recorded Nov 5, 2026 at 8:15 PM".
    static func recordedLine(_ recording: Recording) -> String {
        let date = recording.createdOn.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Recorded \(date)", comment: "Apple TV player: when a recording that plays was made (under its title on the loading screen, its description in the info panel); the placeholder is the date and time, as in 'Nov 5, 2026 at 8:15 PM'.")
    }
}

// MARK: - Failure and end

/// A screen of the player that takes the focus: a symbol, a title, a message and its buttons, centered over the
/// darkened picture.
struct TVPlayerMessageView<Buttons: View>: View {

    let systemImage: String
    let tint: Color
    let title: String
    let message: String?
    /// A technical detail under the message, smaller (the engine's reason of a failure).
    var detail: String?
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
            VStack(spacing: 28) {
                Image(systemName: systemImage)
                    .font(.system(size: 88, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(spacing: 14) {
                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    if let message, !message.isEmpty {
                        Text(message)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 40) {
                    buttons()
                }
                // As the system player's own buttons (the info panel's): white when focused, translucent white
                // when not, readable over black from the couch (the app's violet tint made them navy on black).
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.top, 20)
                .focusSection()
            }
            .padding(100)
            .frame(maxWidth: 1_300)
        }
        .ignoresSafeArea()
        // Dark whatever the system appearance: white text. Not a white foreground style, which the buttons would
        // inherit (a white label on the focused button's white).
        .environment(\.colorScheme, .dark)
    }
}

/// Playback failed: why, Try Again and Close.
struct TVPlayerFailureView: View {

    let viewModel: AVPlayerViewModel
    let message: String

    @FocusState private var focus: Focus?

    private enum Focus {
        case retry
    }

    var body: some View {
        TVPlayerMessageView(
            systemImage: viewModel.isWaitingForNetwork ? "wifi.exclamationmark" : "exclamationmark.triangle.fill",
            tint: Theme.warning,
            title: title,
            message: explanation ?? message,
            detail: explanation == nil ? nil : message
        ) {
            Button {
                viewModel.retry()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(minWidth: 260)
            }
            .focused($focus, equals: .retry)
            if canChangeChannel {
                // A live channel that does not play: the next one, as channel up would (the system player's channel
                // buttons are off while this screen has the focus).
                Button {
                    viewModel.zap(by: 1)
                } label: {
                    Label("Next Channel", systemImage: "chevron.up")
                        .frame(minWidth: 260)
                }
                .accessibilityHint(Text("Plays the next channel of the category", comment: "VoiceOver hint of Next Channel on the Apple TV player's failure screen of a live channel."))
            }
            Button {
                viewModel.closePlayer()
            } label: {
                Text("Close")
                    .frame(minWidth: 220)
            }
        }
        .defaultFocus($focus, .retry)
        // Up and down change the channel, as on the video (the buttons sit in one row: nothing else takes them).
        .onMoveCommand { direction in
            guard canChangeChannel else {
                return
            }
            switch direction {
            case .up:
                viewModel.zap(by: 1)
            case .down:
                viewModel.zap(by: -1)
            default:
                break
            }
        }
        .task {
            // Once more after the system player gave up the focus (its controls turn off with this screen).
            focus = .retry
            try? await Task.sleep(for: .milliseconds(300))
            focus = .retry
        }
    }

    /// A live channel of a playlist, with others in its category, and not recording.
    private var canChangeChannel: Bool {
        guard viewModel.canZap, let item = viewModel.currentItem else {
            return false
        }
        return viewModel.zapper?.neighbor(of: item, offset: 1) != nil
    }

    /// What the engine's or AVFoundation's reason means, in plain words, for the failures a server commonly causes
    /// (the reason, from FFmpeg or the system, is in English and stays under it as a detail); nil for any other.
    private var explanation: String? {
        guard !viewModel.isWaitingForNetwork else {
            // Already in plain words (offline).
            return nil
        }
        return TVPlayerFailureText.explanation(for: message)
    }

    private var title: String {
        let name = TVPlayerTitle.title(of: viewModel)
        if !name.isEmpty {
            return String(localized: "Can’t Play “\(name)”", comment: "Apple TV player: title of the screen shown when a channel or video cannot be played; the placeholder is its name.")
        }
        return String(localized: "Can’t Play This", comment: "Apple TV player: title of the screen shown when a stream without a name cannot be played.")
    }
}

/// Plain words for the technical reason of a failure.
enum TVPlayerFailureText {

    /// A sentence for a reason that names a common server or network failure; nil for any other.
    static func explanation(for reason: String) -> String? {
        let reason = reason.lowercased()
        func mentions(_ parts: String...) -> Bool {
            parts.contains { reason.contains($0) }
        }
        if mentions("connection refused", "could not connect to the server") {
            return String(localized: "The server isn’t accepting connections. Check that it’s running, then try again.", comment: "Apple TV player, failure screen: the stream's server refused the connection (it is down or the address is wrong). The technical reason shows under it.")
        }
        if mentions("timed out", "timeout") {
            return String(localized: "The server didn’t respond in time. Try again in a moment.", comment: "Apple TV player, failure screen: the stream's server did not answer. The technical reason shows under it.")
        }
        if mentions("failed to resolve", "name or service not known", "nodename nor servname", "server with the specified hostname could not be found") {
            return String(localized: "The server couldn’t be found. Check the playlist’s address and your network.", comment: "Apple TV player, failure screen: the host name of the stream's server does not resolve. The technical reason shows under it.")
        }
        if mentions("server returned 401", "server returned 403", "unauthorized", "forbidden", "access denied") {
            return String(localized: "The server refused access to this stream. Check your playlist’s account.", comment: "Apple TV player, failure screen: the stream's server answered 401 or 403 (the subscription or credentials). The technical reason shows under it.")
        }
        if mentions("server returned 404", "404 not found") {
            return String(localized: "The server doesn’t have this stream. The playlist may be out of date.", comment: "Apple TV player, failure screen: the stream's server answered 404. The technical reason shows under it.")
        }
        if mentions("server returned 5", "internal server error", "bad gateway", "service unavailable") {
            return String(localized: "The server has a problem right now. Try again later.", comment: "Apple TV player, failure screen: the stream's server answered with a 5xx error. The technical reason shows under it.")
        }
        return nil
    }
}

/// A movie, episode or recording played to the end (and the series has no next episode, or its countdown was
/// cancelled): Play Again, the next episode when there is one, and Close.
struct TVPlayerEndView: View {

    let viewModel: AVPlayerViewModel
    let next: ChannelItem?
    let playNext: (ChannelItem) -> Void

    @FocusState private var focus: Focus?

    private enum Focus {
        case primary
    }

    var body: some View {
        TVPlayerMessageView(
            systemImage: "checkmark.circle.fill",
            tint: Theme.accent,
            title: TVPlayerTitle.title(of: viewModel),
            message: String(localized: "Finished", comment: "Apple TV player: the movie, episode or recording played to its end.")
        ) {
            if let next {
                Button {
                    playNext(next)
                } label: {
                    Label("Play Next Episode", systemImage: "forward.end.fill")
                        .frame(minWidth: 320)
                }
                .focused($focus, equals: .primary)
                Button {
                    viewModel.play()
                } label: {
                    Label("Play Again", systemImage: "arrow.counterclockwise")
                        .frame(minWidth: 260)
                }
            } else {
                Button {
                    viewModel.play()
                } label: {
                    Label("Play Again", systemImage: "arrow.counterclockwise")
                        .frame(minWidth: 260)
                }
                .focused($focus, equals: .primary)
            }
            Button {
                viewModel.closePlayer()
            } label: {
                Text("Close")
                    .frame(minWidth: 220)
            }
        }
        .defaultFocus($focus, .primary)
        .task {
            // Once more after the system player gave up the focus (its controls turn off with this screen).
            focus = .primary
            try? await Task.sleep(for: .milliseconds(300))
            focus = .primary
        }
    }
}

/// The end of an episode with a next one: what comes next and a countdown that plays it.
struct TVNextEpisodeCard: View {

    static let countdown = 10

    let next: ChannelItem
    /// The countdown runs (VoiceOver and Switch Control wait for a choice instead).
    let autoplays: Bool
    let play: () -> Void
    let cancel: () -> Void

    @State private var secondsLeft = TVNextEpisodeCard.countdown
    @FocusState private var focus: Focus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Focus {
        case play
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.55), .clear], startPoint: .bottomLeading, endPoint: .topTrailing)
            HStack(alignment: .bottom, spacing: 48) {
                ChannelLogoTile(item: next, size: next.kind.usesPosterArtwork ? CGSize(width: 260, height: 390) : CGSize(width: 480, height: 270), cornerRadius: 20)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Up Next", comment: "Label of the episode of a series to watch next (Continue Watching, the series page, the player).")
                        .font(.callout.weight(.heavy))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text(next.series?.seriesTitle ?? next.displayName)
                        .font(.title2.bold())
                        .lineLimit(2)
                    if let ref = next.series {
                        Text(TextParts.line([EpisodeFormat.code(ref), EpisodeFormat.title(ref)]))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .accessibilityLabel(Text(TextParts.spoken([EpisodeFormat.spokenCode(ref), EpisodeFormat.title(ref)])))
                    }
                    HStack(spacing: 32) {
                        Button(action: play) {
                            HStack(spacing: 16) {
                                if autoplays {
                                    CountdownRing(fraction: Double(secondsLeft) / Double(Self.countdown))
                                        .frame(width: 34, height: 34)
                                        .accessibilityHidden(true)
                                    Text("Play in \(secondsLeft) s", comment: "Player: the next episode starts after a countdown; the number is the seconds left.")
                                        .monospacedDigit()
                                        .contentTransition(.numericText(countsDown: true))
                                } else {
                                    Image(systemName: "play.fill")
                                    Text("Play Next Episode")
                                }
                            }
                            .frame(minWidth: 320)
                        }
                        .focused($focus, equals: .play)
                        .accessibilityLabel(Text("Play Next Episode"))
                        Button(action: cancel) {
                            Text("Cancel")
                                .frame(minWidth: 200)
                        }
                    }
                    // As on the player's other screens (`TVPlayerMessageView`).
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .padding(.top, 18)
                    .focusSection()
                }
                .frame(maxWidth: 900, alignment: .leading)
            }
            .padding(.horizontal, 110)
            .padding(.bottom, 100)
        }
        .ignoresSafeArea()
        // Dark: white text, and the buttons keep their own label colors (see `TVPlayerMessageView`).
        .environment(\.colorScheme, .dark)
        .defaultFocus($focus, .play)
        .task {
            // Once more after the system player gave up the focus (its controls turn off with this screen).
            focus = .play
            try? await Task.sleep(for: .milliseconds(300))
            focus = .play
        }
        .task(id: autoplays) {
            guard autoplays else {
                return
            }
            AccessibilityAnnouncer.announce(String(localized: "Next episode in \(Self.countdown) seconds", comment: "VoiceOver: the next episode starts after a countdown."))
            secondsLeft = Self.countdown
            while secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else {
                    return
                }
                withAnimation(reduceMotion ? nil : .default) {
                    secondsLeft -= 1
                }
            }
            play()
        }
    }
}

/// The time left of the countdown, as a ring that empties, in the color of the button's label (dark on the focused
/// button's white, white otherwise).
private struct CountdownRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
        }
    }
}

// MARK: - Banners

/// The channel switched to (logo, number, name and what is on now), at the top left for a few seconds, as on a TV.
struct TVChannelBanner: View {

    let item: ChannelItem
    let nowNext: NowNext?

    var body: some View {
        HStack(spacing: 24) {
            TVLandscapeArtwork(item: item, size: CGSize(width: 192, height: 108))
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.number.map { TextParts.line([String($0), item.displayName]) } ?? item.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if let current = nowNext?.current {
                    Text(current.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    TimelineView(.everyMinute) { context in
                        HStack(spacing: 12) {
                            ProgressView(value: current.progress(at: context.date))
                                .tint(Theme.live)
                                .frame(width: 220)
                            Text(GuideFormat.remaining(current, at: context.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if let next = nowNext?.next {
                        Text(TextParts.line([GuideFormat.time(next.start), next.title]))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if !item.groupName.isEmpty {
                    Text(item.groupName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
        .padding(24)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 28, style: .continuous))
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 28, style: .continuous))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

/// A small status capsule (Reconnecting…, the recording): a symbol or a spinner and a label.
struct TVPlayerStatusPill: View {

    let label: String
    var systemImage: String?
    var tint: Color = .white
    var showsProgress = false

    var body: some View {
        HStack(spacing: 14) {
            if showsProgress {
                ProgressView()
                    .tint(.white)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(.black.opacity(0.45), in: .capsule)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}
#endif
