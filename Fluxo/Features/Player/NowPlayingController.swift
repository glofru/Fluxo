//
//  NowPlayingController.swift
//  Fluxo
//
//  Publishes the playing channel to the system (Lock Screen, Control Center, the macOS Now Playing menu)
//  and routes the remote commands (play/pause, skip, next/previous channel) back to the player.
//
//  The player draws its own controls on an AVPlayerLayer, so nothing does this automatically.
//
//  Apple TV is the exception: its player is the system's `AVPlayerViewController` (`TVPlayerView`), which publishes
//  Now Playing itself (from the item's `externalMetadata`, with the right elapsed time, duration and live state) and
//  answers the remote commands of the Siri Remote and Control Center for its player (`updatesNowPlayingInfoCenter`
//  does not exist on tvOS). A second writer would fight it, so this controller does nothing there.
//

import AppIntents
import Foundation
import MediaPlayer

@MainActor
final class NowPlayingController {

    struct Commands {
        var play: @MainActor () -> Void
        var pause: @MainActor () -> Void
        var togglePlayPause: @MainActor () -> Void
        var skipBackward: @MainActor () -> Void
        var skipForward: @MainActor () -> Void
        var nextChannel: @MainActor () -> Void
        var previousChannel: @MainActor () -> Void
    }

    private var registrations: [(command: MPRemoteCommand, target: Any)] = []

    /// False on Apple TV, where the system player owns Now Playing and the remote commands (see the file comment).
    static var isEnabled: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    func register(_ commands: Commands) {
        guard Self.isEnabled else {
            return
        }
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
    ///
    /// - Parameter item: the library channel that plays (nil for a stream outside the library). The entry names its
    ///   `ChannelEntity` (always on iOS, from macOS 27 and tvOS 27), so Siri knows what plays ("Add this to my
    ///   favorites", "What's on this channel?") even when the player is not on screen.
    func update(title: String, item: ChannelItem? = nil, isLive: Bool, elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool, canSeek: Bool, canZap: Bool) {
        guard Self.isEnabled else {
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
        ]
        if !isLive && duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if #available(macOS 27.0, tvOS 27.0, *),
           let identifier = item.flatMap(ChannelEntity.entityIdentifier(for:)).flatMap(MPAppEntityIdentifier.init(entityIdentifier:)) {
            info[MPNowPlayingInfoPropertyAppEntityIdentifiers] = [identifier]
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
        guard Self.isEnabled else {
            return
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        #if os(macOS)
        center.playbackState = .stopped
        #endif
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        // Remote commands may arrive on any queue; the player lives on the main actor. The handler is `@Sendable`, so it
        // is not isolated to the main actor (MediaPlayer does not mark its handler type `Sendable`, and a main-actor
        // closure would stop at Swift's actor check when called on another queue): it moves to the main queue itself.
        let target = command.addTarget { @Sendable _ in
            DispatchQueue.main.async {
                action()
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
