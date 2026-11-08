//
//  AVPlayerViewModel+PausedTimeShift.swift
//  Fluxo
//
//  A paused live channel through the engine: when the engine stops reading its input (`PausedTimeShiftPolicy`), and
//  how playback continues in a new player item once it reads again.
//

import AVKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Player")

extension AVPlayerViewModel {
    // MARK: - Paused live channels

    /// A live channel through the engine that pauses keeps filling its time-shift window until `PausedTimeShiftPolicy`
    /// says the input should close; anything but a pause opens it again at once.
    func updatePausedTimeShift(_ status: AVPlayer.TimeControlStatus) {
        guard status == .paused, route.isLiveRemux, remuxer.isProcessing, let item = player.currentItem else {
            pausedTimeShiftTask?.cancel()
            pausedTimeShiftTask = nil
            if status != .paused {
                remuxer.setInputSuspended(false)
                if suspension != nil, suspensionResume == nil, route.isLiveRemux, remuxer.isProcessing {
                    // The item stopped following the playlist: a new one continues once the engine writes again.
                    logger.info("Playing after a suspension: a new item continues once the engine writes again")
                    suspensionResume = .pausedPosition
                }
            }
            return
        }
        // Paused again before the engine wrote after a suspension: the next play continues then. (Not when the old item
        // stopped at the end of the playlist, which was marked as ended while the input was suspended.)
        if suspensionResume != nil, item.duration.isNumeric, item.currentTime().seconds >= item.duration.seconds - 0.5 {
            return
        }
        suspensionResume = nil
        guard pausedTimeShiftTask == nil else {
            return
        }
        let pausedAt = ContinuousClock.now
        let windowStartAtPause = seekableRange(of: item)?.start
        pausedTimeShiftTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PausedTimeShiftPolicy.checkInterval)
                guard !Task.isCancelled, let self, let item = self.player.currentItem, self.player.timeControlStatus == .paused else {
                    return
                }
                let decision = PausedTimeShiftPolicy.decide(PausedTimeShiftPolicy.Conditions(
                    pausedFor: TimeInterval((ContinuousClock.now - pausedAt).components.seconds),
                    // (Where the player is now: it may have been moved while paused.)
                    position: item.currentTime().seconds,
                    windowStartAtPause: windowStartAtPause,
                    windowStart: self.seekableRange(of: item)?.start,
                    isExpensiveNetwork: NetworkMonitor.shared.isExpensive,
                    isLowPowerModeEnabled: PowerMonitor.shared.isLowPowerModeEnabled,
                    isRecording: self.isRecording
                ))
                if case .suspend(let reason) = decision {
                    logger.info("Paused live channel: the engine stops reading its input (\(reason, privacy: .public))")
                    self.awaitsInputSuspension = true
                    self.remuxer.setInputSuspended(true)
                    return
                }
            }
        }
    }

    /// Attaches a new item of the live playlist after its input was suspended, at the media where the old item was (it
    /// has the playlist written when the input closed, marked as ended: `PausedTimeShiftPolicy`), or with the first media
    /// after the resume for Go Live. Called when the engine wrote a segment after the resume, so the playlist the new item
    /// loads goes on. The media are named by their date (`PausedTimeShiftPolicy.MediaClock`), which the new item finds
    /// once it is ready (`resumeAfterSuspension(at:in:)`).
    func continueAfterSuspension(_ suspension: Suspension, at resume: SuspensionResume) {
        suspensionResume = nil
        self.suspension = nil
        guard remuxer.configuration != nil, let item = player.currentItem else {
            return
        }
        // (The old item plays the frozen media until the new item comes.)
        let position = item.currentTime().seconds
        let clock = suspension.clock ?? clock(of: item)
        var date: Date?
        switch resume {
        case .pausedPosition:
            date = clock.map { PausedTimeShiftPolicy.resumeDate(position: position, seekTarget: seeker.target, clock: $0, frozen: suspension.frozenDates) }
        case .liveEdge:
            date = suspension.frozenDates?.upperBound
        }
        if let date {
            logger.info("Live channel after a suspension: a new item at the media of \(date.timeIntervalSinceReferenceDate, format: .fixed(precision: 3)) (\(resume == .liveEdge ? "Go Live" : "where the old item was", privacy: .public))")
            pendingSuspensionResume = PendingSuspensionResume(date: date, liveEdge: suspension.frozenDates?.upperBound)
        } else {
            logger.error("Live channel after a suspension: the items have no dates; the new item starts at the live edge")
            pendingSuspensionResume = nil
        }
        // The old item's seeks end with it.
        seeker.reset()
        pendingResumePosition = nil
        pendingResumeContinuesRecovery = false
        server.start(root: outputDirectory)
        attachRemuxedStream()
    }

    /// The clock of `item`: the one read when it became ready, or else (it had no date then) from now, a few frames off
    /// the playlist's dates (`PausedTimeShiftPolicy.MediaClock`).
    func clock(of item: AVPlayerItem) -> PausedTimeShiftPolicy.MediaClock? {
        if let itemClock, itemClock.item == ObjectIdentifier(item) {
            return itemClock.clock
        }
        return PausedTimeShiftPolicy.MediaClock(itemTime: item.currentTime().seconds, date: item.currentDate())
    }

    /// Moves a new item after a suspension, once it is ready, to the media of `date`, through its clock (`clock(of:)`):
    /// its date may come a moment after it is ready (polled for up to 3 s).
    func resumeAfterSuspension(at date: Date, in item: AVPlayerItem) {
        suspensionResumeTask?.cancel()
        suspensionResumeTask = Task { [weak self, weak item] in
            for attempt in 0..<30 {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled, let self, let item, self.player.currentItem === item else {
                    return
                }
                if let clock = self.clock(of: item) {
                    self.suspensionResumeTask = nil
                    let target = PausedTimeShiftPolicy.resumeItemTime(at: date, clock: clock, window: self.seekableRange(of: item))
                    logger.info("Live channel after a suspension: the new item continues at \(target, format: .fixed(precision: 2)) s")
                    self.resume(at: target, in: item)
                    return
                }
            }
            self?.suspensionResumeTask = nil
            logger.error("Live channel after a suspension: the new item has no date; it plays from where it started")
        }
    }
}
