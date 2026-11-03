//
//  ContentView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-05-31.
//

import SwiftUI

struct ContentView: View {

    @Bindable var viewModel: AVPlayerViewModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(ChannelLibrary.self) private var library
    /// The player zooms out of the card or the mini player that opened it.
    @Namespace private var playerNamespace

    var body: some View {
        root
            .environment(\.playerTransitionNamespace, playerNamespace)
            .playerPresentation(isPresented: $viewModel.isPresented) {
                WatchChannelView(viewModel: viewModel)
                    .zoomTransition(sourceID: viewModel.presentationSourceID ?? PlayerTransition.miniPlayerID, in: playerNamespace)
            }
            .playlistManagement()
            .environment(\.playChannel, PlayChannelAction(library: library, player: viewModel))
            .sensoryFeedback(.selection, trigger: library.favoriteToggleCount)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    viewModel.sceneDidBecomeActive()
                }
            }
            #if os(macOS)
            .onDisappear {
                // The main window was closed: nothing shows the player any more, unless it is in PiP.
                if !viewModel.isPictureInPictureActive {
                    viewModel.stop()
                }
            }
            #endif
            #if DEBUG
            .debugAutoplay(viewModel)
            #endif
    }

    @ViewBuilder
    private var root: some View {
        #if os(macOS)
        MacRootView(player: viewModel)
        #else
        TabView {
            Tab("Home", systemImage: "play.tv") {
                HomeView(player: viewModel)
            }

            Tab("Favorites", systemImage: "star") {
                NavigationStack {
                    BookmarkGridView(mode: .favorites, playlistIDs: nil)
                        .channelDestinations()
                }
            }

            Tab("Settings", systemImage: "gear") {
                NavigationStack {
                    SettingsView(player: viewModel)
                        .navigationTitle("Settings")
                }
            }

            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                SearchView()
            }
        }
        .playerAccessory(isVisible: viewModel.currentChannel != nil) {
            PlayerBottomAccessory(viewModel: viewModel)
        }
        #endif
    }
}

/// The mini player: the tab bar bottom accessory on iOS, a floating glass bar on macOS.
///
/// Expanded (above the tab bar): artwork, title, a status line (live, time-shifted, recording, PiP, buffering),
/// play / pause and close. Inline (next to the minimized tab bar): artwork, title and play / pause only.
/// Tapping it opens the player, which zooms out of it.
struct PlayerBottomAccessory: View {

    let viewModel: AVPlayerViewModel

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playPauseTaps = 0

    var body: some View {
        if let channel = viewModel.currentChannel {
            let isInline = placement == .inline
            HStack(spacing: isInline ? 10 : 12) {
                artwork(for: channel, isInline: isInline)

                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.name ?? "No channel name")
                        .font(isInline ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !isInline {
                        status
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    playPauseTaps += 1
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(isInline ? .body : .title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
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
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Stop playback")
                }
            }
            .padding(.leading, isInline ? 6 : 10)
            .padding(.trailing, isInline ? 4 : 10)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onTapGesture(perform: openPlayer)
            .playerTransitionSource(id: PlayerTransition.miniPlayerID, cornerRadius: 24)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Open Player", openPlayer)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: placement)
        } else {
            // Only reached on iOS 26.0, which cannot hide the accessory.
            Label("Not Playing", systemImage: "play.tv")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openPlayer() {
        viewModel.presentationSourceID = nil
        viewModel.isPresented = true
    }

    @ViewBuilder
    private func artwork(for channel: PlayableChannel, isInline: Bool) -> some View {
        let size = isInline ? CGSize(width: 30, height: 30) : CGSize(width: 40, height: 40)
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
        .clipShape(.rect(cornerRadius: isInline ? 8 : 10, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var status: some View {
        if viewModel.isRecording {
            Label {
                Text("Recording")
            } icon: {
                Image(systemName: "record.circle.fill")
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
            .foregroundStyle(.red)
        } else if viewModel.isPictureInPictureActive {
            Label("Picture in Picture", systemImage: "pip")
                .foregroundStyle(.secondary)
        } else if viewModel.playbackState.isBusy {
            Text(viewModel.playbackState.label)
                .foregroundStyle(.secondary)
        } else if isLive && viewModel.playbackState == .playing {
            HStack(spacing: 6) {
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red, in: .capsule)
                    .foregroundStyle(.white)
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
