//
//  AVPlayerViewModel+Playback.swift
//  Fluxo
//
//  Starting and tearing down playback: the route (AVPlayer or the remux engine), the player item, failures,
//  the fallback to the engine, stalls, and the engine's disk use.
//

import AVKit
import Combine
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Player")

extension AVPlayerViewModel {
    // MARK: - Playback setup

    var isSessionHealthy: Bool {
        switch playbackState {
        case .idle, .ended, .failed:
            return false
        default:
            return true
        }
    }

    /// - Parameter forcedRoute: the route to use instead of the one the URL and the kind of the item call for
    ///   (the engine, after AVPlayer could not play a movie directly).
    /// - Parameter startTime: where an on-demand item through the engine starts (e.g. where the movie played
    ///   before it moved to the engine); otherwise its saved position (`resumePosition`).
    func start(_ channel: PlayableChannel, url: URL, route forcedRoute: PlaybackRoute? = nil, startTime: TimeInterval? = nil) {
        tearDownPlayback()
        isLocalPlaybackSuspended = false
        if forcedRoute == nil {
            didFallBackToEngine = false
        }

        currentChannel = channel
        streamError = nil
        recordingError = nil
        isPlayingDownload = url.isFileURL && currentItem?.id == channel.id && currentItem?.url != nil && channel.url != url
        isWaitingForNetwork = false
        if NetworkMonitor.shared.isOffline, !NetworkMonitor.isReachableOffline(url) {
            // Say so at once instead of waiting for the stream to time out (or the engine to give up reconnecting);
            // it starts by itself when the network returns.
            isWaitingForNetwork = true
            streamError = currentItem?.kind == .live || currentItem == nil
                ? String(localized: "You're offline. This plays when your device is connected to the internet again.", comment: "Player error: the device has no network connection; a live channel or stream cannot start.")
                : String(localized: "You're offline. Connect to the internet to watch this, or download it to watch it offline.", comment: "Player error: the device has no network connection and this movie or episode is not downloaded.")
            refreshPlaybackState()
            return
        }
        route = forcedRoute ?? PlaybackRoute(url: url, kind: currentItem?.kind)
        logger.info("Route: \(String(describing: self.route), privacy: .public) for a \(url.pathExtension.isEmpty ? "extensionless" : url.pathExtension, privacy: .public) URL")
        // Through the engine, a seek far into a movie waits for the engine to seek the input and read a GOP: on a slow
        // network that takes about as long as AVPlayer's own stall detection, which would only start it over (the
        // engine still works on that segment, and fails it itself after `StreamRemuxer.segmentRequestTimeout`).
        seeker.stallLimit = route.isOnDemandRemux ? Self.engineSeekStallLimit : Self.seekStallLimit
        surface.startsPictureInPictureAutomatically = PlayerPreferences.autoPictureInPicture
        activateAudioSession()

        switch route {
        case .direct:
            attach(Self.makeItem(url: url, isLocal: url.isFileURL))
            player.play()

        case .remux(let isLive):
            server.start(root: outputDirectory)

            var configuration = StreamRemuxer.Configuration(
                inputURL: url,
                outputDirectory: outputDirectory,
                name: "\(channel.id.uuidString.prefix(8))-\(UUID().uuidString.prefix(8))",
                isLive: isLive
            )
            #if os(tvOS)
            // The TV player covers the screen until the first frame: a server that refuses the connection says so in
            // seconds there, with Try Again, instead of after FFmpeg's own retries.
            configuration.quickOpen = true
            #endif
            if isLive {
                configuration.maxWindowDuration = PlayerPreferences.timeShiftDuration
                configuration.maxWindowBytes = Self.diskBudget(for: outputDirectory, maximum: PlayerPreferences.timeShiftBytes)
            } else {
                // Movies and episodes: a complete VOD playlist whose segments the engine produces as AVPlayer
                // asks for them (seeking the input for a jump), reading at most `onDemandReadAhead` ahead of
                // the player. The segments farthest from the player are deleted beyond the disk budget.
                configuration.segmentDuration = Self.onDemandSegmentDuration
                configuration.readAheadDuration = Self.onDemandReadAhead
                configuration.maxWindowDuration = 0
                configuration.maxWindowBytes = Self.diskBudget(for: outputDirectory, maximum: PlayerPreferences.timeShiftBytes)
                // A resume: the engine produces the segment there first and the playlist starts there, instead of
                // the player waiting for the first segment of the movie before it can seek.
                let resume = startTime ?? currentItem.flatMap { resumePosition?($0) }
                if let resume, resume.isFinite, resume >= Self.engineStartThreshold {
                    configuration.startTime = resume
                }
            }
            if !isLive {
                watchDiskSpace()
            }

            guard let streamURL = SimpleHTTPServer.url(forFileNamed: configuration.playlistFileName) else {
                streamError = String(localized: "Unable to create the local stream address.", comment: "Player error: the in-app streaming server could not provide an address.")
                refreshPlaybackState()
                return
            }
            // Segments of on-demand playlists are produced when AVPlayer requests them.
            if isLive {
                server.setFileProvider(nil)
            } else {
                let provider: SimpleHTTPServer.FileProvider = { [weak self] fileName in
                    guard let self else {
                        return false
                    }
                    return await self.provideFile(named: fileName)
                }
                server.setFileProvider(provider)
            }
            do {
                try remuxer.start(configuration)
            } catch {
                streamError = error.localizedDescription
                refreshPlaybackState()
                return
            }
            self.streamURL = streamURL
            // The AVPlayerItem is created once the engine reports the first complete segment.
            waitingForFirstSegment = true
            isTimeShiftAvailable = isLive
            // Recording becomes available once the engine reports that the input is open.
            canRecord = false
        }
        refreshPlaybackState()
    }

