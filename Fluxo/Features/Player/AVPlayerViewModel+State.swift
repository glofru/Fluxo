//
//  AVPlayerViewModel+State.swift
//  Fluxo
//
//  The engine's events, the playback state, Now Playing, the player observers, the energy profile and the
//  timeline.
//

import AVKit
import Combine
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Player")

extension AVPlayerViewModel {
    // MARK: - Engine events

    func handle(_ event: StreamRemuxer.Event) {
        switch event {
        case .state(let state):
            switch state {
            case .failed(let message):
                streamError = message
            case .running:
                if case .reconnecting = playbackState {
                    streamError = nil
                }
            default:
                break
            }
            // Only offered while the input is open; a running recording stays stoppable meanwhile.
            canRecord = state == .running && route.isLiveRemux
            if !state.isActive {
                waitingForFirstSegment = false
            }
            refreshPlaybackState()

        case .segmentWritten(let statistics):
            if statistics.segmentsWritten == 1 || statistics.segmentsWritten % 15 == 0 {
                logger.info("Segments: \(statistics.segmentsWritten) written, window \(statistics.segmentCount) segments \(statistics.duration)s \(statistics.bytes) bytes")
            }
            if waitingForFirstSegment {
                waitingForFirstSegment = false
                if statistics.hasMasterPlaylist, let configuration = remuxer.configuration,
                   let masterURL = SimpleHTTPServer.url(forFileNamed: configuration.masterPlaylistFileName) {
                    // Extra audio tracks or text subtitles: the master playlist lists them as renditions.
                    logger.info("Master playlist: \(statistics.audioTrackCount) audio, \(statistics.subtitleTrackCount) subtitle tracks")
                    streamURL = masterURL
                }
                attachRemuxedStream()
            }

        case .recordingStarted:
            isRecording = true

        case .recordingProgress(let progress):
            timeline.updateRecordingDuration(progress.duration)
            enforceRecordingLimits(duration: progress.duration)

        case .recordingStopped(let progress):
            logger.info("Recording stopped: \(progress.url.lastPathComponent, privacy: .public) \(progress.duration)s \(progress.bytes) bytes")
            isRecording = false
            timeline.updateRecordingDuration(0)
            recordings.finalize(progress.url)

        case .recordingFailed(let url, let message):
            isRecording = false
            recordingError = message
            timeline.updateRecordingDuration(0)
            if let url {
                // Keeps whatever was written before the failure (removed when empty).
                recordings.finalize(url)
            }
        }
    }

    // MARK: - State

    func refreshPlaybackState() {
        let state = computePlaybackState()
        if state != playbackState {
            logger.info("Playback state: \(state.label, privacy: .public) (engine: \(String(describing: self.remuxer.state), privacy: .public))")
            playbackState = state
            updateNowPlaying()
        }
        // Optional work (a TV guide refresh) waits while this device plays (not while a Chromecast does).
        PowerMonitor.shared.isPlaybackActive = !isCasting && (state == .playing || state.isBusy)
    }

    // MARK: - Now Playing

    func configureRemoteCommands() {
        nowPlaying.register(NowPlayingController.Commands(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            skipBackward: { [weak self] in self?.skipBackward() },
            skipForward: { [weak self] in self?.skipForward() },
            nextChannel: { [weak self] in self?.nextChannel() },
            previousChannel: { [weak self] in self?.previousChannel() }
        ))
    }

    func updateNowPlaying() {
        guard let channel = currentChannel else {
            nowPlaying.clear()
            return
        }
        nowPlaying.update(
            title: channel.name ?? String(localized: "Fluxo", comment: "Now Playing title when the channel has no name; the app name."),
            item: currentItem,
            isLive: isCasting ? (cast.mediaStatus?.isLive ?? true) : (route.isLiveRemux || player.currentItem?.duration.isIndefinite == true),
            elapsed: timeline.currentTime,
            duration: timeline.duration,
            isPlaying: playbackState == .playing,
            canSeek: canSeek,
            canZap: canZap
        )
    }

    private func computePlaybackState() -> PlaybackState {
        guard currentChannel != nil else {
            return .idle
        }
        if isCasting {
            return castPlaybackState
        }
        if let itemFailure {
            return .failed(itemFailure)
        }
        let item = player.currentItem
        if route != .direct {
            switch remuxer.state {
            case .failed(let message) where item == nil || player.timeControlStatus != .playing:
                return .failed(message)
            case .reconnecting(let attempt):
                return .reconnecting(attempt: attempt)
            case .opening where item == nil:
                return .connecting
            default:
                break
            }
        } else if streamError != nil && item == nil {
            return .failed(streamError ?? "")
        }
        if didReachEnd {
            return .ended
        }
        guard let item else {
            if let streamError {
                return .failed(streamError)
            }
            return route == .direct ? .connecting : .buffering
        }
        switch player.timeControlStatus {
        case .playing:
            return .playing
        case .waitingToPlayAtSpecifiedRate:
            return .buffering
        case .paused:
            return item.status == .readyToPlay ? .paused : .buffering
        @unknown default:
            return .buffering
        }
    }

