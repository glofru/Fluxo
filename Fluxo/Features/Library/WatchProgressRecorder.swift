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
///   range (a remuxed file becomes seekable progressively), for at most `resumeWindow` seconds. The resume
///   counts once playback is there: a seek AVPlayer drops while it starts the item is made again.
/// - Bridges a Cast handoff: casting starting or ending resets the timeline before the receiver (or this
///   device) reports the position again, so the last position is kept as a pending resume meanwhile instead
///   of being overwritten with 0. The receiver's position is recorded while casting.
private struct WatchProgressRecorder: View {

    static let saveInterval: TimeInterval = 10
    static let resumeWindow: TimeInterval = 20
    /// A resume this close to where playback already is (e.g. the receiver started at it) needs no seek.
    static let resumeTolerance: TimeInterval = 5
    /// How long a resume seek may take to land before it is made again (at most `resumeAttempts` times).
    static let resumeRetryInterval: TimeInterval = 3
    static let resumeAttempts = 3

    let player: AVPlayerViewModel

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    /// The on-demand item playing and the last position and duration seen for it.
    @State private var tracked: Tracked?

    private struct Tracked {
        let item: ChannelItem
        var startedAt: Date
        var position: TimeInterval = 0
        var duration: TimeInterval = 0
        var savedPosition: TimeInterval = 0
        /// Whether the item was being cast at the last update (see `bridgeCastHandoff()`).
        var isCasting: Bool
        /// The saved position to resume from, until playback is there or it was given up.
        var pendingResume: TimeInterval?
        /// The resume seeks made so far, and when the last one was made.
        var resumeSeeks = 0
        var lastResumeSeek: Date?
    }

    var body: some View {
        let timeline = player.timeline
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: player.currentItem, initial: true) { _, item in
                saveTracked()
                if let item, item.kind != .live {
                    tracked = Tracked(item: item, startedAt: .now, isCasting: player.isCasting, pendingResume: library.watchProgress(for: item)?.position)
                } else {
                    tracked = nil
                }
            }
            .onChange(of: player.isCasting) { _, _ in
                bridgeCastHandoff()
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
        bridgeCastHandoff()
        guard var current = tracked, current.item == player.currentItem, position.isFinite else {
            return
        }
        if let resume = current.pendingResume {
            if Date.now.timeIntervalSince(current.startedAt) > Self.resumeWindow {
                current.pendingResume = nil
            } else if abs(position - resume) <= Self.resumeTolerance {
                // Playback is there (the receiver started at it, or the seek landed).
                current.pendingResume = nil
            } else if player.canSeek, seekableEnd >= resume {
                let due = current.lastResumeSeek.map { Date.now.timeIntervalSince($0) >= Self.resumeRetryInterval } ?? true
                if due && current.resumeSeeks >= Self.resumeAttempts {
                    // It never landed: continue from where playback is.
                    current.pendingResume = nil
                } else {
                    if due {
                        current.resumeSeeks += 1
                        current.lastResumeSeek = .now
                        player.seek(toSeconds: resume)
                    }
                    // Not there yet: do not overwrite the saved position with the start.
                    tracked = current
                    return
                }
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

    /// Casting started or ended for the tracked item: it continues elsewhere from (about) the last position
    /// seen, so that position is resumed (or confirmed) instead of the reset timeline being recorded. Runs once
    /// per change, whichever of the `isCasting` and timeline updates arrives first.
    private func bridgeCastHandoff() {
        guard var current = tracked, current.isCasting != player.isCasting, current.item == player.currentItem else {
            return
        }
        current.isCasting = player.isCasting
        tracked = current
        if current.pendingResume == nil {
            guard current.position >= WatchProgress.minimumPosition else {
                return
            }
            saveTracked()
            current = tracked ?? current
            current.pendingResume = current.position
        }
        current.startedAt = .now
        current.resumeSeeks = 0
        current.lastResumeSeek = nil
        tracked = current
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
