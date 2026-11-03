//
//  WatchChannelView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import AVKit
import SwiftUI

/// Full player screen: the video, its state, and the transport, time-shift and recording controls.
struct WatchChannelView: View {

    let viewModel: AVPlayerViewModel

    @State private var isShowingRecordings = false

    var body: some View {
        VStack(spacing: 0) {
            PlayerHeader(viewModel: viewModel, isShowingRecordings: $isShowingRecordings)

            ZStack {
                Color.black

                AVVideoPlayer(surface: viewModel.surface)
                    .onAppear {
                        viewModel.playerViewDidAppear()
                    }
                    .onDisappear {
                        viewModel.playerViewDidDisappear()
                    }

                PlayerStatusOverlay(viewModel: viewModel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PlayerControls(viewModel: viewModel, timeline: viewModel.timeline)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingRecordings) {
            RecordingsView(store: viewModel.recordings, isRecordingActive: viewModel.isRecording) { recording in
                isShowingRecordings = false
                viewModel.playRecording(recording)
            }
        }
    }
}

private struct PlayerHeader: View {
    let viewModel: AVPlayerViewModel
    @Binding var isShowingRecordings: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.isPresented = false
            } label: {
                Image(systemName: "chevron.down")
                    .accessibilityLabel("Close the player")
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.currentChannel?.name ?? "No channel")
                    .font(.headline)
                    .lineLimit(1)
                Text(viewModel.playbackState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isShowingRecordings = true
            } label: {
                Image(systemName: "film.stack")
                    .accessibilityLabel("Recordings")
            }
            .buttonStyle(.glass)

            Button(role: .destructive) {
                viewModel.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .accessibilityLabel("Stop playback")
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

/// Connection, buffering and error feedback on top of the video.
private struct PlayerStatusOverlay: View {
    let viewModel: AVPlayerViewModel

    var body: some View {
        switch viewModel.playbackState {
        case .connecting, .buffering:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .allowsHitTesting(false)
        case .reconnecting:
            Label(viewModel.playbackState.label, systemImage: "wifi.exclamationmark")
                .font(.callout.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
                .allowsHitTesting(false)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Button("Try Again", systemImage: "arrow.clockwise") {
                    viewModel.retry()
                }
                .buttonStyle(.glassProminent)
            }
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding()
        default:
            EmptyView()
        }
    }
}

/// Transport, time-shift and recording controls. Observes the timeline, which changes twice a second.
private struct PlayerControls: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline

    var body: some View {
        VStack(spacing: 10) {
            if viewModel.isTimeShiftAvailable {
                timeShiftInfo
            }

            if let error = viewModel.recordingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .onTapGesture {
                        viewModel.clearRecordingError()
                    }
            }

            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    Button {
                        viewModel.skipBackward()
                    } label: {
                        Image(systemName: "gobackward.10")
                            .accessibilityLabel("Back 10 seconds")
                    }
                    .disabled(!viewModel.canSeek)

                    Button {
                        viewModel.togglePlayPause()
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.title2)
                            .frame(width: 32, height: 32)
                            .accessibilityLabel(isPaused ? "Play" : "Pause")
                    }
                    .keyboardShortcut(.space, modifiers: [])

                    Button {
                        viewModel.skipForward()
                    } label: {
                        Image(systemName: "goforward.30")
                            .accessibilityLabel("Forward 30 seconds")
                    }
                    .disabled(!viewModel.canSeek || (viewModel.isTimeShiftAvailable && timeline.isAtLiveEdge))

                    if viewModel.isTimeShiftAvailable {
                        Button {
                            viewModel.goLive()
                        } label: {
                            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                                .foregroundStyle(timeline.isAtLiveEdge ? .red : .primary)
                        }
                        .disabled(timeline.isAtLiveEdge)
                    }

                    if viewModel.canRecord || viewModel.isRecording {
                        Button {
                            viewModel.toggleRecording()
                        } label: {
                            Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                                .foregroundStyle(.red)
                                .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Record")
                        }
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var isPaused: Bool {
        switch viewModel.playbackState {
        case .paused, .ended, .failed, .idle:
            return true
        default:
            return false
        }
    }

    private var timeShiftInfo: some View {
        HStack(spacing: 12) {
            if timeline.isAtLiveEdge {
                Label("LIVE", systemImage: "circle.fill")
                    .foregroundStyle(.red)
            } else {
                Label("-\(Self.format(timeline.timeBehindLive))", systemImage: "clock.arrow.circlepath")
            }
            Spacer()
            if viewModel.isRecording {
                Label("REC \(Self.format(timeline.recordingDuration))", systemImage: "record.circle")
                    .foregroundStyle(.red)
            }
            Text("Buffer \(Self.format(timeline.seekableDuration))")
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .labelStyle(.titleAndIcon)
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

#Preview {
    WatchChannelView(viewModel: AVPlayerViewModel())
}
