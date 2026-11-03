//
//  ContentView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-05-31.
//

import SwiftUI

struct ContentView: View {

    @ObservedObject var viewModel: AVPlayerViewModel

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Watch", systemImage: "play.tv") {
                WatchView(viewModel: viewModel)
            }

            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }

            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                List(0..<100) { i in
                    Text("Row \(i)")
                }
                .searchable(text: .init(get: { "test" }, set: { _ in }))
            }
        }
        .playerAccessory(isVisible: viewModel.currentChannel != nil) {
            PlayerBottomAccessory(viewModel: viewModel)
        }
        .playerPresentation(isPresented: $viewModel.isPresented) {
            WatchChannelView(viewModel: viewModel)
        }
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
}

struct PlayerBottomAccessory: View {
    @ObservedObject var viewModel: AVPlayerViewModel

    var body: some View {
        if let channel = viewModel.currentChannel {
            HStack {
                if let logo = channel.logo, let url = URL(string: logo) {
                    if let image = Image(dataURL: url) {
                        image
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerSize: .init(width: 6, height: 6)))
                            .padding(.leading, 16)
                            .padding(.trailing, 6)
                            .padding(.vertical, 6)
                            .accessibilityLabel(Text(channel.name ?? "No channel name"))
                    } else {
                        AsyncImage(url: url) { result in
                            if result.error != nil {
                                EmptyView()
                            } else if let image = result.image {
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .clipShape(RoundedRectangle(cornerSize: .init(width: 6, height: 6)))
                                        .padding(.leading, 16)
                                        .padding(.trailing, 6)
                                        .padding(.vertical, 6)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                } else {
                    EmptyView()
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
}