    /// Asks the engine for a file AVPlayer requests from the loopback server and waits until it exists.
    private func provideFile(named fileName: String) async -> Bool {
        await remuxer.requestFile(named: fileName)
    }

    /// Stops the engine and the player item of the current channel. A running recording is finalized.
    func tearDownPlayback() {
        attachTask?.cancel()
        attachTask = nil
        diskSpaceTask?.cancel()
        diskSpaceTask = nil
        stallTask?.cancel()
        stallTask = nil
        server.setFileProvider(nil)
        waitingForFirstSegment = false
        streamURL = nil
        itemCancellables.removeAll()
        itemFailure = nil
        itemFailureNSError = nil
        didReachEnd = false
        itemRecoveryAttempts = 0
        pendingResumePosition = nil
        pendingResumeContinuesRecovery = false

        player.pause()
        player.replaceCurrentItem(with: nil)
        seeker.reset()
        scrubPreview.reset()
        mediaSelection.attach(nil)

        let recordings = recordings
        remuxer.stop(recordingCompletion: { url in
            recordings.finalize(url)
        })

        isRecording = false
        canRecord = false
        isTimeShiftAvailable = false
        canSeek = false
        timeline.reset()
    }

    func attachRemuxedStream() {
        guard let streamURL else {
            return
        }
        let isLive = route.isLiveRemux
        attachTask?.cancel()
        attachTask = Task { [weak self, server] in
            // Deterministic start: the playlist has a complete segment and the server accepts connections.
            await server.waitUntilListening()
            guard let self, !Task.isCancelled, self.streamURL == streamURL else {
                return
            }
            let item = Self.makeItem(url: streamURL, isLocal: true)
            // Keep reloading the live playlist while paused, so the time-shift window stays current.
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = isLive
            self.attach(item)
            self.player.play()
        }
    }

    func attach(_ item: AVPlayerItem) {
        itemCancellables.removeAll()
        sampledBufferedEnd = nil
        didReachEnd = false
        itemFailure = nil
        itemFailureNSError = nil

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, item === self.player.currentItem else {
                    return
                }
                if status == .readyToPlay {
                    // HLS renditions are known once the playlist is read.
                    self.mediaSelection.reload()
                    self.checkTracksAreDecodable(item)
                }
                if status == .failed {
                    self.handleItemFailure(item.error)
                } else if status == .readyToPlay, let position = self.pendingResumePosition {
                    // Back from casting (continue where the Chromecast was), or the engine took a movie over.
                    let continuesRecovery = self.pendingResumeContinuesRecovery
                    self.pendingResumePosition = nil
                    self.pendingResumeContinuesRecovery = false
                    self.resume(at: position, in: item, continuesRecovery: continuesRecovery)
                }
                self.refreshPlaybackState()
            }
            .store(in: &itemCancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.didReachEnd = true
                self?.refreshPlaybackState()
            }
            .store(in: &itemCancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
                self?.handleItemFailure(error)
            }
            .store(in: &itemCancellables)

