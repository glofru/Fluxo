//
//  PlayerStatusOverlay.swift
//  Fluxo
//
//  What the player screen (WatchChannelView) shows in the middle of the video: the seek spinner, and the
//  connection, buffering, error and end-of-stream messages.
//

import AVKit
import SwiftUI

#if !os(tvOS)
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
struct PlayerStatusOverlay: View {
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
#endif
