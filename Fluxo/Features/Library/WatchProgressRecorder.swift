//
//  WatchProgressRecorder.swift
//  Fluxo
//
//  Keeps the playback position of movies and episodes (for "Continue Watching" and the progress bars of
//  cards and rows) and resumes them where they stopped.
//

import SwiftUI

extension View {
    /// Records the position of the on-demand item `player` plays and resumes it the next time it plays.
    func watchProgressRecording(player: AVPlayerViewModel) -> some View {
        background {
            WatchProgressRecorder(player: player)
        }
    }
}

/// An invisible view that follows the player's timeline. It is the only reader of the timeline at the root,
/// so the twice-a-second time updates re-render nothing else.
///
/// - Saves every `saveInterval` seconds of playback, when playback pauses or ends, and when another item
///   starts or playback stops (with the last position seen, since the player resets its timeline first).
/// - Resumes once per start: as soon as the item can seek and the saved position is within the seekable
///   range (a remuxed file becomes seekable progressively), for at most `resumeWindow` seconds.
private struct WatchProgressRecorder: View {

    static let saveInterval: TimeInterval = 10
    static let resumeWindow: TimeInterval = 20

    let player: AVPlayerViewModel

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    /// The on-demand item playing and the last position and duration seen for it.
    @State private var tracked: Tracked?

    private struct Tracked {
        let item: ChannelItem
        let startedAt: Date
        var position: TimeInterval = 0
        var duration: TimeInterval = 0
        var savedPosition: TimeInterval = 0
        /// The saved position to resume from, until it was applied or given up.
        var pendingResume: TimeInterval?
    }

    var body: some View {
        let timeline = player.timeline
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: player.currentItem, initial: true) { _, item in
                saveTracked()
                if let item, item.kind != .live {
                    tracked = Tracked(item: item, startedAt: .now, pendingResume: library.watchProgress(for: item)?.position)
                } else {
                    tracked = nil
                }
            }
            .onChange(of: timeline.currentTime) { _, time in
                update(position: time, duration: timeline.duration, seekableEnd: timeline.seekableEnd)
            }
            .onChange(of: player.playbackState) { _, state in
                switch state {
                case .paused:
                    saveTracked()
                case .ended:
                    if var current = tracked, current.duration > 0 {
                        current.position = current.duration
                        tracked = current
                        saveTracked()
                    }
                default:
                    break
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    saveTracked()
                }
            }
    }

    private func update(position: TimeInterval, duration: TimeInterval, seekableEnd: TimeInterval) {
        guard var current = tracked, current.item == player.currentItem, position.isFinite else {
            return
        }
        if let resume = current.pendingResume {
            if Date.now.timeIntervalSince(current.startedAt) > Self.resumeWindow {
                current.pendingResume = nil
            } else if player.canSeek, seekableEnd >= resume {
                current.pendingResume = nil
                player.seek(toSeconds: resume)
                tracked = current
                return
            } else {
                // Not seekable that far yet: do not overwrite the saved position with the start.
                tracked = current
                return
            }
        }
        current.position = position
        if duration > 0 {
            current.duration = duration
        }
        tracked = current
        if abs(position - current.savedPosition) >= Self.saveInterval {
            saveTracked()
        }
    }

    private func saveTracked() {
        guard var current = tracked, current.pendingResume == nil, current.duration > 0 else {
            return
        }
        library.saveWatchProgress(for: current.item, position: current.position, duration: current.duration)
        current.savedPosition = current.position
        tracked = current
    }
}
