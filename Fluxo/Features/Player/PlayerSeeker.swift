//
//  PlayerSeeker.swift
//  Fluxo
//
//  Every seek of the player goes through here: the scrubber, the skip buttons, the keyboard and remote
//  commands, resuming a movie. It coalesces seeks (only the latest target wins), says where the position is
//  going while AVPlayer gets there (the controls show the target at once instead of the old position), and
//  recovers seeks that do not play: AVPlayer dropping a seek, or waiting for media for too long.
//
//  Also compiled into Tools/EngineSmokeTest/VODCheck (run_vod.sh), which measures seeks with it on macOS.
//

import AVFoundation
import Observation
import OSLog

private let seekLogger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Seek")

@MainActor
@Observable
final class PlayerSeeker {

    /// How exactly a seek must land.
    enum Precision {
        /// The frame at the target (the scrubber released, a skip, a resume).
        case exact
        /// The nearest key frame, which shows at once: the video following the finger while scrubbing.
        case keyFrame
    }

    enum Phase: Equatable {
        case idle
        /// AVPlayer is seeking.
        case seeking
        /// The seek landed and AVPlayer waits for media there.
        case loading
        /// Playback did not continue at the target, even after the recovery attempts.
        case failed
    }

    /// Where the position is going: the controls show it instead of the player's time until playback is there.
    /// nil when no seek is pending.
    private(set) var target: TimeInterval?
    private(set) var phase: Phase = .idle
    /// Counts the seeks the user made that landed (for feedback such as haptics).
    private(set) var landings = 0

    /// A seek is in progress (or waits for media where it landed).
    var isBusy: Bool {
        phase == .seeking || phase == .loading
    }

    /// The seeker moves the player now: a user seek, or the video following the finger (`isFinal` false), in flight
    /// or about to start. (The time jumps AVPlayer reports then are the seeker's own.)
    var isMoving: Bool {
        isBusy || inFlight != nil || pending != nil
    }

    let player: AVPlayer

    /// A seek landed (the position changed): refresh what shows the position (timeline, Now Playing).
    @ObservationIgnored var onLanded: (() -> Void)?
    /// AVPlayer is about to seek to this time (e.g. the engine then produces the segment there from a key frame,
    /// see `StreamRemuxer.noteSeek(to:)`).
    @ObservationIgnored var onWillSeek: ((TimeInterval) -> Void)?
    /// Playback did not continue after a seek and a retry from the key frame before the target: a last recovery
    /// (e.g. a new player item at the target, or another route). Returns true when it handles it; the seek then
    /// waits for the player to play again. Otherwise the seek fails (`phase` `.failed`). The handler resumes the
    /// new item with `seek(to:continuesRecovery:)` true, so that a stall there fails instead of starting over.
    @ObservationIgnored var onStuck: ((TimeInterval) -> Bool)?
    /// The seek failed for good.
    @ObservationIgnored var onFailed: ((TimeInterval) -> Void)?
    /// Checks only: replaces AVPlayer's seek (e.g. to drop seeks the way AVPlayer does while it starts an item,
    /// VODCheck `SCENARIO=dropped` and the debug harness's `seek-drop:`). Gets the completion of the seek; returns
    /// false to let AVPlayer seek.
    @ObservationIgnored var seekInterceptor: ((_ completion: @escaping @Sendable (Bool) -> Void) -> Bool)?

    /// How long a seek may take, or wait for media, before it is made again from the key frame before the target.
    /// Longer for media from the network.
    @ObservationIgnored var stallLimit: Duration = .seconds(8)
    /// At most one AVPlayer seek is started per interval while another one is in flight: the latest target replaces
    /// the pending one.
    static let replaceInterval: Duration = .milliseconds(250)
    /// Skips made in quick succession (tapping +30 four times) add up: the player seeks once they stop for this long.
    static let burstQuietTime: Duration = .milliseconds(300)
    /// A seek AVPlayer dropped (it does while it starts an item) is made again once the item is ready: at once the
    /// first time, then this much later times the drops before, at most `maxDrops` times; then the recovery takes over
    /// (`recover()`).
    static let dropRetryDelay: Duration = .milliseconds(150)
    static let maxDrops = 3
    /// How long a dropped seek waits for its item to be ready before it is made again anyway.
    static let dropReadyWait: Duration = .seconds(2)
    /// A seek that completed but plays (or rests) away from its target for this long ends there anyway: the
    /// controls then show where playback really is (logged as a landing error), never a target forever.
    static let offTargetLimit: Duration = .seconds(1)
    /// How far from the target playback may continue for the seek to count as landed.
    static let landingWindow: TimeInterval = 6

