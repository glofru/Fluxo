//
//  AVPlayerViewModel.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import AVKit
import Combine
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Player")

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

/// Drives playback for the whole app: one AVPlayer, one long-lived player view (for Picture in
/// Picture), the remux engine for live MPEG-TS channels and the loopback HLS server.
///
/// FluxoApp creates the only instance and the app has a single main scene (a `Window` on macOS,
/// multiple scenes disabled on iOS), because the loopback port, the PiP surface and the segment
/// directory can only have one owner.
///
/// It is `@Observable`: views re-render only for the properties they read, so e.g. the playlist
/// browser does not re-render whenever the playback state, seekability or PiP state changes.
@MainActor
@Observable
final class AVPlayerViewModel {

    enum PlaybackState: Equatable {
        case idle
        /// Connecting to the stream (engine opening, or AVPlayer loading a direct URL).
        case connecting
        /// Waiting for media: the first segment, or AVPlayer refilling its buffer.
        case buffering
        case playing
        case paused
        /// The live input dropped and the engine is reconnecting; buffered media keeps playing.
        case reconnecting(attempt: Int)
        case ended
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "Idle"
            case .connecting:
                return "Connecting…"
            case .buffering:
                return "Buffering…"
            case .playing:
                return "Playing"
            case .paused:
                return "Paused"
            case .reconnecting(let attempt):
                return attempt > 1 ? "Reconnecting (\(attempt))…" : "Reconnecting…"
            case .ended:
                return "Ended"
            case .failed:
                return "Playback failed"
            }
        }

        var isBusy: Bool {
            switch self {
            case .connecting, .buffering, .reconnecting:
                return true
            default:
                return false
            }
        }
    }

    /// Skip intervals chosen in Settings.
    static var skipBackwardInterval: TimeInterval {
        PlayerPreferences.skipBackwardInterval
    }

    static var skipForwardInterval: TimeInterval {
        PlayerPreferences.skipForwardInterval
    }

    var isPresented: Bool = false
    /// The player screen was closed and Picture in Picture is taking the video over: the screen stays mounted
    /// (off screen, the video layer must stay in a window until PiP has started), see `closePlayer()`.
    private(set) var isClosingIntoPictureInPicture = false
    /// The view the full-screen player grows out of (iOS), see `playerTransitionSource(id:)`. nil: the mini
    /// player. Only read when the player is presented.
    @ObservationIgnored
    var presentationSourceID: String?
    /// Identifies the latest `closePlayer()` that asked for PiP, so an older timeout never ends a newer one.
    @ObservationIgnored
    private var closingAttempt = 0

    private(set) var currentChannel: PlayableChannel?
    /// The playlist entry being played, when it was started from a card, a row or by zapping (not for
    /// recordings). Channel up / down moves within its group.
    private(set) var currentItem: ChannelItem?
    private(set) var playbackState: PlaybackState = .idle
    /// Last error reported by the stream engine or AVPlayer for the current channel.
    private(set) var streamError: String?
    /// The current item is a live stream with a time-shift (DVR) window.
    private(set) var isTimeShiftAvailable = false
    private(set) var canSeek = false
    private(set) var canRecord = false
    private(set) var isRecording = false {
        didSet {
            // Channel up / down (the remote next / previous track commands) depends on it.
            if isRecording != oldValue {
                updateNowPlaying()
            }
        }
    }
    private(set) var recordingError: String?
    private(set) var isPictureInPictureActive = false
    /// Picture in Picture can start now (the item is ready and the video view is on screen).
    private(set) var isPictureInPicturePossible = false
    /// Aspect fill instead of aspect fit.
    private(set) var fillsScreen = false

    let player = AVPlayer()
    let timeline = PlaybackTimeline()
    let recordings: RecordingStore
    /// The platform player view, kept alive across player screen presentations for PiP.
    let surface: PlayerSurface

    /// Finds the previous / next channel of the current group. Set by the app once the store is open.
    @ObservationIgnored
    var zapper: ChannelZapper?

    private let server = SimpleHTTPServer()
    private let nowPlaying = NowPlayingController()
    private let remuxer = StreamRemuxer()
    private let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hls", isDirectory: true)

    @ObservationIgnored
    private var route: PlaybackRoute = .direct
    @ObservationIgnored
    private var streamURL: URL?
    @ObservationIgnored
    private var waitingForFirstSegment = false
    @ObservationIgnored
    private var attachTask: Task<Void, Never>?
    @ObservationIgnored
    private var itemCancellables = Set<AnyCancellable>()
    @ObservationIgnored
    private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored
    private var timeObserver: Any?
    @ObservationIgnored
    private var itemRecoveryAttempts = 0
    @ObservationIgnored
    private var didReachEnd = false
    @ObservationIgnored
    private var itemFailure: String?
    @ObservationIgnored
    private var pendingRestoreCompletion: ((Bool) -> Void)?
    @ObservationIgnored
    private var isPlayerUIVisible = false

    init(recordings: RecordingStore? = nil) {
        self.recordings = recordings ?? RecordingStore()
        self.surface = PlayerSurface(player: player)

        Self.removeLeftoverSegmentsOnce(in: outputDirectory)

        // Keep the audio going when the app is in the background without PiP.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible

        remuxer.onEvent = { [weak self] event in
            self?.handle(event)
        }
        configureSurface()
        configureRemoteCommands()
        observePlayer()
        observeAudioSession()
    }

    private static var didRemoveLeftoverSegments = false

    /// Deletes the segments left over by a previous run (e.g. after a crash). It runs once per
    /// process, before any session starts, and only in the primary instance, so it never touches
    /// the files of a running session.
    private static func removeLeftoverSegmentsOnce(in directory: URL) {
        guard !didRemoveLeftoverSegments else {
            return
        }
        didRemoveLeftoverSegments = true
        guard AppInstanceLock.isPrimaryInstance else {
            logger.info("Another instance is running: leftover segments are kept")
            return
        }
        StreamRemuxer.removeAllFiles(in: directory)
    }

    // MARK: - Channel selection

    /// Plays a playlist entry (it can then be zapped from) and presents the player.
    func play(_ item: ChannelItem, present: Bool = true) {
        currentItem = item
        playChannel(item.playable, present: present)
    }

    /// Plays a stream that is not a playlist entry (e.g. a recording or a debug URL).
    func play(_ channel: PlayableChannel, present: Bool = true) {
        currentItem = nil
        // Not started from a card: the player zooms from the mini player.
        presentationSourceID = nil
        playChannel(channel, present: present)
    }

    /// Plays `channel` and presents the player (unless Picture in Picture is running).
    /// Selecting the channel that is already playing only presents the player again.
    private func playChannel(_ channel: PlayableChannel, present: Bool) {
        defer {
            if present && !isPictureInPictureActive {
                isPresented = true
            }
        }
        if channel == currentChannel, isSessionHealthy {
            return
        }
        guard let url = channel.url else {
            currentChannel = channel
            streamError = "This channel has no valid stream URL."
            refreshPlaybackState()
            return
        }
        start(channel, url: url)
    }

    func playRecording(_ recording: Recording) {
        guard !recording.isFinalizing else {
            return
        }
        play(PlayableChannel(id: UUID(), name: recording.title, logo: nil, url: recording.url))
    }

    /// Restarts the current channel from scratch (e.g. after a failure).
    func retry() {
        guard let channel = currentChannel, let url = channel.url else {
            return
        }
        start(channel, url: url)
    }

    /// Opens the player screen for the current channel. While Picture in Picture runs, PiP is stopped instead
    /// and AVKit restores the screen (see `onRestoreUserInterface`), so the video animates back into it.
    func presentPlayer() {
        guard currentChannel != nil else {
            return
        }
        if isPictureInPictureActive {
            surface.stopPictureInPicture()
            // AVKit normally asks to restore the screen at once; present it anyway if it does not.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.currentChannel != nil, !self.isPictureInPictureActive, !self.isPresented else {
                    return
                }
                self.presentationSourceID = nil
                self.isPresented = true
            }
        } else {
            isPresented = true
        }
    }

    /// Closes the player screen; playback continues. On iOS the video moves into Picture in Picture when it can
    /// (Settings › Playback), otherwise it continues in the mini player.
    func closePlayer() {
        guard isPresented, !isClosingIntoPictureInPicture else {
            return
        }
        #if os(iOS)
        if PlayerPreferences.pictureInPictureOnClose, !isPictureInPictureActive, playbackState == .playing || playbackState == .buffering, surface.startPictureInPicture() {
            // `onPictureInPictureActiveChange` closes the screen once PiP runs; never wait longer than this.
            isClosingIntoPictureInPicture = true
            closingAttempt &+= 1
            let attempt = closingAttempt
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.closingAttempt == attempt else {
                    return
                }
                self.finishClosingIntoPictureInPicture()
            }
            return
        }
        #endif
        isPresented = false
    }

    private func finishClosingIntoPictureInPicture() {
        guard isClosingIntoPictureInPicture else {
            return
        }
        isClosingIntoPictureInPicture = false
        isPresented = false
    }

    /// Stops playback completely and closes the player.
    func stop() {
        isClosingIntoPictureInPicture = false
        completePendingRestore(false)
        surface.stopPictureInPicture()
        tearDownPlayback()
        currentChannel = nil
        currentItem = nil
        streamError = nil
        isPresented = false
        server.stop()
        deactivateAudioSession()
        refreshPlaybackState()
        nowPlaying.clear()
    }

    // MARK: - Channel zapping

    /// Channel up / down is offered for live channels of a playlist, and not while recording (switching
    /// channel would end the recording).
    var canZap: Bool {
        guard let currentItem, zapper != nil else {
            return false
        }
        return currentItem.kind == .live && !isRecording
    }

    /// Plays the next (`offset` > 0) or previous channel of the current group, wrapping around.
    func zap(by offset: Int) {
        guard canZap, let item = currentItem, let next = zapper?.neighbor(of: item, offset: offset) else {
            return
        }
        zapper?.recordWatch(next)
        play(next, present: false)
    }

    func nextChannel() {
        zap(by: 1)
    }

    func previousChannel() {
        zap(by: -1)
    }

    // MARK: - Picture in Picture and video

    var isPictureInPictureSupported: Bool {
        surface.isPictureInPictureSupported
    }

    func togglePictureInPicture() {
        surface.togglePictureInPicture()
    }

    func toggleFillsScreen() {
        fillsScreen.toggle()
        surface.fillsScreen = fillsScreen
    }

    // MARK: - Transport

    func togglePlayPause() {
        if player.timeControlStatus == .paused {
            play()
        } else {
            pause()
        }
    }

    func play() {
        if case .failed = playbackState {
            retry()
            return
        }
        guard let item = player.currentItem else {
            return
        }
        if didReachEnd {
            didReachEnd = false
            player.seek(to: .zero)
        } else if isTimeShiftAvailable, let range = seekableRange(of: item), item.currentTime().seconds < range.start + 1 {
            // Paused for longer than the time-shift window: continue from the oldest buffered media.
            seek(to: range.start + 2)
        }
        activateAudioSession()
        player.play()
    }

    func pause() {
        player.pause()
    }

    /// Moves the playback position by `seconds` (negative goes back), within the seekable range.
    func skip(by seconds: TimeInterval) {
        guard canSeek, let item = player.currentItem, let range = seekableRange(of: item) else {
            return
        }
        let upperBound = isTimeShiftAvailable ? range.end - liveOffset(of: item) : range.end
        let target = min(max(item.currentTime().seconds + seconds, range.start + 0.5), max(range.start + 0.5, upperBound))
        seek(to: target)
    }

    func skipBackward() {
        skip(by: -Self.skipBackwardInterval)
    }

    func skipForward() {
        skip(by: Self.skipForwardInterval)
    }

    /// Seeks to `seconds` on the item timeline (e.g. from the scrubber), within the seekable range.
    func seek(toSeconds seconds: TimeInterval) {
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

    /// Jumps back to the live edge of a time-shifted live stream.
    func goLive() {
        guard isTimeShiftAvailable, let item = player.currentItem, let range = seekableRange(of: item) else {
            return
        }
        seek(to: max(range.start, range.end - liveOffset(of: item)))
        player.play()
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard canRecord, !isRecording else {
            return
        }
        let url = recordings.makeRecordingURL(channelName: currentChannel?.name)
        do {
            try remuxer.startRecording(to: url)
            recordings.recordingDidStart(url, title: currentChannel?.name)
            recordingError = nil
            isRecording = true
            timeline.updateRecordingDuration(0)
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func stopRecording() {
        remuxer.stopRecording()
    }

    func clearRecordingError() {
        recordingError = nil
    }

    // MARK: - Lifecycle hooks

    /// Called by the player screen when its video view is on screen.
    func playerViewDidAppear() {
        logger.debug("Player screen appeared")
        isPlayerUIVisible = true
        // Give UIKit/AppKit one run loop to finish installing the view before PiP animates back.
        DispatchQueue.main.async { [weak self] in
            self?.completePendingRestore(true)
        }
    }

    func playerViewDidDisappear() {
        logger.debug("Player screen disappeared")
        isPlayerUIVisible = false
    }

    /// Called when the app becomes active again. iOS may have reclaimed the loopback server socket
    /// while the app was suspended; start it again if a remuxed stream needs it.
    func sceneDidBecomeActive() {
        guard route != .direct, remuxer.isProcessing else {
            return
        }
        server.start(root: outputDirectory)
    }

    // MARK: - Playback setup

    private var isSessionHealthy: Bool {
        switch playbackState {
        case .idle, .ended, .failed:
            return false
        default:
            return true
        }
    }

    private func start(_ channel: PlayableChannel, url: URL) {
        tearDownPlayback()

        currentChannel = channel
        streamError = nil
        recordingError = nil
        route = PlaybackRoute(url: url)
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
            if isLive {
                configuration.maxWindowDuration = PlayerPreferences.timeShiftDuration
                configuration.maxWindowBytes = Self.diskBudget(for: outputDirectory, maximum: PlayerPreferences.timeShiftBytes)
            } else {
                // On-demand inputs (local .ts files) are kept whole, so that every position stays
                // seekable. The engine reads them at disk speed, so a sliding byte window would delete
                // segments far ahead of the playhead. The remuxed copy is about the size of the input,
                // which is known: refuse to start when it would not fit instead.
                configuration.maxWindowDuration = 0
                configuration.maxWindowBytes = 0
                if let message = Self.insufficientSpaceMessage(forRemuxing: url, into: outputDirectory) {
                    streamError = message
                    refreshPlaybackState()
                    return
                }
            }

            guard let streamURL = SimpleHTTPServer.url(forFileNamed: configuration.playlistFileName) else {
                streamError = "Unable to create the local stream address."
                refreshPlaybackState()
                return
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

    /// Stops the engine and the player item of the current channel. A running recording is finalized.
    private func tearDownPlayback() {
        attachTask?.cancel()
        attachTask = nil
        waitingForFirstSegment = false
        streamURL = nil
        itemCancellables.removeAll()
        itemFailure = nil
        didReachEnd = false
        itemRecoveryAttempts = 0

        player.pause()
        player.replaceCurrentItem(with: nil)

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

    private func attachRemuxedStream() {
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

    private func attach(_ item: AVPlayerItem) {
        itemCancellables.removeAll()
        didReachEnd = false
        itemFailure = nil

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, item === self.player.currentItem else {
                    return
                }
                if status == .failed {
                    self.handleItemFailure(item.error)
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
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.handleItemFailure(error)
            }
            .store(in: &itemCancellables)

        player.replaceCurrentItem(with: item)
    }

    private func handleItemFailure(_ error: Error?) {
        let message = error?.localizedDescription ?? "Playback failed."
        if route != .direct, remuxer.isProcessing, itemRecoveryAttempts < 3 {
            // The engine still produces media: the player lost the local stream (e.g. the server
            // socket was reclaimed in the background). Restart the server and attach a fresh item.
            itemRecoveryAttempts += 1
            server.start(root: outputDirectory)
            attachRemuxedStream()
            return
        }
        logger.error("Player item failed: \(message, privacy: .public)")
        itemFailure = message
        streamError = message
        refreshPlaybackState()
    }

    // MARK: - Engine events

    private func handle(_ event: StreamRemuxer.Event) {
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
                attachRemuxedStream()
            }

        case .recordingStarted:
            isRecording = true

        case .recordingProgress(let progress):
            timeline.updateRecordingDuration(progress.duration)

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

    private func refreshPlaybackState() {
        let state = computePlaybackState()
        if state != playbackState {
            logger.info("Playback state: \(state.label, privacy: .public) (engine: \(String(describing: self.remuxer.state), privacy: .public))")
            playbackState = state
            updateNowPlaying()
        }
    }

    // MARK: - Now Playing

    private func configureRemoteCommands() {
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

    private func updateNowPlaying() {
        guard let channel = currentChannel else {
            nowPlaying.clear()
            return
        }
        nowPlaying.update(
            title: channel.name ?? "Fluxo",
            isLive: route.isLiveRemux || player.currentItem?.duration.isIndefinite == true,
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

    private func observePlayer() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else {
                    return
                }
                if status == .playing {
                    self.itemRecoveryAttempts = 0
                }
                self.refreshPlaybackState()
            }
            .store(in: &cancellables)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateTimeline()
            }
        }
    }

    private func updateTimeline() {
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

    private func seekableRange(of item: AVPlayerItem) -> (start: TimeInterval, end: TimeInterval)? {
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
    private func liveOffset(of item: AVPlayerItem) -> TimeInterval {
        let recommended = item.recommendedTimeOffsetFromLive
        return recommended.isNumeric && recommended.seconds > 0 ? recommended.seconds : 6
    }

    private func seek(to seconds: TimeInterval) {
        let tolerance = CMTime(value: 1, timescale: 4)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            guard finished else {
                return
            }
            // Now Playing only gets a new elapsed time on state changes, so push the new position
            // (otherwise the Lock Screen / Control Center scrubber drifts after a skip or a scrub).
            Task { @MainActor [weak self] in
                self?.updateTimeline()
                self?.updateNowPlaying()
            }
        }
    }

    // The time-shift (DVR) window of live streams and its disk budget come from PlayerPreferences.
    /// Free space kept in reserve when an on-demand file is remuxed whole.
    static let onDemandFreeSpaceMargin: Int64 = 256 * 1024 * 1024

    /// Media AVPlayer buffers ahead of the playhead (in memory). Remuxed streams are read from the local
    /// disk, so a few seconds are enough; remote items keep more to ride out network hiccups. Without a
    /// value AVFoundation picks the size itself, which for long on-demand items can be minutes of video.
    static let localForwardBufferDuration: TimeInterval = 8
    static let remoteForwardBufferDuration: TimeInterval = 30

    private static func makeItem(url: URL, isLocal: Bool) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = isLocal ? localForwardBufferDuration : remoteForwardBufferDuration
        return item
    }

    /// Disk budget of a remux session: at most `maximum` and never more than a tenth of the free space.
    private static func diskBudget(for directory: URL, maximum: Int64) -> Int64 {
        let minimum: Int64 = 64 * 1024 * 1024
        let probe = FileManager.default.fileExists(atPath: directory.path) ? directory : FileManager.default.temporaryDirectory
        guard let available = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
              available > 0 else {
            return maximum
        }
        return min(maximum, max(minimum, available / 10))
    }

    /// Returns an error message when the remuxed copy of a local on-demand file (about the size of the
    /// input) would not fit in the free space of `directory`, keeping `onDemandFreeSpaceMargin` free.
    private static func insufficientSpaceMessage(forRemuxing input: URL, into directory: URL) -> String? {
        guard input.isFileURL,
              let inputSize = try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        let probe = FileManager.default.fileExists(atPath: directory.path) ? directory : FileManager.default.temporaryDirectory
        guard let available = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
              available > 0 else {
            return nil
        }
        guard Int64(inputSize) + onDemandFreeSpaceMargin > available else {
            return nil
        }
        return "Not enough free space to play this recording."
    }

    // MARK: - Picture in Picture

    private func configureSurface() {
        surface.onPictureInPictureActiveChange = { [weak self] isActive in
            guard let self else {
                return
            }
            logger.info("Picture in Picture active: \(isActive, privacy: .public)")
            self.isPictureInPictureActive = isActive
            if isActive {
                // Let the user browse while the video plays in PiP. The surface (and with it the
                // controller that drives PiP) stays alive in this model.
                self.isClosingIntoPictureInPicture = false
                self.isPresented = false
            }
        }
        surface.onRestoreUserInterface = { [weak self] completion in
            guard let self else {
                completion(false)
                return
            }
            // `stop()` ends PiP from code and AVKit then asks to restore asynchronously, after
            // playback is already gone. Never reopen an empty player screen for that.
            guard self.currentChannel != nil else {
                completion(false)
                return
            }
            if self.isPresented && self.isPlayerUIVisible {
                completion(true)
                return
            }
            self.completePendingRestore(false)
            self.pendingRestoreCompletion = completion
            // Coming back from PiP: the mini player is the only source sure to be on screen.
            self.presentationSourceID = nil
            self.isPresented = true
            // Never leave PiP waiting if the player screen cannot appear.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.completePendingRestore(true)
            }
        }
        surface.onPictureInPictureError = { [weak self] error in
            guard let self else {
                return
            }
            if self.isClosingIntoPictureInPicture {
                // Closing the screen was asking for PiP: just close it, playback goes on in the mini player.
                logger.error("Picture in Picture did not start on close: \(error.localizedDescription, privacy: .public)")
                self.finishClosingIntoPictureInPicture()
            } else {
                self.streamError = error.localizedDescription
            }
        }
        surface.onPictureInPicturePossibleChange = { [weak self] isPossible in
            self?.updatePictureInPicturePossible(isPossible)
        }
    }

    private func updatePictureInPicturePossible(_ isPossible: Bool) {
        guard isPictureInPicturePossible != isPossible else {
            return
        }
        logger.info("Picture in Picture possible: \(isPossible, privacy: .public)")
        isPictureInPicturePossible = isPossible
    }

    private func completePendingRestore(_ restored: Bool) {
        let completion = pendingRestoreCompletion
        pendingRestoreCompletion = nil
        completion?(restored)
    }

    // MARK: - Audio session

    private func activateAudioSession() {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // Required for background audio and Picture in Picture.
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            logger.error("Unable to activate the playback audio session: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    private func deactivateAudioSession() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func observeAudioSession() {
        #if !os(macOS)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let info = notification.userInfo,
                      let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: rawType) == .ended,
                      let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) else {
                    return
                }
                self?.play()
            }
            .store(in: &cancellables)
        #endif
    }
}