        // Not moved to the main queue when it is posted there: AVPlayer asks for the segment of the new time right
        // after, and the engine must know about the seek before (see `itemTimeJumped(_:)`). AVPlayer may also post it
        // on another queue, so the subscriber is `@Sendable` rather than isolated to the main actor (a main-actor
        // closure would stop at Swift's actor check there), and it names the item by identity.
        let itemID = ObjectIdentifier(item)
        NotificationCenter.default.publisher(for: AVPlayerItem.timeJumpedNotification, object: item)
            .sink { @Sendable [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.itemTimeJumped(itemID)
                    }
                } else {
                    Task { @MainActor in
                        self?.itemTimeJumped(itemID)
                    }
                }
            }
            .store(in: &itemCancellables)

        applyQualityLimit(to: item)
        player.replaceCurrentItem(with: item)
        mediaSelection.attach(item, contentKey: currentChannel?.url?.absoluteString, allowsExternalSubtitles: isOnDemandContent)
    }

    /// A movie, an episode or a recording (a subtitle file can be loaded for it), not a live channel.
    private var isOnDemandContent: Bool {
        if let currentItem {
            return currentItem.kind != .live
        }
        guard let url = currentChannel?.url else {
            return false
        }
        return url.isFileURL || route == .remux(isLive: false)
    }

    private func handleItemFailure(_ error: (any Error)?) {
        let message = error?.localizedDescription ?? String(localized: "Playback failed.", comment: "Player error shown when the system gives no reason.")
        // An audio track this device cannot decode fails the whole item: the recovered item uses the default one.
        let failedAfterAudioSwitch = mediaSelection.playbackFailed(error)
        if let error {
            let nsError = error as NSError
            logger.error("Player item error \(nsError.domain, privacy: .public) \(nsError.code): \(message, privacy: .public)")
        }
        if fallBackToEngine(reason: "the item failed") {
            return
        }
        let position = player.currentItem.map { $0.currentTime().seconds } ?? timeline.currentTime
        if route.isOnDemandRemux, !failedAfterAudioSwitch, timeline.duration > 0, position.isFinite,
           position >= timeline.duration - 2 * Self.onDemandSegmentDuration {
            // The media ended a little before the planned end of the playlist (durations of MPEG-TS files
            // are estimated): it simply ended.
            didReachEnd = true
            refreshPlaybackState()
            return
        }
        if route != .direct, remuxer.isProcessing, itemRecoveryAttempts < 3 || failedAfterAudioSwitch {
            // The engine still produces media: the player lost the local stream (e.g. the server
            // socket was reclaimed in the background). Restart the server and attach a fresh item, at the
            // same position for a movie.
            itemRecoveryAttempts += 1
            if route.isOnDemandRemux, position.isFinite, position > 1 {
                pendingResumePosition = position
                // The new item starts there (not where the first one did), so the engine is not moved twice.
                remuxer.setPlaylistStart(position)
            }
            server.start(root: outputDirectory)
            attachRemuxedStream()
            return
        }
        logger.error("Player item failed: \(message, privacy: .public)")
        itemFailure = message
        itemFailureNSError = error.map { $0 as NSError }
        streamError = message
        refreshPlaybackState()
    }

    /// Whether the current movie or episode played directly by AVPlayer may move to the engine: AVPlayer
    /// opens MP4 files only from servers with byte ranges, does not decode HEVC tagged `hev1` (nor DTS, TrueHD and
    /// other audio the engine converts), and opens several connections (some IPTV servers allow one per account,
    /// which stalls seeking).
    private var canFallBackToEngine: Bool {
        guard route == .direct, !didFallBackToEngine, !isCasting, !isPlayingDownload, currentItem?.kind != .live,
              let url = currentChannel?.url else {
            return false
        }
        return PlaybackRoute.onDemandFallback(for: url) != nil
    }

    /// Plays the current movie or episode through the engine instead of AVPlayer's own loader, from where it
    /// was. Returns false when it does not apply (see `canFallBackToEngine`).
    /// - Parameter startPosition: where it continues; by default where the movie is.
    @discardableResult
    func fallBackToEngine(reason: String, at startPosition: TimeInterval? = nil) -> Bool {
        guard canFallBackToEngine, let channel = currentChannel, let url = channel.url,
              let fallback = PlaybackRoute.onDemandFallback(for: url) else {
            return false
        }
        logger.info("Playing through the engine: \(reason, privacy: .public)")
        let position = startPosition ?? player.currentItem.map { $0.currentTime().seconds } ?? 0
        didFallBackToEngine = true
        start(channel, url: url, route: fallback, startTime: position.isFinite && position > 1 ? position : nil)
        if position.isFinite, position > 1 {
            pendingResumePosition = position
        }
        return true
    }

    /// An MP4 / MOV file whose video AVPlayer cannot decode (HEVC tagged `hev1`) plays its audio over a black picture,
    /// and one whose audio it cannot decode (DTS, which it does not even list) plays silently: the engine plays it
    /// instead, copying what AVPlayer decodes and converting the rest (`PlaybackRoute.engineReason`).
    private func checkTracksAreDecodable(_ item: AVPlayerItem) {
        // Items of URLs (`AVPlayerItem(url:)`) have an `AVURLAsset`, which is `Sendable`: its tracks load off the main actor.
        guard canFallBackToEngine, let asset = item.asset as? AVURLAsset else {
            return
        }
        Task { [weak self] in
            guard let reason = await PlaybackRoute.engineReason(for: asset),
                  let self, self.player.currentItem === item else {
                return
            }
            self.fallBackToEngine(reason: reason)
        }
    }

    /// AVPlayer keeps waiting for a movie or episode it plays directly (typically after a seek, from a server
    /// that allows a single connection): after `stallTimeout` without the buffer growing, the engine takes over.
    func watchForStall() {
        stallTask?.cancel()
        stallTask = nil
        guard canFallBackToEngine, player.timeControlStatus == .waitingToPlayAtSpecifiedRate, let item = player.currentItem else {
            return
        }
        let bufferedEnd = Self.bufferedEnd(of: item)
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stallTimeout)
            guard !Task.isCancelled, let self, self.player.currentItem === item,
                  self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                  Self.bufferedEnd(of: item) < bufferedEnd + 1 else {
                return
            }
            self.fallBackToEngine(reason: "AVPlayer stalled for \(Self.stallTimeout)")
        }
    }

    static func bufferedEnd(of item: AVPlayerItem) -> TimeInterval {
        item.loadedTimeRanges.map { $0.timeRangeValue }.map { $0.start.seconds + $0.duration.seconds }.filter(\.isFinite).max() ?? 0
    }

    // MARK: - Limits and disk space
    //
    // The time-shift (DVR) window of live streams and its disk budget come from PlayerPreferences.

    /// Segments of on-demand playlists made by the engine. Short, so that a seek plays after one segment
    /// is read (at most a few MB), and a multiple of the usual 1–2 s GOP of IPTV movies.
    static let onDemandSegmentDuration: TimeInterval = 4
    /// Media the engine reads ahead of the player in an on-demand playlist, then pauses (the network radio
    /// rests until the player has used half of it).
    static let onDemandReadAhead: TimeInterval = 60
    /// Positions from which an on-demand item through the engine starts where it continues (see `start`): the
    /// positions `WatchProgressRecorder` resumes (it does not resume under 30 s).
    static let engineStartThreshold: TimeInterval = 30
    /// How long a seek may wait for media (the buffer not growing) before `PlayerSeeker` makes it again.
    static let seekStallLimit: Duration = .seconds(8)
    static let engineSeekStallLimit: Duration = .seconds(20)
    /// How long a movie played directly may wait for data (its buffer not growing) before the engine takes over.
    static let stallTimeout: Duration = .seconds(12)
    /// Free space kept in reserve while the segments of an on-demand input accumulate.
    static let onDemandFreeSpaceMargin: Int64 = 256 * 1024 * 1024

    /// Media AVPlayer buffers ahead of the playhead (in memory). Remuxed streams are read from the local
    /// disk, so a few seconds are enough; remote items keep more to ride out network hiccups. Without a
    /// value AVFoundation picks the size itself, which for long on-demand items can be minutes of video.
    static let localForwardBufferDuration: TimeInterval = 8
    static let remoteForwardBufferDuration: TimeInterval = 30

    static func makeItem(url: URL, isLocal: Bool) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = isLocal ? localForwardBufferDuration : remoteForwardBufferDuration
        return item
    }

    /// Disk budget of a remux session: at most `maximum` and never more than a tenth of the free space.
    private static func diskBudget(for directory: URL, maximum: Int64) -> Int64 {
        let minimum: Int64 = 64 * 1024 * 1024
        guard let available = PlatformStorage.availableCapacity(at: directory) else {
            return maximum
        }
        return min(maximum, max(minimum, available / 10))
    }

    /// The engine keeps a bounded number of segments of a planned on-demand playlist (its disk budget), but an
    /// on-demand input without a known duration is remuxed whole into a growing playlist, so that every position
    /// read so far stays seekable: playback stops with an error before that copy fills the disk.
    private func watchDiskSpace() {
        let directory = outputDirectory
        diskSpaceTask?.cancel()
        diskSpaceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else {
                    return
                }
                if let available = PlatformStorage.availableCapacity(at: directory), available < Self.onDemandFreeSpaceMargin {
                    self?.stopForDiskSpace()
                    return
                }
            }
        }
    }

    private func stopForDiskSpace() {
        logger.error("Not enough free space for the segments of the on-demand file: playback stops")
        tearDownPlayback()
        streamError = String(localized: "Not enough free space to play this file.", comment: "Player error: playing a movie or an episode file needs disk space for a temporary copy, and the device is almost full.")
        refreshPlaybackState()
    }
}