    private struct Request {
        var time: TimeInterval
        var precision: Precision
        /// A seek the user made (the scrubber, a skip), not the video following the finger.
        var isFinal: Bool
    }

    /// The seek AVPlayer performs now.
    @ObservationIgnored private var inFlight: Request?
    @ObservationIgnored private var inFlightGeneration = 0
    @ObservationIgnored private var lastIssue: ContinuousClock.Instant?
    /// The latest target, waiting for the seek in flight (or the end of a burst of skips).
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    /// Watches the seek until playback continues there.
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryStep = 0
    /// The recovery step reached when `onStuck` replaced the item (or the route): kept across `reset()` for the
    /// resume seek on the new item (`continuesRecovery`).
    @ObservationIgnored private var stuckRecoveryStep = 0
    /// Times AVPlayer reported the seek as not finished without a newer one replacing it (since the user's seek, or
    /// the latest recovery step).
    @ObservationIgnored private var droppedCount = 0
    /// When the latest user seek started (latency logging).
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private weak var item: AVPlayerItem?

    init(player: AVPlayer) {
        self.player = player
    }

    /// Seeks to `seconds` (item timeline, already within the seekable range).
    /// - Parameters:
    ///   - precision: `.keyFrame` while the finger moves the scrubber, `.exact` otherwise.
    ///   - isFinal: false while scrubbing: the position follows the finger, without the loading state.
    ///   - isBurst: a skip button tap: quick taps add up and seek once they stop.
    ///   - continuesRecovery: the seek of an item that `onStuck` made for a seek that did not play: the recovery
    ///     goes on from where it was (one more stall fails), rather than from the start.
    func seek(to seconds: TimeInterval, precision: Precision = .exact, isFinal: Bool = true, isBurst: Bool = false,
              continuesRecovery: Bool = false) {
        guard seconds.isFinite, let item = player.currentItem else {
            return
        }
        if self.item !== item {
            reset()
            self.item = item
        }
        let request = Request(time: max(0, seconds), precision: precision, isFinal: isFinal)
        target = request.time
        if isFinal {
            if phase == .failed || phase == .idle {
                phase = .seeking
            }
            recoveryStep = continuesRecovery ? max(recoveryStep, stuckRecoveryStep) : 0
            stuckRecoveryStep = 0
            droppedCount = 0
            startedAt = .now
        }
        pending = request
        pendingTask?.cancel()
        pendingTask = nil

        if isBurst {
            // More taps may follow: wait until they stop, then seek once to where they add up to (the controls show
            // the target at once). Every seek through the engine can cost a reconnection to the server.
            schedulePending(after: Self.burstQuietTime)
            return
        }
        guard inFlight != nil, let lastIssue else {
            issuePending()
            return
        }
        // A seek is in flight: replace it once it ran for a moment (a finger moving the scrubber, or another
        // release right away, should not restart the player's loading every few milliseconds), or as soon as it
        // completes, whichever comes first.
        let elapsed = ContinuousClock.now - lastIssue
        if elapsed >= Self.replaceInterval {
            issuePending()
        } else {
            schedulePending(after: Self.replaceInterval - elapsed)
        }
    }

    /// The system's player seeks AVPlayer itself to `seconds` (the transport bar of Apple TV: the clickpad's skips,
    /// a scrub committed with a click): the seeker follows that seek as one of its own, without seeking again. The
    /// target, the loading state, the latency log and the recovery of a seek that does not play (`recover()`: again
    /// from the key frame before the target, then `onStuck`) are those of the app's seeks, and `onWillSeek` tells the
    /// engine where playback goes before AVPlayer asks for the segment there. Call it just before the system seeks
    /// (`AVPlayerViewControllerDelegate.playerViewController(_:timeToSeekAfterUserNavigatedFrom:to:)`).
    func followSystemSeek(to seconds: TimeInterval) {
        guard seconds.isFinite, let item = player.currentItem else {
            return
        }
        if self.item !== item {
            reset()
            self.item = item
        }
        // The system's seek replaces whatever the seeker was doing: its seek in flight completes as replaced.
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        inFlight = nil
        inFlightGeneration += 1
        lastIssue = nil
        target = max(0, seconds)
        phase = .seeking
        recoveryStep = 0
        stuckRecoveryStep = 0
        droppedCount = 0
        startedAt = .now
        onWillSeek?(max(0, seconds))
        watch(generation: inFlightGeneration)
    }

