//
//  NowPlayingController.swift
//  Fluxo
//
//  Publishes the playing channel to the system (Lock Screen, Control Center, the macOS Now Playing menu)
//  and routes the remote commands (play/pause, skip, next/previous channel) back to the player.
//
//  The player draws its own controls on an AVPlayerLayer, so nothing does this automatically.
//

import Foundation
import MediaPlayer

@MainActor
final class NowPlayingController {

    struct Commands {
        var play: () -> Void
        var pause: () -> Void
        var togglePlayPause: () -> Void
        var skipBackward: () -> Void
        var skipForward: () -> Void
        var nextChannel: () -> Void
        var previousChannel: () -> Void
    }

    private var registrations: [(command: MPRemoteCommand, target: Any)] = []

    func register(_ commands: Commands) {
        unregister()
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand, commands.play)
        add(center.pauseCommand, commands.pause)
        add(center.togglePlayPauseCommand, commands.togglePlayPause)
        add(center.skipBackwardCommand, commands.skipBackward)
        add(center.skipForwardCommand, commands.skipForward)
        add(center.nextTrackCommand, commands.nextChannel)
        add(center.previousTrackCommand, commands.previousChannel)
    }

    /// Updates the Now Playing entry. Call it when the channel, the state or the seekability changes;
    /// the system extrapolates the elapsed time from the rate in between.
    func update(title: String, isLive: Bool, elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool, canSeek: Bool, canZap: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
        ]
        if !isLive && duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif

        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: PlayerPreferences.skipBackwardInterval)]
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: PlayerPreferences.skipForwardInterval)]
        commands.skipBackwardCommand.isEnabled = canSeek
        commands.skipForwardCommand.isEnabled = canSeek
        commands.nextTrackCommand.isEnabled = canZap
        commands.previousTrackCommand.isEnabled = canZap
    }

    func clear() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        #if os(macOS)
        center.playbackState = .stopped
        #endif
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping () -> Void) {
        command.isEnabled = true
        let target = command.addTarget { _ in
            // Remote commands may arrive on any queue; the player lives on the main actor.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    action()
                }
            }
            return .success
        }
        registrations.append((command, target))
    }

    private func unregister() {
        for registration in registrations {
            registration.command.removeTarget(registration.target)
        }
        registrations.removeAll()
    }
}
