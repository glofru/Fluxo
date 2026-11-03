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
    @State private var playlistActions = PlaylistActions()

    var body: some View {
        root
            .playerPresentation(isPresented: $viewModel.isPresented) {
                WatchChannelView(viewModel: viewModel)
            }
            .playlistManagement()
            .environment(playlistActions)
            .environment(\.playChannel, PlayChannelAction(library: library, player: viewModel))
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
                    SettingsView()
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

struct PlayerBottomAccessory: View {
    static let logoSize = CGSize(width: 40, height: 32)

    let viewModel: AVPlayerViewModel

    var body: some View {
        if let channel = viewModel.currentChannel {
            HStack {
                if channel.logo != nil {
                    LogoImage(source: channel.logo, size: Self.logoSize, accessibilityLabel: channel.name ?? "No channel name") { _ in
                        Color.clear
                    }
                    .clipShape(RoundedRectangle(cornerSize: .init(width: 6, height: 6)))
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(channel.name ?? "No channel name")
                        .bold()
                        .lineLimit(1)
                    if viewModel.isPictureInPictureActive || viewModel.isRecording || viewModel.playbackState.isBusy {
                        Text(accessoryStatus)
                            .font(.caption2)
                            .foregroundStyle(viewModel.isRecording ? .red : .secondary)
                    }
                }

                Spacer()

                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .accessibilityLabel(isPaused ? "Play" : "Pause")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)

                Button {
                    viewModel.stop()
                } label: {
                    Image(systemName: "xmark")
                        .accessibilityLabel("Stop playback")
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
            }
            .ignoresSafeArea(.all)
            .onTapGesture {
                viewModel.isPresented = true
            }
        } else {
            EmptyView()
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

    private var accessoryStatus: String {
        if viewModel.isRecording {
            return "Recording"
        }
        if viewModel.isPictureInPictureActive {
            return "Picture in Picture"
        }
        return viewModel.playbackState.label
    }
}

#Preview {
    ContentView(viewModel: AVPlayerViewModel())
        .fluxoPreviewEnvironment()
}