    /// Forgets the seeks of the current item (a new item, or playback stopped).
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        watchTask?.cancel()
        watchTask = nil
        pending = nil
        inFlight = nil
        inFlightGeneration += 1
        lastIssue = nil
        target = nil
        phase = .idle
        recoveryStep = 0
        droppedCount = 0
        item = nil
    }

    /// Clears a failed seek (the user dismissed it, or playback continued by other means).
    func clearFailure() {
        if phase == .failed {
            phase = .idle
            target = nil
        }
    }

    // MARK: - Issuing

    private func schedulePending(after delay: Duration) {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else {
                return
            }
            self.pendingTask = nil
            self.issuePending()
        }
    }

    private func issuePending() {
        guard let request = pending, let item = player.currentItem, item === self.item else {
            return
        }
        pending = nil
        pendingTask?.cancel()
        pendingTask = nil
        inFlight = request
        inFlightGeneration += 1
        let generation = inFlightGeneration
        lastIssue = .now
        if request.isFinal && phase != .loading {
            phase = .seeking
        }
        let (before, after) = Self.tolerances(for: request.precision)
        if request.isFinal {
            onWillSeek?(request.time)
        }
        // Replaces a seek in flight: AVPlayer completes that one with `finished` false.
        startSeek(to: request.time, toleranceBefore: before, toleranceAfter: after, generation: generation)
        if request.isFinal {
            watch(generation: generation)
        }
    }

    private func startSeek(to seconds: TimeInterval, toleranceBefore before: CMTime, toleranceAfter after: CMTime, generation: Int) {
        let completion: @Sendable (Bool) -> Void = { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.seekCompleted(generation: generation, finished: finished)
            }
        }
        if seekInterceptor?(completion) == true {
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: before, toleranceAfter: after, completionHandler: completion)
    }

    static func tolerances(for precision: Precision) -> (CMTime, CMTime) {
        switch precision {
        case .exact:
            // A quarter of a second either way. (No tolerance at all makes AVPlayer buffer the next segment of an HLS
            // stream before it plays: twice as long through the engine.)
            let tolerance = CMTime(value: 1, timescale: 4)
            return (tolerance, tolerance)
        case .keyFrame:
            // The sync sample nearest the target: no frames to decode up to it, so it shows at once.
            return (.positiveInfinity, .positiveInfinity)
        }
    }

    private func seekCompleted(generation: Int, finished: Bool) {
        guard generation == inFlightGeneration, let request = inFlight else {
            // Replaced by a newer seek.
            return
        }
        inFlight = nil
        if pending != nil {
            // A newer target came while this one was in flight: it goes now (unless a burst of skips is still going on).
            if pendingTask == nil {
                issuePending()
            }
            return
        }
        guard finished else {
            seekDropped(request)
            return
        }
        onLanded?()
        guard request.isFinal else {
            // Following the finger: the position is the finger's until the scrubber is released.
            return
        }
        if phase == .seeking {
            phase = .loading
        }
        checkLanded()
    }

    /// AVPlayer completed `request` without finishing it, and no newer seek replaced it: it drops seeks while it
    /// starts an item (or the item changed underneath). A user seek is never left there (`phase` `.seeking` with
    /// nothing in flight would show the target and the spinner forever): it is made again once the item is ready,
    /// a few times, and then the recovery takes over, which ends in a landing or in `.failed`.
    private func seekDropped(_ request: Request) {
        guard request.isFinal else {
            // Following the finger: the next position (or the release) seeks again.
            return
        }
        guard player.currentItem === item else {
            // Another item: its seeks start over (its resume seek, if any, follows).
            seekLogger.info("Seek to \(request.time, format: .fixed(precision: 1)) s was dropped: the item changed")
            reset()
            return
        }
        guard droppedCount < Self.maxDrops else {
            seekLogger.error("Seek to \(request.time, format: .fixed(precision: 1)) s was dropped \(self.droppedCount + 1) times")
            recover()
            return
        }
        droppedCount += 1
        seekLogger.info("Seek to \(request.time, format: .fixed(precision: 1)) s was dropped, seeking again (\(self.droppedCount))")
        pending = request
        pendingTask?.cancel()
        let delay = Self.dropRetryDelay * (droppedCount - 1)
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            var waited: Duration = .zero
            // AVPlayer drops the seeks of an item it still starts: wait until it is ready (or failed).
            while !Task.isCancelled, let status = self?.player.currentItem?.status, status == .unknown, waited < Self.dropReadyWait {
                try? await Task.sleep(for: .milliseconds(100))
                waited += .milliseconds(100)
            }
            guard !Task.isCancelled, let self else {
                return
            }
            self.pendingTask = nil
            self.issuePending()
        }
    }

    // MARK: - Landing and recovery

    /// The seek is done once the player plays there again (or it is paused there: the frame shows when decoded).
    private func checkLanded() {
        guard inFlight == nil, pending == nil, phase == .loading || phase == .seeking, let target else {
            return
        }
        let status = player.timeControlStatus
        let current = player.currentTime().seconds
        guard isNearTarget(current), status == .playing || status == .paused else {
            return
        }
        if let startedAt {
            let latency = ContinuousClock.now - startedAt
            seekLogger.info("Seek to \(target, format: .fixed(precision: 1)) s \(status == .playing ? "playing" : "paused", privacy: .public) at \(current, format: .fixed(precision: 1)) s after \(latency.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)), privacy: .public)")
        }
        finish()
    }

    /// Whether playback at `time` is where the seek went.
    private func isNearTarget(_ time: TimeInterval) -> Bool {
        guard let target, time.isFinite else {
            return false
        }
        // After the retry from the key frame before the target, playback may start up to a GOP before it.
        let slack: TimeInterval = recoveryStep > 0 ? 30 : Self.landingWindow
        return time > target - slack && time < target + Self.landingWindow
    }

    /// The seek completed, and the player plays with its time moving (or rests, paused) away from the target:
    /// it will not get there by itself. Retrying would land in the same place (a media timeline with a gap, a
    /// segment that starts late): the seek ends where playback is.
    private func isOffTarget(lastTime: inout TimeInterval) -> Bool {
        let current = player.currentTime().seconds
        defer {
            lastTime = current
        }
        // (`.seeking` with nothing in flight or pending should not happen; if it does, it ends the same way.)
        guard inFlight == nil, pending == nil, phase == .loading || phase == .seeking, current.isFinite, !isNearTarget(current) else {
            return false
        }
        switch player.timeControlStatus {
        case .playing:
            return current > lastTime + 0.02
        case .paused:
            return true
        default:
            return false
        }
    }

    private func finishOffTarget() {
        let current = player.currentTime().seconds
        if let target {
            seekLogger.error("Seek to \(target, format: .fixed(precision: 1)) s continues at \(current, format: .fixed(precision: 1)) s instead (landing error \(current - target, format: .fixed(precision: 1)) s)")
        }
        finish()
    }

    private func finish() {
        watchTask?.cancel()
        watchTask = nil
        phase = .idle
        target = nil
        recoveryStep = 0
        stuckRecoveryStep = 0
        landings += 1
        onLanded?()
    }

    /// Follows a user seek until playback continues there: checks the player as it changes, and recovers when it
    /// takes longer than `stallLimit`.
    private func watch(generation: Int) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            var waited: Duration = .zero
            let step: Duration = .milliseconds(100)
            var buffered = -1.0
            var offTarget: Duration = .zero
            var lastTime = TimeInterval.nan
            while !Task.isCancelled {
                try? await Task.sleep(for: step)
                guard !Task.isCancelled, let self else {
                    return
                }
                guard self.phase == .seeking || self.phase == .loading else {
                    return
                }
                self.checkLanded()
                guard self.isBusy else {
                    return
                }
                if self.isOffTarget(lastTime: &lastTime) {
                    offTarget += step
                    if offTarget >= Self.offTargetLimit {
                        self.finishOffTarget()
                        return
                    }
                } else {
                    offTarget = .zero
                }
                // Waiting without wanting to play (paused while seeking) is not a stall, nor is waiting while media
                // arrives (a slow network).
                let end = self.bufferedEnd()
                if end > buffered + 0.5 {
                    buffered = end
                    waited = .zero
                } else if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate || self.inFlight != nil {
                    waited += step
                }
                if waited >= self.stallLimit {
                    waited = .zero
                    self.recover()
                }
            }
        }
    }

    /// The end of the media buffered around the target (seconds), -1 when none is.
    private func bufferedEnd() -> TimeInterval {
        guard let target else {
            return -1
        }
        return bufferedEnd(around: target)
    }

    private func bufferedEnd(around target: TimeInterval) -> TimeInterval {
        guard let item = player.currentItem, target.isFinite else {
            return -1
        }
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        for range in ranges where range.start.isNumeric && range.duration.isNumeric {
            let start = range.start.seconds
            let end = start + range.duration.seconds
            if start <= target + 1 && end >= target - 30 {
                return end
            }
        }
        return -1
    }

    /// 1. Seek again from the key frame at or before the target (decoding from there needs no earlier media,
    ///    and a fresh seek restarts AVPlayer's loading); 2. `onStuck` (e.g. a new item at the target);
    /// 3. fail with a message.
    private func recover() {
        guard let target, player.currentItem === item else {
            return
        }
        recoveryStep += 1
        seekLogger.error("Seek to \(target, format: .fixed(precision: 1)) s does not play (step \(self.recoveryStep))")
        switch recoveryStep {
        case 1:
            pendingTask?.cancel()
            pendingTask = nil
            pending = nil
            droppedCount = 0
            inFlightGeneration += 1
            lastIssue = .now
            let generation = inFlightGeneration
            inFlight = Request(time: target, precision: .exact, isFinal: true)
            phase = .seeking
            onWillSeek?(target)
            startSeek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .zero, generation: generation)
        case 2:
            // Kept across a `reset()` by the handler, for its resume seek on the new item.
            stuckRecoveryStep = recoveryStep
            guard onStuck?(target) == true else {
                stuckRecoveryStep = 0
                fail(at: target)
                return
            }
            guard self.target != nil, self.item != nil else {
                // The handler restarted playback (another route): its resume seek follows the target from now on.
                return
            }
            // The handler replaced the item (or will, once it is ready): the seek is followed on the new one.
            pendingTask?.cancel()
            pendingTask = nil
            pending = nil
            droppedCount = 0
            inFlight = nil
            inFlightGeneration += 1
            phase = .loading
            item = player.currentItem
        default:
            fail(at: target)
        }
    }

    private func fail(at target: TimeInterval) {
        watchTask?.cancel()
        watchTask = nil
        pendingTask?.cancel()
        pendingTask = nil
        inFlight = nil
        inFlightGeneration += 1
        pending = nil
        stuckRecoveryStep = 0
        phase = .failed
        onFailed?(target)
    }

    #if DEBUG
    /// Debug harness (`seek-fail:`): the state of a seek to `seconds` that did not play, as after every recovery step.
    func debugFail(at seconds: TimeInterval) {
        guard player.currentItem != nil else {
            return
        }
        reset()
        item = player.currentItem
        target = seconds
        fail(at: seconds)
    }
    #endif

    /// The position moved (the player's time observer): a seek that failed but plays at its target after all (e.g.
    /// the new item of the last recovery started there by itself) is no failure; the controls then follow playback.
    func positionChanged() {
        guard phase == .failed, let target, player.timeControlStatus == .playing else {
            return
        }
        let current = player.currentTime().seconds
        guard current.isFinite, abs(current - target) < Self.landingWindow else {
            return
        }
        seekLogger.info("Seek to \(target, format: .fixed(precision: 1)) s plays there after all (\(current, format: .fixed(precision: 1)) s)")
        clearFailure()
        onLanded?()
    }

    /// The player changed (status, item): a seek waiting for it may be done.
    func playerChanged() {
        if phase == .failed, player.timeControlStatus == .playing {
            // Playback continued after all (e.g. a live stream that reconnected): nothing to retry.
            clearFailure()
            return
        }
        if player.currentItem !== item, item != nil, phase != .loading {
            // Another item: its seeks start over.
            reset()
            return
        }
        checkLanded()
    }
}
