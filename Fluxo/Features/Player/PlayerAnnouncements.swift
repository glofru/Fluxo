//
//  PlayerAnnouncements.swift
//  Fluxo
//
//  VoiceOver announcements of what the player does on its own, wherever the user is (the player, the mini
//  player or any other screen): the channel that starts and whether it is live, buffering that lasts,
//  reconnecting, failures, the end of playback, recordings that start, stop or fail, back to live, and Cast.
//
//  Short-lived states are not spoken: a state is announced only once it has lasted a moment (buffering of a
//  fraction of a second, or connecting before a channel plays, stay silent), and "Playing" only closes a state
//  that was announced, so a channel that starts at once is announced once, as it plays.
//

import SwiftUI

extension View {
    /// Announces the player's state changes to VoiceOver (see the file comment).
    ///
    /// - Parameter isEnabled: false in the windows that leave the announcements to another one: there is a single
    ///   player and announcements are system-wide, so with several windows (iPad) only one of them speaks.
    func playerAnnouncements(_ viewModel: AVPlayerViewModel, isEnabled: Bool = true) -> some View {
        background {
            PlayerAnnouncer(viewModel: viewModel, timeline: viewModel.timeline, isEnabled: isEnabled)
        }
    }
}

private struct PlayerAnnouncer: View {
    let viewModel: AVPlayerViewModel
    let timeline: PlaybackTimeline
    let isEnabled: Bool

    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverRunning
    /// The last state that was spoken, so that "Playing" is said only after a state that needed it.
    @State private var spoken: Spoken?
    /// The channel that started and has not been announced yet.
    @State private var startedChannel: String?

    private enum Spoken: Equatable {
        case channel
        case busy
        case paused
        case failed
        case ended
    }

    /// VoiceOver runs and this window speaks for the player.
    private var isVoiceOverEnabled: Bool {
        isVoiceOverRunning && isEnabled
    }

    private struct StateKey: Equatable {
        let state: AVPlayerViewModel.PlaybackState
        let channel: UUID?
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: StateKey(state: viewModel.playbackState, channel: viewModel.currentChannel?.id)) {
                guard isVoiceOverEnabled else {
                    return
                }
                await announce(viewModel.playbackState)
            }
            .onChange(of: viewModel.currentChannel?.id) {
                startedChannel = viewModel.currentChannel?.name
                spoken = nil
            }
            .onChange(of: viewModel.isRecording) { wasRecording, isRecording in
                guard isVoiceOverEnabled, viewModel.recordingError == nil else {
                    return
                }
                if isRecording {
                    AccessibilityAnnouncer.announce(String(localized: "Recording started", comment: "VoiceOver announcement."))
                } else if wasRecording, viewModel.currentChannel != nil {
                    AccessibilityAnnouncer.announce(String(localized: "Recording stopped and saved to Recordings", comment: "VoiceOver announcement; Recordings is the name of the app's recordings screen."))
                }
            }
            .onChange(of: viewModel.recordingError) { _, error in
                if isVoiceOverEnabled, let error {
                    AccessibilityAnnouncer.announce(String(localized: "Recording failed: \(error)", comment: "VoiceOver announcement; the placeholder is the error message."), priority: .high)
                }
            }
            .onChange(of: viewModel.castError) { _, error in
                if isVoiceOverEnabled, let error {
                    AccessibilityAnnouncer.announce(error, priority: .high)
                }
            }
            .onChange(of: viewModel.isCasting) { _, isCasting in
                guard isVoiceOverEnabled, viewModel.currentChannel != nil else {
                    return
                }
                if isCasting, let device = viewModel.cast.connectedDevice {
                    AccessibilityAnnouncer.announce(String(localized: "Playing on \(device.name)", comment: "VoiceOver announcement when casting starts; the placeholder is the Chromecast name."))
                } else if !isCasting {
                    AccessibilityAnnouncer.announce(String(localized: "Playing on this device", comment: "VoiceOver announcement when casting stops and playback comes back to the phone or Mac."))
                }
            }
            .onChange(of: timeline.isAtLiveEdge) { _, isAtLive in
                // Back to live after watching behind it (Go Live, or catching up).
                if isVoiceOverEnabled, isAtLive, viewModel.isTimeShiftAvailable, viewModel.playbackState == .playing {
                    AccessibilityAnnouncer.announce(String(localized: "Live", comment: "VoiceOver announcement: playback is at the live edge of a live channel."), priority: .low)
                }
            }
    }

    private func announce(_ state: AVPlayerViewModel.PlaybackState) async {
        switch state {
        case .idle:
            spoken = nil
        case .connecting, .buffering:
            // Only waits that last.
            guard await settle(for: .seconds(2)) else {
                return
            }
            spoken = .busy
            AccessibilityAnnouncer.announce(state.label, priority: .low)
        case .reconnecting:
            guard await settle(for: .seconds(1)) else {
                return
            }
            spoken = .busy
            AccessibilityAnnouncer.announce(String(localized: "Connection lost. Reconnecting", comment: "VoiceOver announcement while the live stream reconnects."))
        case .playing:
            guard await settle(for: .milliseconds(600)) else {
                return
            }
            let isLive = viewModel.isTimeShiftAvailable || viewModel.currentChannel?.isLiveContent == true
            if let name = startedChannel {
                startedChannel = nil
                spoken = .channel
                AccessibilityAnnouncer.announce(isLive ? String(localized: "\(name), live", comment: "VoiceOver announcement when a live channel starts; the placeholder is the channel name.") : String(localized: "Playing \(name)", comment: "VoiceOver announcement when a video starts; the placeholder is its name."))
            } else if spoken != nil, spoken != .channel {
                spoken = .channel
                AccessibilityAnnouncer.announce(isLive ? String(localized: "Live", comment: "VoiceOver announcement: playback is at the live edge of a live channel.") : String(localized: "Playing", comment: "VoiceOver announcement: playback resumed."))
            }
        case .paused:
            guard await settle(for: .milliseconds(600)) else {
                return
            }
            spoken = .paused
            AccessibilityAnnouncer.announce(String(localized: "Paused", comment: "VoiceOver announcement: playback paused."), priority: .low)
        case .ended:
            spoken = .ended
            AccessibilityAnnouncer.announce(viewModel.isTimeShiftAvailable ? String(localized: "The stream ended", comment: "VoiceOver announcement: the live stream ended.") : String(localized: "Playback ended", comment: "VoiceOver announcement: the video finished."))
        case .failed(let message):
            spoken = .failed
            startedChannel = nil
            let title = viewModel.isCasting
                ? String(localized: "Can't play on the Cast device", comment: "VoiceOver announcement: the Chromecast could not play the channel.")
                : String(localized: "Can't play this channel", comment: "VoiceOver announcement: playback failed.")
            AccessibilityAnnouncer.announce(message.isEmpty ? title : String(localized: "\(title). \(message)", comment: "VoiceOver announcement of a playback failure: the failure, then the reason."), priority: .high)
        }
    }

    /// Waits `duration`; false when the state changed meanwhile (the task was cancelled).
    private func settle(for duration: Duration) async -> Bool {
        try? await Task.sleep(for: duration)
        return !Task.isCancelled
    }
}