    func observePlayer() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else {
                    return
                }
                if status == .playing {
                    self.itemRecoveryAttempts = 0
                }
                self.watchForStall()
                self.seeker.playerChanged()
                self.refreshPlaybackState()
            }
            .store(in: &cancellables)

        // The periodic time observer is installed by `applyEnergyProfile()`, at the interval of what is on screen.
    }

    /// Samples the playback position (the timeline of the controls, the watch progress, the seeker's landing checks)
    /// at `interval`, replacing the observer installed before.
    private func installTimeObserver(interval: CMTime) {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, let item = self.player.currentItem {
                    self.sampledBufferedEnd = Self.bufferedEnd(of: item)
                    self.seeker.positionChanged()
                }
                self?.updateTimeline()
            }
        }
    }

    // MARK: - Energy

    /// Sizes the work of playback to what is on screen and to Low Power Mode and the thermal state (see
    /// `PlaybackEnergyProfile`). Called when any of them changes.
    func applyEnergyProfile() {
        let power = PowerMonitor.shared
        let profile = PlaybackEnergyProfile(PlaybackEnergyProfile.Conditions(
            isLowPowerModeEnabled: power.isLowPowerModeEnabled,
            thermalState: power.thermalState,
            isInBackground: power.isInBackground,
            isPlayerScreenVisible: isPlayerUIVisible,
            isPlayerPresented: isPresented,
            isPictureInPictureActive: isPictureInPictureActive
        ))
        let previous = energyProfile
        guard profile != previous else {
            return
        }
        energyProfile = profile
        logger.info("Energy: \(profile.summary, privacy: .public)")
        if previous?.timeObserverInterval != profile.timeObserverInterval {
            installTimeObserver(interval: profile.timeObserverInterval)
            if previous != nil {
                // The controls show the position at once, not at the first tick of the new interval.
                updateTimeline()
            }
        }
        if previous?.qualityLimit != profile.qualityLimit, let item = player.currentItem {
            applyQualityLimit(to: item)
        }
        if player.preventsDisplaySleepDuringVideoPlayback != profile.preventsDisplaySleep {
            player.preventsDisplaySleepDuringVideoPlayback = profile.preventsDisplaySleep
        }
        surface.rendersVideo = profile.rendersVideo
    }

    /// The highest quality of an adaptive stream the player may choose now. No effect on streams with one quality.
    func applyQualityLimit(to item: AVPlayerItem) {
        let limit = energyProfile?.qualityLimit ?? .none
        if item.preferredMaximumResolution != limit.maximumResolution {
            item.preferredMaximumResolution = limit.maximumResolution
        }
        if item.preferredPeakBitRate != limit.peakBitRate {
            item.preferredPeakBitRate = limit.peakBitRate
        }
    }

    func updateTimeline() {
        guard !isCasting else {
            // The receiver's position drives the timeline (`updateCastTimeline()`).
            return
        }
        // Also polled here, as a fallback for the KVO observation in PlayerSurface (cheap: one property read).
        updatePictureInPicturePossible(surface.isPictureInPicturePossible)
        guard let item = player.currentItem else {
            if canSeek {
                canSeek = false
            }
            return
        }
        let current = item.currentTime().seconds
        let duration = item.duration.isNumeric ? item.duration.seconds : 0
        let range = seekableRange(of: item)
        let seekableStart = range?.start ?? 0
        let seekableEnd = range?.end ?? 0
        let isLive = isTimeShiftAvailable || item.duration.isIndefinite
        // Measured from the live point (where `goLive()` seeks), so the timeline, "-m:ss Go Live" and the LIVE
        // indicator agree: a scrub a few seconds back shows "Go Live" with the same time as the timeline.
        let latency = isLive ? liveOffset(of: item) : 0
        let behind = isLive ? max(0, seekableEnd - latency - current) : 0
        // With some hysteresis, so that playback hovering around the tolerance does not flip LIVE and Go Live.
        let tolerance = Self.liveEdgeTolerance(latency: latency) + (timeline.isAtLiveEdge ? 1.5 : 0)
        let atLiveEdge = !isLive || behind <= tolerance

        timeline.update(
            currentTime: current,
            duration: duration,
            seekableStart: seekableStart,
            seekableEnd: seekableEnd,
            timeBehindLive: behind,
            liveLatency: latency,
            isAtLiveEdge: atLiveEdge
        )
        let seekable = (range.map { $0.end - $0.start } ?? 0) > 2
        if seekable != canSeek {
            canSeek = seekable
            updateNowPlaying()
        }
    }
}
