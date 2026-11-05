//
//  ContentView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-05-31.
//

import SwiftUI

struct ContentView: View {

    let viewModel: AVPlayerViewModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(ChannelLibrary.self) private var library
    @Environment(EPGStore.self) private var epg
    @Environment(WindowCoordinator.self) private var coordinator
    /// Selected tab / sidebar item, navigation paths and search text, shared with code outside the screens
    /// (App Intents, the debug routes). One per window (iPad windows each have their own); App Intents move the
    /// one of the window used last (see `WindowCoordinator.intentNavigation`).
    @State private var navigation: AppNavigation
    /// Identifies this window to the `WindowCoordinator`.
    @State private var windowID = UUID()

    init(viewModel: AVPlayerViewModel, navigation: AppNavigation) {
        self.viewModel = viewModel
        _navigation = State(initialValue: navigation)
    }

    var body: some View {
        root
            // The player grows out of the card or the mini player that opened it, and follows the finger down.
            // With several windows (iPad) it shows in one of them: the one it was opened from.
            .playerPresentation(
                isPresented: coordinator.shows(.player, in: windowID, isActive: viewModel.isPresented),
                isVisible: !viewModel.isClosingIntoPictureInPicture,
                sourceID: viewModel.presentationSourceID,
                onDismiss: viewModel.closePlayer
            ) {
                WatchChannelView(viewModel: viewModel)
                    // Full Guide in the player's channel guide: the player closes (playback continues, in Picture in
                    // Picture when it can) and this window's TV guide shows the channel.
                    .environment(\.openChannelGuide, OpenChannelGuideAction { [viewModel, navigation] item in
                        viewModel.closePlayer()
                        navigation.showInGuide(item)
                    })
                    // On-screen awareness: "Add this to my favorites" or "Record this" can resolve the channel
                    // that is playing through Siri and Apple Intelligence.
                    .appEntityIdentifier(viewModel.currentItem.flatMap(ChannelEntity.entityIdentifier(for:)))
            }
            // A download that could not start (no space, not a video).
            .downloadNotices()
            // The Copy Link confirmation, over the app and the player.
            .linkCopyFeedbackHost(colorScheme: coordinator.shows(.player, in: windowID, isActive: viewModel.isPresented) ? .dark : nil)
            .windowPresentation(.player, isActive: viewModel.isPresented)
            .playlistManagement()
            .guideManagement(epg)
            .channelScheduleSheet(navigation)
            // URLs and M3U files dropped on the window add a playlist (iPad, macOS).
            .playlistDropDestination()
            .watchProgressRecording(player: viewModel)
            // Announcements are system-wide: with several windows (iPad) only the main window used last speaks.
            .playerAnnouncements(viewModel, isEnabled: coordinator.preferredMainWindowID ?? windowID == windowID)
            .environment(\.playChannel, PlayChannelAction(library: library, player: viewModel, coordinator: coordinator, windowID: windowID))
            .channelWindowOpening(coordinator: coordinator)
            .sensoryFeedback(.selection, trigger: library.favoriteToggleCount)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    viewModel.sceneDidBecomeActive()
                } else if phase == .background {
                    EPGBackgroundRefresh.schedule()
                }
            }
            .task(id: epg.reminders.channelToOpen) {
                // A reminder notification was opened: play its channel.
                // With several windows, the one used last plays it.
                guard let channel = epg.reminders.channelToOpen, coordinator.preferredMainWindowID ?? windowID == windowID else {
                    return
                }
                epg.reminders.channelToOpen = nil
                PlayChannelAction(library: library, player: viewModel, coordinator: coordinator, windowID: windowID)(channel)
            }
            #if os(macOS)
            .onDisappear {
                // The main window was closed: nothing shows the player any more, unless it is in PiP.
                if !viewModel.isPictureInPictureActive {
                    viewModel.stop()
                }
            }
            #endif
            #if os(iOS)
            // The Cast device picker, opened by the cast buttons of the player and the mini player.
            .castDevicePickerSheet(player: viewModel)
            #endif
            #if DEBUG
            .debugAutoplay(viewModel)
            .debugSnapshots()
            .debugHarness(player: viewModel, navigation: navigation)
            #endif
            // The hinge, fold and vertical bar of a foldable iPhone, for the player's two-pane layout.
            .readsDisplayPosture()
            .environment(navigation)
            .focusedSceneValue(navigation)
            .windowScene(windowID, kind: .main, coordinator: coordinator, navigation: navigation)
            .defaultAppStorage(.fluxo)
            .tint(Theme.accent)
    }

    @ViewBuilder
    private var root: some View {
        #if os(macOS)
        MacRootView(player: viewModel)
        #else
        AppTabView(player: viewModel)
        #endif
    }
}

/// The mini player: the tab bar bottom accessory on iOS, a floating glass bar on macOS.
///
/// Expanded (above the tab bar): artwork, title, a status line (casting, live, time-shifted, recording, PiP,
/// buffering), Cast (iOS, when a Cast device is around), play / pause and stop. Inline (next to the minimized
/// tab bar): artwork, title and play / pause only.
/// A tap or a swipe up opens the player, which grows out of it. The channel name gets all the room the
/// buttons leave, at the regular text size (it is never shrunk to fit).
struct PlayerBottomAccessory: View {

