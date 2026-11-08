//
//  AVPlayerViewModel+Transport.swift
//  Fluxo
//
//  Play / pause, skips, seeks and scrubbing, and the seeker that makes AVPlayer's seeks reliable.
//

import AVKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Player")

extension AVPlayerViewModel {
    // MARK: - Transport

    func togglePlayPause() {
        if isCasting {
            if playbackState == .playing || playbackState == .buffering {
                pause()
            } else {
                play()
            }
            return
        }
        if player.timeControlStatus == .paused {
            play()
        } else {
            pause()
        }
    }

    func play() {
        if isCasting {
            switch playbackState {
            case .failed, .ended:
                castCurrentChannel(startTime: nil)
            default:
                cast.play()
            }
            return
        }
        if case .failed = playbackState {
            retry()
            return
        }
        guard let item = player.currentItem else {
            return
        }
        if didReachEnd {
            didReachEnd = false
            seeker.seek(to: 0)
        } else if isTimeShiftAvailable, let range = seekableRange(of: item), item.currentTime().seconds < range.start + 1 {
            // Paused for longer than the time-shift window: continue from the oldest buffered media.
            seek(to: range.start + 2)
        }
        activateAudioSession()
        player.play()
    }

    func pause() {
        if isCasting {
            cast.pause()
            return
        }
        player.pause()
    }

    /// Moves the playback position by `seconds` (negative goes back), within the seekable range.
    func skip(by seconds: TimeInterval) {
        if isCasting {
            seekOnCast(to: timeline.currentTime + seconds)
            return
        }
        guard canSeek, let item = player.currentItem, let range = seekableRange(of: item) else {
            return
        }
        let upperBound = isTimeShiftAvailable ? range.end - liveOffset(of: item) : range.end
        // Quick taps add up: from where the previous skip goes, not from where the player still is.
        let base = seeker.target ?? item.currentTime().seconds
        let target = min(max(base + seconds, range.start + 0.5), max(range.start + 0.5, upperBound))
        seeker.seek(to: target, isBurst: true)
        if didReachEnd, seconds < 0 {
            didReachEnd = false
            refreshPlaybackState()
        }
    }

    func skipBackward() {
        skip(by: -Self.skipBackwardInterval)
    }

    func skipForward() {
        skip(by: Self.skipForwardInterval)
    }

    /// Seeks to `seconds` on the item timeline (e.g. from the scrubber), within the seekable range.
    func seek(toSeconds seconds: TimeInterval) {
        if isCasting {
            seekOnCast(to: seconds)
            return
        }
        guard canSeek, let item = player.currentItem, let range = seekableRange(of: item) else {
            return
        }
        let upperBound = isTimeShiftAvailable ? range.end - liveOffset(of: item) : range.end
        seek(to: min(max(seconds, range.start + 0.5), max(range.start + 0.5, upperBound)))
        if didReachEnd {
            didReachEnd = false
            refreshPlaybackState()
        }
    }

    /// Whether the video itself follows the finger on the scrubber: a local file (a download, a recording) seeks
    /// to key frames at once. Streams only seek when the scrubber is released (each seek reloads media from the
    /// network); movies AVPlayer plays from the network show frame previews instead (`scrubPreview`).
    var scrubbingMovesVideo: Bool {
        !isCasting && route == .direct && currentChannel?.url.map { $0.isFileURL || isPlayingDownload } == true
    }

    /// The scrubber is being dragged to `seconds`: the video follows when it can (`scrubbingMovesVideo`), and the
    /// frame preview is updated. The seek itself is made when the scrubber is released (`seek(toSeconds:)`).
    func scrub(toSeconds seconds: TimeInterval) {
        guard canSeek, !isCasting, let item = player.currentItem, let range = seekableRange(of: item) else {
            return
        }
        let time = min(max(seconds, range.start), range.end)
        if scrubbingMovesVideo {
            seeker.seek(to: time, precision: .keyFrame, isFinal: false)
        } else {
            scrubPreview.request(time)
        }
    }

    /// The scrubber was touched (the frame previews start) or released (they stop).
    func setScrubbing(_ isScrubbing: Bool) {
        // (HLS has no frames to generate: its media is in segments.)
        if isScrubbing, !isCasting, !scrubbingMovesVideo, route == .direct, !isTimeShiftAvailable,
           let asset = player.currentItem?.asset as? AVURLAsset, asset.url.pathExtension.lowercased() != "m3u8" {
            scrubPreview.begin(asset: asset, isLocal: asset.url.isFileURL)
        } else if !isScrubbing {
            scrubPreview.end()
        }
    }

    /// A seek that could not play (`PlayerSeeker.Phase.failed`) is tried again, from where it went.
    func retrySeek() {
        guard let target = seeker.target else {
            seeker.clearFailure()
            return
        }
        seeker.clearFailure()
        seek(toSeconds: target)
    }

    /// Jumps back to the live edge of a time-shifted live stream.
    func goLive() {
        guard !isCasting, isTimeShiftAvailable, let item = player.currentItem, let range = seekableRange(of: item) else {
            return
        }
        seek(to: max(range.start, range.end - liveOffset(of: item)))
        player.play()
    }

    // MARK: - Seeking

    func seekableRange(of item: AVPlayerItem) -> (start: TimeInterval, end: TimeInterval)? {
        guard let range = item.seekableTimeRanges.last?.timeRangeValue, range.start.isNumeric, range.duration.isNumeric else {
            return nil
        }
        let start = range.start.seconds
        return (start, start + range.duration.seconds)
    }

