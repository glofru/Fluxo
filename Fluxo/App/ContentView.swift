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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// Selected tab / sidebar item, navigation paths and search text, shared with code outside the screens.
    @State private var navigation = AppNavigation()

    var body: some View {
        root
            // The player grows out of the card or the mini player that opened it, and follows the finger down.
            .playerPresentation(
                isPresented: viewModel.isPresented,
                isVisible: !viewModel.isClosingIntoPictureInPicture,
                sourceID: viewModel.presentationSourceID,
                onDismiss: viewModel.closePlayer
            ) {
                WatchChannelView(viewModel: viewModel)
            }
            .playlistManagement()
            .guideManagement(epg)
            .channelScheduleSheet(navigation)
            .watchProgressRecording(player: viewModel)
            .environment(\.playChannel, PlayChannelAction(library: library, player: viewModel))
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
                guard let channel = epg.reminders.channelToOpen else {
                    return
                }
                epg.reminders.channelToOpen = nil
                PlayChannelAction(library: library, player: viewModel)(channel)
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
            .sheet(isPresented: Bindable(viewModel.cast).isPickerPresented) {
                CastDevicePicker(cast: viewModel.cast, player: viewModel)
                    .castPickerPresentation(overPlayer: viewModel.isPresented, isRegularWidth: horizontalSizeClass == .regular)
            }
            #endif
            #if DEBUG
            .debugAutoplay(viewModel)
            .debugSnapshots()
            .debugHarness(player: viewModel, navigation: navigation)
            #endif
            .environment(navigation)
            .defaultAppStorage(.fluxo)
            .tint(Theme.accent)
    }

    @ViewBuilder
    private var root: some View {
        #if os(macOS)
        MacRootView(player: viewModel)
        #else
        TabView(selection: $navigation.tab) {
            Tab("Home", systemImage: "play.tv", value: AppNavigation.Tab.home) {
                HomeView(player: viewModel)
            }

            Tab("Guide", systemImage: "calendar.day.timeline.left", value: AppNavigation.Tab.guide) {
                GuideView()
            }

            Tab("Favorites", systemImage: "star", value: AppNavigation.Tab.favorites) {
                NavigationStack(path: $navigation.favoritesPath) {
                    FavoritesView(playlistIDs: nil)
                        .channelDestinations()
                }
            }

            Tab("Settings", systemImage: "gear", value: AppNavigation.Tab.settings) {
                NavigationStack {
                    SettingsView(player: viewModel)
                        .navigationTitle("Settings")
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: AppNavigation.Tab.search, role: .search) {
                SearchView()
            }
        }
        .playerAccessory(isVisible: viewModel.currentChannel != nil) {
            PlayerBottomAccessory(viewModel: viewModel)
        }
        #if DEBUG
        .onAppear {
            if DebugGuideDemo.opensGuide {
                navigation.tab = .guide
            } else if DebugGuideDemo.opensFavorites {
                navigation.tab = .favorites
            }
        }
        #endif
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
    @State private var playPauseTaps = 0

    var body: some View {
        if let channel = viewModel.currentChannel {
            let isInline = placement == .inline
            HStack(spacing: isInline ? 8 : 10) {
                artwork(for: channel, isInline: isInline)

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name ?? "No channel name")
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
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Stop Playback")
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("miniPlayer")
            .accessibilityAction(named: "Open Player", openPlayer)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: placement)
        } else {
            // Not reached: the accessory is disabled while nothing plays (`playerAccessory(isVisible:)`).
            Color.clear
                .accessibilityHidden(true)
        }
    }

    private func openPlayer() {
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
                .foregroundStyle(.secondary)
        } else if viewModel.playbackState.isBusy {
            Text(viewModel.playbackState.label)
                .foregroundStyle(.secondary)
        } else if isLive && viewModel.playbackState == .playing {
            HStack(spacing: 6) {
                LiveBadge(compact: true)
                if let group = viewModel.currentItem?.groupName, !group.isEmpty {
                    Text(group)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(viewModel.playbackState.label)
                .foregroundStyle(.secondary)
        }
    }

    private var isLive: Bool {
        viewModel.isTimeShiftAvailable || viewModel.currentChannel?.isLiveContent == true
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
    ContentView(viewModel: AVPlayerViewModel())
        .fluxoPreviewEnvironment()
}
