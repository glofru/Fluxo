//
//  PlaybackTimeline.swift
//  Fluxo
//
//  The fast-changing playback position of the player (AVPlayerViewModel.timeline).
//

import Foundation
import Observation

/// Fast-changing playback position. It is a separate object so that only the player controls
/// re-render while a stream plays, not every view that observes the player model.
/// With Observation, a view only re-renders for the properties it actually reads.
@MainActor
@Observable
final class PlaybackTimeline {
    private(set) var currentTime: TimeInterval = 0
    /// Duration of on-demand items, 0 for live streams.
    private(set) var duration: TimeInterval = 0
    private(set) var seekableStart: TimeInterval = 0
    private(set) var seekableEnd: TimeInterval = 0
    /// How far playback is behind the live point of a live stream: the end of the seekable range minus the
    /// player's live latency (`liveLatency`), which is where playback sits when it plays live. 0 at live.
    private(set) var timeBehindLive: TimeInterval = 0
    /// How far behind the end of the seekable range the player plays live (a few segments for HLS).
    private(set) var liveLatency: TimeInterval = 0
    private(set) var isAtLiveEdge = true
    private(set) var recordingDuration: TimeInterval = 0

    /// Length of the time-shift window (or of the seekable range of an on-demand item).
    var seekableDuration: TimeInterval {
        max(0, seekableEnd - seekableStart)
    }

    func update(currentTime: TimeInterval, duration: TimeInterval, seekableStart: TimeInterval, seekableEnd: TimeInterval, timeBehindLive: TimeInterval, liveLatency: TimeInterval, isAtLiveEdge: Bool) {
        // Half a second of resolution is enough for the controls and avoids needless renders.
        assignIfChanged(\.currentTime, currentTime)
        assignIfChanged(\.duration, duration)
        assignIfChanged(\.seekableStart, seekableStart)
        assignIfChanged(\.seekableEnd, seekableEnd)
        assignIfChanged(\.timeBehindLive, timeBehindLive)
        assignIfChanged(\.liveLatency, liveLatency)
        if self.isAtLiveEdge != isAtLiveEdge {
            self.isAtLiveEdge = isAtLiveEdge
        }
    }

    func updateRecordingDuration(_ duration: TimeInterval) {
        assignIfChanged(\.recordingDuration, duration)
    }

    func reset() {
        update(currentTime: 0, duration: 0, seekableStart: 0, seekableEnd: 0, timeBehindLive: 0, liveLatency: 0, isAtLiveEdge: true)
        recordingDuration = 0
    }

    private func assignIfChanged(_ keyPath: ReferenceWritableKeyPath<PlaybackTimeline, TimeInterval>, _ value: TimeInterval) {
        let value = value.isFinite ? value : 0
        if abs(self[keyPath: keyPath] - value) >= 0.25 || (value == 0 && self[keyPath: keyPath] != 0) {
            self[keyPath: keyPath] = value
        }
    }
}