    /// How far behind the live point still counts as live. The seekable range grows a segment at a time, so
    /// playing live drifts by up to one segment (about a third of the recommended latency, which is three
    /// segments) before the next one arrives.
    static func liveEdgeTolerance(latency: TimeInterval) -> TimeInterval {
        max(3, latency / 3 + 1)
    }

    /// Distance from the live edge AVPlayer recommends for smooth live playback.
    func liveOffset(of item: AVPlayerItem) -> TimeInterval {
        let recommended = item.recommendedTimeOffsetFromLive
        return recommended.isNumeric && recommended.seconds > 0 ? recommended.seconds : 6
    }

    func seek(to seconds: TimeInterval) {
        seeker.seek(to: seconds)
    }

    /// Seeks a new item to `position`. AVPlayer can drop a seek made while it starts an item (it then reports
    /// the seek as not finished and plays from the start): the seeker makes it again (see `PlayerSeeker`).
    /// - Parameter continuesRecovery: the item replaces one whose seek did not play (see `recoverStuckSeek`).
    func resume(at position: TimeInterval, in item: AVPlayerItem, continuesRecovery: Bool = false) {
        guard player.currentItem === item else {
            return
        }
        seeker.seek(to: position, continuesRecovery: continuesRecovery)
    }

    /// The item's time changed by a seek the seeker did not make: Picture in Picture's skip buttons (they seek
    /// AVPlayer themselves). Through the engine, a skip just past what the player buffered asks for the segment after
    /// the last one it loaded, which the engine may have written ahead from inside a GOP: served as written, playback
    /// starts at its next key frame, seconds after the target (or the picture freezes over the audio until then).
    /// AVPlayer asks for that segment before it posts the jump, so telling the engine now is too late for it: the
    /// seek is made again through the seeker, which tells the engine first (`onWillSeek`) and follows it like any
    /// other. A jump within what was buffered plays from there (the media before it is continuous) and is left alone,
    /// and so are the jumps outside Picture in Picture: every seek of the app goes through the seeker, so those are
    /// AVPlayer's own (e.g. a seek it clamps to the end of a playlist that still grows), not to be made again.
    /// `itemID`: the `ObjectIdentifier` of the item that posted the jump.
    func itemTimeJumped(_ itemID: ObjectIdentifier) {
        var isPictureInPicture = isPictureInPictureActive
        #if DEBUG
        isPictureInPicture = isPictureInPicture || debugTreatsJumpsAsPictureInPicture
        #endif
        guard isPictureInPicture, let item = player.currentItem, ObjectIdentifier(item) == itemID, !isCasting, route.isOnDemandRemux, !seeker.isMoving,
              let bufferedEnd = sampledBufferedEnd else {
            return
        }
        let time = item.currentTime().seconds
        guard time.isFinite, time > bufferedEnd - 0.5 else {
            return
        }
        logger.info("Time jumped to \(time, format: .fixed(precision: 1)) s past the buffer (\(bufferedEnd, format: .fixed(precision: 1)) s) outside the seeker: seeking there again")
        seeker.seek(to: time)
    }

    func configureSeeker() {
        seeker.onLanded = { [weak self] in
            // Now Playing only gets a new elapsed time on state changes, so push the new position
            // (otherwise the Lock Screen / Control Center scrubber drifts after a skip or a scrub).
            self?.updateTimeline()
            self?.updateNowPlaying()
        }
        seeker.onWillSeek = { [weak self] target in
            // The engine produces the segment of the target from a key frame (also the segment after the last one
            // the player loaded, which it may have written ahead from inside a GOP).
            guard let self, !self.isCasting, self.route.isOnDemandRemux else {
                return
            }
            self.remuxer.noteSeek(to: target)
        }
        seeker.onStuck = { [weak self] target in
            self?.recoverStuckSeek(at: target) ?? false
        }
        seeker.onFailed = { [weak self] target in
            logger.error("Seek to \(target, format: .fixed(precision: 1)) s failed")
            self?.refreshPlaybackState()
        }
    }

    /// A seek that does not play even from the key frame before it: a movie AVPlayer plays itself moves to the
    /// engine (or gets a new item), a movie through the engine gets a new item from the local server, both at the
    /// target. A live channel has nothing to recover to (its window moves): the seek fails.
    private func recoverStuckSeek(at target: TimeInterval) -> Bool {
        guard !isCasting, currentChannel != nil, player.currentItem != nil, !isTimeShiftAvailable, !route.isLiveRemux else {
            return false
        }
        if fallBackToEngine(reason: "a seek did not play", at: target) {
            pendingResumePosition = target
            pendingResumeContinuesRecovery = true
            return true
        }
        switch route {
        case .direct:
            guard let asset = player.currentItem?.asset as? AVURLAsset else {
                return false
            }
            logger.info("Seek did not play: new item at \(target, format: .fixed(precision: 1)) s")
            pendingResumePosition = target
            pendingResumeContinuesRecovery = true
            attach(Self.makeItem(url: asset.url, isLocal: asset.url.isFileURL))
            player.play()
            return true
        case .remux:
            guard remuxer.isProcessing else {
                return false
            }
            logger.info("Seek did not play: new item from the engine at \(target, format: .fixed(precision: 1)) s")
            pendingResumePosition = target
            pendingResumeContinuesRecovery = true
            // The new item starts at the target (its playlist says so), not where the first one did.
            remuxer.setPlaylistStart(target)
            server.start(root: outputDirectory)
            attachRemuxedStream()
            return true
        }
    }
}
