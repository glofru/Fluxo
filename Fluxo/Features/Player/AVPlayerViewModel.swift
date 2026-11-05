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
/// Picture), the remux engine (live MPEG-TS channels, and movies and episodes AVPlayer cannot open) and
/// the loopback HLS server.
///
/// FluxoApp creates the only instance, because the loopback port, the PiP surface and the segment
/// directory can only have one owner. macOS has a single main `Window`; iPad windows share this instance and
/// `WindowCoordinator` shows the player screen in one of them at a time.
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
                return String(localized: "Idle", comment: "Player status: nothing is loaded.")
            case .connecting:
                return String(localized: "Connecting…", comment: "Player status: opening the stream.")
            case .buffering:
                return String(localized: "Buffering…", comment: "Player status: waiting for media data.")
            case .playing:
                return String(localized: "Playing", comment: "Player status.")
            case .paused:
                return String(localized: "Paused", comment: "Player status.")
            case .reconnecting(let attempt):
                return attempt > 1
                    ? String(localized: "Reconnecting (\(attempt))…", comment: "Player status: the live stream dropped; the number is the reconnection attempt.")
                    : String(localized: "Reconnecting…", comment: "Player status: the live stream dropped and the app reconnects.")
            case .ended:
                return String(localized: "Ended", comment: "Player status: the stream or video finished.")
            case .failed:
                return String(localized: "Playback failed", comment: "Player status: the stream could not be played.")
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
    private(set) var currentItem: ChannelItem? {
        didSet {
            if oldValue?.bookmarkKey != currentItem?.bookmarkKey {
                // Watched downloads are deleted once they no longer play ("Delete Watched Downloads").
                downloads?.playbackDidChange()
            }
        }
    }
    /// The current item plays from its offline download (a local file), not from the network.
    private(set) var isPlayingDownload = false

    /// What plays is a live channel: the kind of the playlist entry, or for other URLs (recordings, a URL played
    /// on its own) what the URL looks like. An Xtream Codes movie without extension is not live, and neither is a
    /// download: whatever the link looks like, its file is on-demand media.
    var isCurrentChannelLiveContent: Bool {
        if isPlayingDownload {
            return false
        }
        if let kind = currentItem?.kind {
            return kind == .live
        }
        return currentChannel?.isLiveContent == true
    }
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

    /// Chromecast: discovery, the session and the receiver's media (iOS; unsupported on macOS).
    let cast: CastController
    /// A Chromecast plays the current channel and local playback is suspended (see "Chromecast" below).
    private(set) var isCasting = false {
        didSet {
            if isCasting != oldValue {
                // The Audio and Subtitles menu lists the receiver's tracks while casting.
                updateCastTracks()
            }
        }
    }
    /// Why the current channel could not be cast, or why casting stopped. Dismissed by the user.
    private(set) var castError: String?

    let player = AVPlayer()
    let timeline = PlaybackTimeline()
    /// Audio tracks and subtitles of the item that plays.
    let mediaSelection = MediaSelectionController()
    let recordings: RecordingStore
    /// The platform player view, kept alive across player screen presentations for PiP.
    let surface: PlayerSurface

    /// Finds the previous / next channel of the current group. Set by the app once the store is open.
    @ObservationIgnored
    var zapper: ChannelZapper?

    /// Offline downloads: a downloaded movie or episode plays from its local file. Set by the app.
    @ObservationIgnored
    var downloads: DownloadCenter?

    /// The current channel could not start because the device is offline: it starts when the network returns.
    private(set) var isWaitingForNetwork = false

    private let server = SimpleHTTPServer()
    private let nowPlaying = NowPlayingController()
    private let remuxer = StreamRemuxer()
    private let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hls", isDirectory: true)

    @ObservationIgnored
    private(set) var route: PlaybackRoute = .direct
    @ObservationIgnored
    private var streamURL: URL?
    @ObservationIgnored
    private var waitingForFirstSegment = false
    @ObservationIgnored
    private var attachTask: Task<Void, Never>?
    /// Watches the free space while a remote on-demand file is copied whole (its size is not always known).
    @ObservationIgnored
    private var diskSpaceTask: Task<Void, Never>?
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
    /// Local playback was stopped because a Chromecast took over (or is about to): `resumeLocalPlayback(at:)`
    /// starts it again.
    @ObservationIgnored
    private var isLocalPlaybackSuspended = false
    /// A load request is on its way to the receiver.
    @ObservationIgnored
    private var isCastLoading = false
    /// Identifies the latest cast load, so that the answer to an older one is ignored.
    @ObservationIgnored
    private var castLoadGeneration = 0
    /// The stream the receiver accepted (the original URL or its HLS fallback).
    @ObservationIgnored
    private var castMediaURL: URL?
    /// The last position the receiver reported in on-demand media, so "Try Again" continues from there (a
    /// failed receiver reports 0).
    @ObservationIgnored
    private var castResumePosition: TimeInterval?
    /// Casting came from a session the SDK resumed (the app was relaunched while casting), not from local
    /// playback: when it ends there is nothing to resume on this device.
    @ObservationIgnored
    private var isCastAdopted = false
    /// A session was resumed while nothing plays here: the receiver's media is adopted once its status arrives.
    @ObservationIgnored
    private var adoptsResumedCastMedia = false
    /// Where to start on-demand media on the next device, while switching from one Chromecast to another.
    @ObservationIgnored
    private var pendingCastStartTime: TimeInterval?
    /// Where to continue on-demand media on this device once its item is ready (after casting ends).
    @ObservationIgnored
    private var pendingResumePosition: TimeInterval?
    @ObservationIgnored
    private var castTimelineTask: Task<Void, Never>?
    /// The current movie or episode already fell back from AVPlayer to the engine (see `fallBackToEngine`).
    @ObservationIgnored
    private var didFallBackToEngine = false
    /// Watches a direct on-demand item that keeps waiting for data (see `watchForStall()`).
    @ObservationIgnored
    private var stallTask: Task<Void, Never>?

    init(recordings: RecordingStore? = nil, cast: CastController? = nil) {
        self.recordings = recordings ?? RecordingStore()
        self.surface = PlayerSurface(player: player)
        self.cast = cast ?? CastController(backend: nil)
        mediaSelection.player = player

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
        self.cast.onEvent = { [weak self] event in
            self?.handleCast(event)
        }
        NetworkMonitor.shared.addObserver { [weak self] online in
            guard let self, online, self.isWaitingForNetwork, self.currentChannel != nil else {
                return
            }
            // Back online: the channel that could not start offline starts now.
            self.retry()
        }
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
        if cast.isConnected {
            // A Chromecast is connected: the channel plays there (or here, if it cannot be cast).
            castChannel(channel)
            return
        }
        guard let url = playbackURL(for: channel) else {
            currentChannel = channel
            streamError = String(localized: "This channel has no valid stream URL.", comment: "Player error: the playlist entry has no usable address.")
            refreshPlaybackState()
            return
        }
        start(channel, url: url)
    }

    /// Where `channel` plays from: its offline download when the current item has one, else its stream.
    private func playbackURL(for channel: PlayableChannel) -> URL? {
        if let item = currentItem, item.id == channel.id, item.url == channel.url, let local = downloads?.localPlaybackURL(for: item) {
            return local
        }
        return channel.url
    }

    /// Stops playback when the current item plays from its download, which is about to be deleted.
    func stopIfPlayingDownload() {
        guard isPlayingDownload else {
            return
        }
        stop()
    }

    func playRecording(_ recording: Recording) {
        guard !recording.isFinalizing else {
            return
        }
        play(PlayableChannel(id: UUID(), name: recording.title, logo: nil, url: recording.url))
    }

    /// Restarts the current channel from scratch (e.g. after a failure).
    func retry() {
        if isCasting || (cast.isConnected && isLocalPlaybackSuspended) {
            castCurrentChannel(startTime: isCasting ? castResumePosition : nil)
            return
        }
        guard let channel = currentChannel, let url = playbackURL(for: channel) else {
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
        if PlayerPreferences.pictureInPictureOnClose, !isCasting, !isPictureInPictureActive, playbackState == .playing || playbackState == .buffering, surface.startPictureInPicture() {
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
        if isCasting {
            // The receiver stops too; the Cast session stays connected for the next channel.
            cast.stopMedia()
        }
        endCastingState()
        isLocalPlaybackSuspended = false
        adoptsResumedCastMedia = false
        pendingCastStartTime = nil
        castError = nil
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
        guard !isCasting else {
            return
        }
        surface.togglePictureInPicture()
    }

    func toggleFillsScreen() {
        fillsScreen.toggle()
        surface.fillsScreen = fillsScreen
    }

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
            player.seek(to: .zero)
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

    /// Jumps back to the live edge of a time-shifted live stream.
    func goLive() {
        guard !isCasting, isTimeShiftAvailable, let item = player.currentItem, let range = seekableRange(of: item) else {
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

    /// - Parameter forcedRoute: the route to use instead of the one the URL and the kind of the item call for
    ///   (the engine, after AVPlayer could not play a movie directly).
    private func start(_ channel: PlayableChannel, url: URL, route forcedRoute: PlaybackRoute? = nil) {
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
                // Movies and episodes: a complete VOD playlist whose segments the engine produces as AVPlayer
                // asks for them (seeking the input for a jump), reading at most `onDemandReadAhead` ahead of
                // the player. The segments farthest from the player are deleted beyond the disk budget.
                configuration.segmentDuration = Self.onDemandSegmentDuration
                configuration.readAheadDuration = Self.onDemandReadAhead
                configuration.maxWindowDuration = 0
                configuration.maxWindowBytes = Self.diskBudget(for: outputDirectory, maximum: PlayerPreferences.timeShiftBytes)
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
    private func tearDownPlayback() {
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
        didReachEnd = false
        itemRecoveryAttempts = 0
        pendingResumePosition = nil

        player.pause()
        player.replaceCurrentItem(with: nil)
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
                if status == .readyToPlay {
                    // HLS renditions are known once the playlist is read.
                    self.mediaSelection.reload()
                    self.checkTracksAreDecodable(item)
                }
                if status == .failed {
                    self.handleItemFailure(item.error)
                } else if status == .readyToPlay, let position = self.pendingResumePosition {
                    // Back from casting (continue where the Chromecast was), or the engine took a movie over.
                    self.pendingResumePosition = nil
                    self.resume(at: position, in: item)
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

    private func handleItemFailure(_ error: Error?) {
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
            }
            server.start(root: outputDirectory)
            attachRemuxedStream()
            return
        }
        logger.error("Player item failed: \(message, privacy: .public)")
        itemFailure = message
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
    @discardableResult
    private func fallBackToEngine(reason: String) -> Bool {
        guard canFallBackToEngine, let channel = currentChannel, let url = channel.url,
              let fallback = PlaybackRoute.onDemandFallback(for: url) else {
            return false
        }
        logger.info("Playing through the engine: \(reason, privacy: .public)")
        let position = player.currentItem.map { $0.currentTime().seconds } ?? 0
        didFallBackToEngine = true
        start(channel, url: url, route: fallback)
        if position.isFinite, position > 1 {
            pendingResumePosition = position
        }
        return true
    }

    /// An MP4 / MOV file whose video AVPlayer cannot decode (HEVC tagged `hev1`) plays its audio over a black picture,
    /// and one whose audio it cannot decode (DTS, which it does not even list) plays silently: the engine plays it
    /// instead, copying what AVPlayer decodes and converting the rest (`PlaybackRoute.engineReason`).
    private func checkTracksAreDecodable(_ item: AVPlayerItem) {
        guard canFallBackToEngine else {
            return
        }
        let asset = item.asset
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
    private func watchForStall() {
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

    private static func bufferedEnd(of item: AVPlayerItem) -> TimeInterval {
        item.loadedTimeRanges.map { $0.timeRangeValue }.map { $0.start.seconds + $0.duration.seconds }.filter(\.isFinite).max() ?? 0
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
                self.watchForStall()
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

    /// Seeks a new item to `position`. AVPlayer can drop a seek made while it starts an item (it then reports
    /// the seek as not finished and plays from the start), so the seek is made again until playback is there,
    /// up to `attempt` == 3.
    private func resume(at position: TimeInterval, in item: AVPlayerItem, attempt: Int = 1) {
        let tolerance = CMTime(value: 1, timescale: 4)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.player.currentItem === item else {
                    return
                }
                if abs(item.currentTime().seconds - position) > 5, attempt < 3 {
                    self.resume(at: position, in: item, attempt: attempt + 1)
                    return
                }
                self.updateTimeline()
                self.updateNowPlaying()
            }
        }
    }

    // The time-shift (DVR) window of live streams and its disk budget come from PlayerPreferences.

    /// Segments of on-demand playlists made by the engine. Short, so that a seek plays after one segment
    /// is read (at most a few MB), and a multiple of the usual 1–2 s GOP of IPTV movies.
    static let onDemandSegmentDuration: TimeInterval = 4
    /// Media the engine reads ahead of the player in an on-demand playlist, then pauses (the network radio
    /// rests until the player has used half of it).
    static let onDemandReadAhead: TimeInterval = 60
    /// How long a movie played directly may wait for data (its buffer not growing) before the engine takes over.
    static let stallTimeout: Duration = .seconds(12)
    /// Free space kept in reserve while the segments of an on-demand input accumulate.
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
                if let available = Self.availableSpace(in: directory), available < Self.onDemandFreeSpaceMargin {
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

    private nonisolated static func availableSpace(in directory: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: directory.path) ? directory : FileManager.default.temporaryDirectory
        guard let available = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
              available > 0 else {
            return nil
        }
        return available
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

    // MARK: - Chromecast
    //
    // While a Cast session is connected, a channel that is played goes to the receiver (Google's Default Media
    // Receiver) as its original stream URL, see `CastMedia`. Local playback stops while the Chromecast plays (the
    // engine and the player item are torn down, so the IPTV provider sees one connection, the receiver's; a
    // running recording is finished and saved), and the transport (play / pause, skip, scrubbing, channel up /
    // down, stop) drives the receiver. When casting ends (Stop Casting, the session drops), the channel plays here
    // again, on-demand media from the receiver's position. A channel the receiver cannot play keeps playing here,
    // with `castError` explaining why.

    func clearCastError() {
        castError = nil
    }

    /// Stops casting and plays the channel on this device again.
    func stopCasting() {
        cast.disconnect()
    }

    private func handleCast(_ event: CastController.Event) {
        switch event {
        case .sessionStarted(let resumed):
            if isCasting {
                // Back from the background: the receiver kept playing.
                startCastTimeline()
                refreshPlaybackState()
            } else if currentChannel != nil {
                guard !resumed || isLocalPlaybackSuspended else {
                    return
                }
                let startTime = pendingCastStartTime ?? localOnDemandPosition
                pendingCastStartTime = nil
                castCurrentChannel(startTime: startTime)
            } else if resumed {
                adoptsResumedCastMedia = true
                adoptCastMedia()
            }

        case .sessionEnded(let error, let switchingDevice):
            adoptsResumedCastMedia = false
            guard isCasting else {
                // Nothing was cast (e.g. the channel could not be): a message about it is over with the session.
                if error == nil {
                    castError = nil
                }
                return
            }
            if let message = error?.message {
                castError = String(localized: "Casting stopped. \(message)", comment: "Cast error; the placeholder is the reason given by the Cast device.")
            }
            if isCastAdopted {
                endCastingState()
                stop()
                return
            }
            let position = castOnDemandPosition
            if switchingDevice {
                // The next device gets the channel as soon as its session starts.
                endCastingState()
                pendingCastStartTime = position
                refreshPlaybackState()
            } else {
                resumeLocalPlayback(at: position)
            }

        case .sessionFailedToStart:
            adoptsResumedCastMedia = false
            if isCasting || isLocalPlaybackSuspended {
                let position = pendingCastStartTime
                pendingCastStartTime = nil
                resumeLocalPlayback(at: position)
            }

        case .mediaStatusChanged:
            if isCasting, castMediaWasReplaced {
                // Another sender loaded something else on the receiver: show (and control) that instead.
                logger.info("Another sender replaced the cast media")
                endCastingState()
                stop()
                adoptsResumedCastMedia = true
                adoptCastMedia()
            } else if isCasting {
                updateCastTimeline()
                updateCastTracks()
                refreshPlaybackState()
            } else if adoptsResumedCastMedia {
                adoptCastMedia()
            }
        }
    }

    /// The receiver's audio and text tracks in the Audio and Subtitles menu while casting, the local ones otherwise.
    private func updateCastTracks() {
        guard isCasting else {
            mediaSelection.hideCastTracks()
            return
        }
        mediaSelection.showCastTracks(cast.mediaStatus) { [weak self] trackIDs in
            self?.cast.setActiveTracks(trackIDs)
        }
    }

    /// Makes `channel` the current one and sends it to the receiver.
    private func castChannel(_ channel: PlayableChannel) {
        if channel != currentChannel {
            if !isLocalPlaybackSuspended {
                // The previous channel was playing here (it could not be cast): it stops either way.
                surface.stopPictureInPicture()
                tearDownPlayback()
                isLocalPlaybackSuspended = true
            }
            currentChannel = channel
            streamError = nil
            castResumePosition = nil
        }
        castCurrentChannel(startTime: nil)
    }

    /// Sends the current channel to the connected receiver, trying the fallbacks of `CastMedia` in turn.
    private func castCurrentChannel(startTime: TimeInterval?) {
        guard let channel = currentChannel, let device = cast.connectedDevice else {
            return
        }
        let isLive = currentItem.map { $0.kind == .live } ?? (channel.url.map { PlaybackRoute(url: $0).isLiveRemux } ?? true)
        switch CastMedia.requests(for: channel.url, title: channel.name, subtitle: currentItem?.groupName, logo: channel.logo, isLive: isLive, startTime: startTime) {
        case .failure(let reason):
            logger.info("Not casting: \(reason.message, privacy: .public)")
            castError = reason.message
            resumeLocalPlayback(at: startTime)
        case .success(let requests):
            castError = nil
            if !isLocalPlaybackSuspended {
                surface.stopPictureInPicture()
                tearDownPlayback()
                isLocalPlaybackSuspended = true
            }
            isCasting = true
            isCastAdopted = false
            isCastLoading = true
            castMediaURL = nil
            castLoadGeneration &+= 1
            timeline.reset()
            canSeek = false
            loadOnCast(requests[...], deviceName: device.name, originalURL: channel.url, generation: castLoadGeneration, lastFailure: nil)
            startCastTimeline()
            refreshPlaybackState()
        }
    }

    private func loadOnCast(_ requests: ArraySlice<CastLoadRequest>, deviceName: String, originalURL: URL?, generation: Int, lastFailure: CastFailure?) {
        guard let request = requests.first else {
            // Every stream failed: play the channel here again, and say why.
            let failure = lastFailure ?? CastFailure(kind: .media, message: nil)
            castError = CastMedia.failureMessage(for: originalURL, deviceName: deviceName, failure: failure)
            resumeLocalPlayback(at: nil)
            return
        }
        cast.load(request) { [weak self] result in
            guard let self, generation == self.castLoadGeneration, self.isCasting else {
                return
            }
            switch result {
            case .success:
                logger.info("Casting \(request.contentType, privacy: .public) to the receiver")
                self.isCastLoading = false
                self.castMediaURL = request.url
                self.updateCastTimeline()
                self.refreshPlaybackState()
            case .failure(let failure) where failure.kind == .cancelled:
                // Declined (e.g. the Cast terms) or replaced: never retried automatically.
                self.resumeLocalPlayback(at: request.startTime)
            case .failure(let failure) where failure.kind == .media && requests.count > 1:
                logger.info("The receiver refused \(request.contentType, privacy: .public); trying the next stream")
                self.loadOnCast(requests.dropFirst(), deviceName: deviceName, originalURL: originalURL, generation: generation, lastFailure: failure)
            case .failure(let failure):
                self.loadOnCast([], deviceName: deviceName, originalURL: originalURL, generation: generation, lastFailure: failure)
            }
        }
    }

    /// Plays the current channel on this device again, from `position` for on-demand media.
    private func resumeLocalPlayback(at position: TimeInterval?) {
        endCastingState()
        defer {
            refreshPlaybackState()
        }
        guard isLocalPlaybackSuspended, let channel = currentChannel else {
            // Still playing here (the channel could not be cast at all).
            return
        }
        guard let url = channel.url else {
            isLocalPlaybackSuspended = false
            streamError = String(localized: "This channel has no valid stream URL.", comment: "Player error: the playlist entry has no usable address.")
            return
        }
        start(channel, url: url)
        pendingResumePosition = position.flatMap { $0 > 1 ? $0 : nil }
    }

    /// Clears the casting state (the session itself is left as it is).
    private func endCastingState() {
        castLoadGeneration &+= 1
        castTimelineTask?.cancel()
        castTimelineTask = nil
        isCastLoading = false
        castMediaURL = nil
        castResumePosition = nil
        isCastAdopted = false
        guard isCasting else {
            return
        }
        isCasting = false
        canSeek = false
        timeline.reset()
    }

    /// A session the SDK resumed while nothing plays here (the app was relaunched while casting): show what the
    /// receiver plays, so the mini player and the player can control it.
    private func adoptCastMedia() {
        guard currentChannel == nil, cast.isConnected, let status = cast.mediaStatus, let url = status.contentURL,
              status.playerState != .idle else {
            return
        }
        adoptsResumedCastMedia = false
        currentItem = nil
        currentChannel = PlayableChannel(id: UUID(), name: status.title, logo: nil, url: url)
        isLocalPlaybackSuspended = true
        isCasting = true
        isCastAdopted = true
        castMediaURL = url
        startCastTimeline()
        updateCastTimeline()
        refreshPlaybackState()
    }

    /// The position of on-demand media playing here, to start the receiver at.
    private var localOnDemandPosition: TimeInterval? {
        guard !isCasting, !isLocalPlaybackSuspended, canSeek, !isTimeShiftAvailable, timeline.duration > 0 else {
            return nil
        }
        return timeline.currentTime
    }

    /// The receiver's position in on-demand media, to continue at on this device.
    private var castOnDemandPosition: TimeInterval? {
        guard let status = cast.mediaStatus, !status.isLive, status.duration > 0 else {
            return nil
        }
        return cast.streamPosition()
    }

    /// The receiver plays other media than the one sent to it: another sender (a phone, Google Home) loaded
    /// something in the same Default Media Receiver session. Only a status that is playing or paused counts, as
    /// the receiver may still report the previous media for a moment while it loads the new one.
    private var castMediaWasReplaced: Bool {
        guard !isCastLoading, let sent = castMediaURL, let status = cast.mediaStatus, let url = status.contentURL else {
            return false
        }
        return !CastMedia.isSameMedia(url, sent) && (status.playerState == .playing || status.playerState == .paused)
    }

    private func seekOnCast(to seconds: TimeInterval) {
        guard canSeek else {
            return
        }
        cast.seek(to: min(max(0, seconds), max(0, timeline.duration - 1)))
    }

    private var castPlaybackState: PlaybackState {
        if isCastLoading {
            return .connecting
        }
        // A status of the previous media (the receiver reports it until the new one starts).
        guard let status = cast.mediaStatus, status.contentURL == nil || castMediaURL == nil || CastMedia.isSameMedia(status.contentURL, castMediaURL) else {
            return .buffering
        }
        switch status.playerState {
        case .playing:
            return .playing
        case .paused:
            return .paused
        case .buffering, .loading:
            return .buffering
        case .idle:
            if status.idleReason == .error {
                let device = cast.connectedDevice?.name ?? String(localized: "The Cast device", comment: "Stands in for the Chromecast name in an error when the name is unknown.")
                return .failed(String(localized: "\(device) stopped playing this stream.", comment: "Cast error; the placeholder is the Chromecast name."))
            }
            return .ended
        }
    }

    private func startCastTimeline() {
        castTimelineTask?.cancel()
        castTimelineTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateCastTimeline()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func updateCastTimeline() {
        guard isCasting, !isCastLoading, let status = cast.mediaStatus else {
            return
        }
        let duration = status.isLive ? 0 : status.duration
        timeline.update(
            currentTime: cast.streamPosition(),
            duration: duration,
            seekableStart: 0,
            seekableEnd: duration,
            timeBehindLive: 0,
            liveLatency: 0,
            isAtLiveEdge: true
        )
        if !status.isLive, duration > 0, status.contentURL == nil || CastMedia.isSameMedia(status.contentURL, castMediaURL),
           status.playerState == .playing || status.playerState == .paused {
            castResumePosition = cast.streamPosition()
        }
        let seekable = !status.isLive && duration > 2 && status.canSeek
        if seekable != canSeek {
            canSeek = seekable
            updateNowPlaying()
        }
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
