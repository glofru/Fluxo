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
@MainActor
final class PlaybackTimeline: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    /// Duration of on-demand items, 0 for live streams.
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var seekableStart: TimeInterval = 0
    @Published private(set) var seekableEnd: TimeInterval = 0
    /// How far playback is behind the live edge of a live stream.
    @Published private(set) var timeBehindLive: TimeInterval = 0
    @Published private(set) var isAtLiveEdge = true
    @Published private(set) var recordingDuration: TimeInterval = 0

    /// Length of the time-shift window (or of the seekable range of an on-demand item).
    var seekableDuration: TimeInterval {
        max(0, seekableEnd - seekableStart)
    }

    func update(currentTime: TimeInterval, duration: TimeInterval, seekableStart: TimeInterval, seekableEnd: TimeInterval, timeBehindLive: TimeInterval, isAtLiveEdge: Bool) {
        // Half a second of resolution is enough for the controls and avoids needless renders.
        assignIfChanged(\.currentTime, currentTime)
        assignIfChanged(\.duration, duration)
        assignIfChanged(\.seekableStart, seekableStart)
        assignIfChanged(\.seekableEnd, seekableEnd)
        assignIfChanged(\.timeBehindLive, timeBehindLive)
        if self.isAtLiveEdge != isAtLiveEdge {
            self.isAtLiveEdge = isAtLiveEdge
        }
    }

    func updateRecordingDuration(_ duration: TimeInterval) {
        assignIfChanged(\.recordingDuration, duration)
    }

    func reset() {
        update(currentTime: 0, duration: 0, seekableStart: 0, seekableEnd: 0, timeBehindLive: 0, isAtLiveEdge: true)
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
@MainActor
final class AVPlayerViewModel: ObservableObject {

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

    static let skipBackwardInterval: TimeInterval = 10
    static let skipForwardInterval: TimeInterval = 30

    @Published var isPresented: Bool = false

    @Published private(set) var currentChannel: PlayableChannel?
    @Published private(set) var playbackState: PlaybackState = .idle
    /// Last error reported by the stream engine or AVPlayer for the current channel.
    @Published private(set) var streamError: String?
    /// The current item is a live stream with a time-shift (DVR) window.
    @Published private(set) var isTimeShiftAvailable = false
    @Published private(set) var canSeek = false
    @Published private(set) var canRecord = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingError: String?
    @Published private(set) var isPictureInPictureActive = false

    let player = AVPlayer()
    let timeline = PlaybackTimeline()
    let recordings: RecordingStore
    /// The platform player view, kept alive across player screen presentations for PiP.
    let surface: PlayerSurface

    private let server = SimpleHTTPServer()
    private let remuxer = StreamRemuxer()
    private let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hls", isDirectory: true)

    private var route: PlaybackRoute = .direct
    private var streamURL: URL?
    private var waitingForFirstSegment = false
    private var attachTask: Task<Void, Never>?
    private var itemCancellables = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()
    private var timeObserver: Any?
    private var itemRecoveryAttempts = 0
    private var didReachEnd = false
    private var itemFailure: String?
    private var pendingRestoreCompletion: ((Bool) -> Void)?
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

    /// Plays `channel` and presents the player (unless Picture in Picture is running).
    /// Selecting the channel that is already playing only presents the player again.
    func play(_ channel: PlayableChannel, present: Bool = true) {
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

    /// Stops playback completely and closes the player.
    func stop() {
        tearDownPlayback()
        currentChannel = nil
        streamError = nil
        isPresented = false
        server.stop()
        deactivateAudioSession()
        refreshPlaybackState()
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
        isPlayerUIVisible = true
        // Give UIKit/AppKit one run loop to finish installing the view before PiP animates back.
        DispatchQueue.main.async { [weak self] in
            self?.completePendingRestore(true)
        }
    }

    func playerViewDidDisappear() {
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
        activateAudioSession()

        switch route {
        case .direct:
            attach(AVPlayerItem(url: url))
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
                configuration.maxWindowDuration = 30 * 60
                configuration.maxWindowBytes = Self.timeShiftDiskBudget(for: outputDirectory)
            } else {
                // On-demand inputs are kept whole so that every position stays seekable.
                configuration.maxWindowDuration = 0
                configuration.maxWindowBytes = 0
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
            let item = AVPlayerItem(url: streamURL)
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
        }
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
        let behind = isLive ? max(0, seekableEnd - current) : 0
        let atLiveEdge = !isLive || behind <= liveOffset(of: item) + 5

        timeline.update(
            currentTime: current,
            duration: duration,
            seekableStart: seekableStart,
            seekableEnd: seekableEnd,
            timeBehindLive: behind,
            isAtLiveEdge: atLiveEdge
        )
        let seekable = (range.map { $0.end - $0.start } ?? 0) > 2
        if seekable != canSeek {
            canSeek = seekable
        }
    }

    private func seekableRange(of item: AVPlayerItem) -> (start: TimeInterval, end: TimeInterval)? {
        guard let range = item.seekableTimeRanges.last?.timeRangeValue, range.start.isNumeric, range.duration.isNumeric else {
            return nil
        }
        let start = range.start.seconds
        return (start, start + range.duration.seconds)
    }

    /// Distance from the live edge AVPlayer recommends for smooth live playback.
    private func liveOffset(of item: AVPlayerItem) -> TimeInterval {
        let recommended = item.recommendedTimeOffsetFromLive
        return recommended.isNumeric && recommended.seconds > 0 ? recommended.seconds : 6
    }

    private func seek(to seconds: TimeInterval) {
        let tolerance = CMTime(value: 1, timescale: 4)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    /// Disk budget of the time-shift window: at most 512 MB and never more than a tenth of the free space.
    private static func timeShiftDiskBudget(for directory: URL) -> Int64 {
        let maximum: Int64 = 512 * 1024 * 1024
        let minimum: Int64 = 64 * 1024 * 1024
        let probe = FileManager.default.fileExists(atPath: directory.path) ? directory : FileManager.default.temporaryDirectory
        guard let available = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
              available > 0 else {
            return maximum
        }
        return min(maximum, max(minimum, available / 10))
    }

    // MARK: - Picture in Picture

    private func configureSurface() {
        surface.onPictureInPictureActiveChange = { [weak self] isActive in
            guard let self else {
                return
            }
            self.isPictureInPictureActive = isActive
            if isActive {
                // Let the user browse while the video plays in PiP. The surface (and with it the
                // controller that drives PiP) stays alive in this model.
                self.isPresented = false
            }
        }
        surface.onRestoreUserInterface = { [weak self] completion in
            guard let self else {
                completion(false)
                return
            }
            if self.isPresented && self.isPlayerUIVisible {
                completion(true)
                return
            }
            self.completePendingRestore(false)
            self.pendingRestoreCompletion = completion
            self.isPresented = true
            // Never leave PiP waiting if the player screen cannot appear.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.completePendingRestore(true)
            }
        }
        surface.onPictureInPictureError = { [weak self] error in
            self?.streamError = error.localizedDescription
        }
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