    let viewModel: AVPlayerViewModel

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WindowCoordinator.self) private var coordinator: WindowCoordinator?
    @Environment(\.windowID) private var windowID
    @State private var playPauseTaps = 0

    var body: some View {
        if let channel = viewModel.currentChannel {
            let isInline = placement == .inline
            HStack(spacing: isInline ? 8 : 10) {
                artwork(for: channel, isInline: isInline)

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name ?? String(localized: "No channel name", comment: "Shown instead of the name of a channel that has none."))
                        .font(isInline ? .footnote.weight(.semibold) : Theme.Typography.cardTitle)
                        .lineLimit(1)
                    if !isInline {
                        status
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                // One element for VoiceOver ("Sky Sport F1, Live, Sport", in the "Mini Player" container); activating
                // it opens the player.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Now playing. Opens the player")
                .accessibilityAction {
                    openPlayer()
                }
                .accessibilityInputLabels([Text("Now Playing"), Text("Open Player"), Text(channel.name ?? "")])
                // The bar keeps its height: at the accessibility text sizes a long press shows the channel in the
                // Large Content Viewer.
                .accessibilityShowsLargeContentViewer {
                    Label(channel.name ?? String(localized: "No channel name"), systemImage: "play.tv")
                }

                if !isInline {
                    CastButton(cast: viewModel.cast, style: .miniPlayer)
                }

                Button {
                    playPauseTaps += 1
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(isInline ? .body : .title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: isInline ? 32 : 36, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPaused ? "Play" : "Pause")
                .accessibilityInputLabels(isPaused ? [Text("Play"), Text("Resume")] : [Text("Pause")])
                .largeContentControl(isPaused ? String(localized: "Play") : String(localized: "Pause"), systemImage: isPaused ? "play.fill" : "pause.fill")
                .sensoryFeedback(.impact(weight: .light), trigger: playPauseTaps)

                if !isInline {
                    Button {
                        viewModel.stop()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 30, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityLabel("Stop Playback")
                    .accessibilityInputLabels([Text("Stop Playback"), Text("Stop")])
                    .largeContentControl(String(localized: "Stop Playback"), systemImage: "xmark")
                }
            }
            .padding(.leading, isInline ? 6 : 8)
            .padding(.trailing, isInline ? 4 : 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            // A tap anywhere but the buttons, or a swipe up, opens the player. The swipe is simultaneous so that
            // it never blocks the tab bar's own gestures.
            .onTapGesture(perform: openPlayer)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        let upward = -value.translation.height
                        if upward > 24 || -value.velocity.height > 400, upward > abs(value.translation.width) {
                            openPlayer()
                        }
                    }
            )
            .playerTransitionSource(id: PlayerTransition.miniPlayerID, cornerRadius: 24)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mini Player")
            .accessibilityIdentifier("miniPlayer")
            .accessibilityAction(named: "Open Player", openPlayer)
            #if os(iOS)
            .accessibilityAction(.magicTap) {
                viewModel.togglePlayPause()
            }
            #endif
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: placement)
        } else {
            // Not reached: the accessory is disabled while nothing plays (`playerAccessory(isVisible:)`).
            Color.clear
                .accessibilityHidden(true)
        }
    }

    private func openPlayer() {
        // iPad: the player may be on screen in another window; it moves to this one.
        if let coordinator, let windowID {
            coordinator.move(.player, to: windowID)
        }
        viewModel.presentationSourceID = nil
        viewModel.presentPlayer()
    }

    @ViewBuilder
    private func artwork(for channel: PlayableChannel, isInline: Bool) -> some View {
        let size = isInline ? CGSize(width: 28, height: 28) : CGSize(width: 36, height: 36)
        let name = channel.name ?? ""
        ZStack {
            if channel.logo != nil {
                LogoImage(source: channel.logo, size: CGSize(width: size.width - 6, height: size.height - 6), accessibilityLabel: name) { phase in
                    if phase == .unavailable {
                        ArtworkPlaceholder(name: name, kind: .live)
                    } else {
                        Color.clear
                    }
                }
            } else {
                ArtworkPlaceholder(name: name, kind: .live)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: isInline ? 7 : 9, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var status: some View {
        if viewModel.isCasting, let device = viewModel.cast.connectedDevice {
            Label {
                Text("On \(device.name)")
            } icon: {
                CastIcon(connection: .connected(device), size: 12)
            }
            .foregroundStyle(Theme.accent)
        } else if viewModel.castError != nil {
            Label("Can't cast this channel", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
        } else if viewModel.isRecording {
            Label {
                Text("Recording")
            } icon: {
                Image(systemName: "record.circle.fill")
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
            .foregroundStyle(Theme.recording)
        } else if viewModel.isPictureInPictureActive {
            Label("Picture in Picture", systemImage: "pip")
                .foregroundStyle(Theme.secondaryText)
        } else if viewModel.playbackState.isBusy {
            Text(viewModel.playbackState.label)
                .foregroundStyle(Theme.secondaryText)
        } else if isLive && viewModel.playbackState == .playing {
            HStack(spacing: 6) {
                LiveBadge(compact: true)
                if let group = viewModel.currentItem?.groupName, !group.isEmpty {
                    Text(group)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        } else {
            Text(viewModel.playbackState.label)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var isLive: Bool {
        viewModel.isTimeShiftAvailable || viewModel.isCurrentChannelLiveContent
    }

    private var isPaused: Bool {
        switch viewModel.playbackState {
        case .paused, .ended, .failed, .idle:
            return true
        default:
            return false
        }
    }
}

#Preview {
    ContentView(viewModel: AVPlayerViewModel(), navigation: AppNavigation())
        .fluxoPreviewEnvironment()
}
