//
//  PlayerChrome.swift
//  Fluxo
//
//  The chrome of the player screen (WatchChannelView): its buttons, the top bar with the channel and its
//  status badges, and the AirPlay route picker.
//

import AVKit
import SwiftUI

#if !os(tvOS)
// MARK: - Chrome

/// Feedback of icon buttons that sit on a shared glass capsule: a soft circle lights up under the finger.
/// (A glass shape per button cannot be used there: it would not line up with the capsule.)
struct PlayerIconButtonStyle: ButtonStyle {
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

struct PlayerChrome: View {
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
#endif
