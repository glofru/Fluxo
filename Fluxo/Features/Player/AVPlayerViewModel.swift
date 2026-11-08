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
///
/// This file has its state, channel selection, zapping and the lifecycle hooks; the rest is in extensions by
/// concern: `AVPlayerViewModel+Transport` (play / pause, skips, seeks), `+Recording`, `+Playback` (starting and
/// tearing down playback, failures, the fallback to the engine), `+State` (engine events, the playback state, Now
/// Playing, the timeline), `+PictureInPicture`, `+Cast` and `+AudioSession`. The extensions set the state declared
/// here, so its setters are internal; views only read it and call the methods.
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

    var isPresented: Bool = false {
        didSet {
            if isPresented != oldValue {
                // The video is decoded again as the screen opens, so it shows during the transition.
                applyEnergyProfile()
                PowerMonitor.shared.isPlayerScreenOpen = isPresented
            }
        }
    }
    /// The player screen was closed and Picture in Picture is taking the video over: the screen stays mounted
    /// (off screen, the video layer must stay in a window until PiP has started), see `closePlayer()`.
    var isClosingIntoPictureInPicture = false
    /// The view the full-screen player grows out of (iOS), see `playerTransitionSource(id:)`. nil: the mini
    /// player. Only read when the player is presented.
    @ObservationIgnored
    var presentationSourceID: String?
    /// Identifies the latest `closePlayer()` that asked for PiP, so an older timeout never ends a newer one.
    @ObservationIgnored
    private var closingAttempt = 0

    var currentChannel: PlayableChannel?
    /// The playlist entry being played, when it was started from a card, a row or by zapping (not for
    /// recordings). Channel up / down moves within its group.
    var currentItem: ChannelItem? {
        didSet {
            if oldValue?.bookmarkKey != currentItem?.bookmarkKey {
                // Watched downloads are deleted once they no longer play ("Delete Watched Downloads").
                downloads?.playbackDidChange()
            }
        }
    }
    /// The current item plays from its offline download (a local file), not from the network.
    var isPlayingDownload = false

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
    var playbackState: PlaybackState = .idle
    /// Last error reported by the stream engine or AVPlayer for the current channel.
    var streamError: String?
    /// The error of the player item that failed (`playbackState` is `.failed` with its localized description), or the
    /// engine's (`EngineMessage.errorDomain`, FFmpeg's error code) while its failure is the error shown, so a screen can
    /// tell what happened by its domain and code: the description is in the device's language. Nil for anything else.
    var itemFailureError: NSError? {
        if itemFailure != nil {
            return itemFailureNSError
        }
        return engineFailure.flatMap { $0.message == streamError ? $0.error : nil }
    }
    /// The current item is a live stream with a time-shift (DVR) window.
    var isTimeShiftAvailable = false
    var canSeek = false
    var canRecord = false
    var isRecording = false {
        didSet {
            // Channel up / down (the remote next / previous track commands) depends on it.
            if isRecording != oldValue {
                updateNowPlaying()
            }
        }
    }
    var recordingError: String?
    /// The recording was asked to stop by `enforceRecordingLimits` (the engine reports the end a moment later).
    @ObservationIgnored var recordingLimitReached = false
    /// Recording time of the last free-space check.
    @ObservationIgnored var lastRecordingSpaceCheck: TimeInterval = 0
    var isPictureInPictureActive = false
    /// Picture in Picture can start now (the item is ready and the video view is on screen).
    var isPictureInPicturePossible = false
    /// Aspect fill instead of aspect fit.
    private(set) var fillsScreen = false

    /// Chromecast: discovery, the session and the receiver's media (iOS; unsupported on macOS).
    let cast: CastController
    /// A Chromecast plays the current channel and local playback is suspended (see "Chromecast" below).
    var isCasting = false {
        didSet {
            if isCasting != oldValue {
                // The Audio and Subtitles menu lists the receiver's tracks while casting.
                updateCastTracks()
            }
        }
    }
    /// Why the current channel could not be cast, or why casting stopped. Dismissed by the user.
    var castError: String?

    let player: AVPlayer
    let timeline = PlaybackTimeline()
    /// Every seek goes through it: coalescing, the target the controls show meanwhile, the loading state and
    /// recovery (see `PlayerSeeker`).
    let seeker: PlayerSeeker
    /// Frame previews over the scrubber while it is dragged (movies AVPlayer plays itself).
    let scrubPreview = ScrubPreviewProvider()
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

    #if DEBUG
    /// Debug harness: holds the scrubber at this position as a finger would (`scrub-hold:`); nil releases it there.
    var debugScrubHold: TimeInterval?
    /// Debug harness (`seek-past-buffer:direct`): seeks AVPlayer makes itself are handled as Picture in Picture's.
    @ObservationIgnored var debugTreatsJumpsAsPictureInPicture = false
    #endif

    /// Where a movie or episode continues (its saved watch progress), so that the engine produces that part
    /// first. Set by the app; `WatchProgressRecorder` still makes the resume seek.
    @ObservationIgnored
    var resumePosition: ((ChannelItem) -> TimeInterval?)?

    /// The current channel could not start because the device is offline: it starts when the network returns.
    var isWaitingForNetwork = false

    let server = SimpleHTTPServer()
    let nowPlaying = NowPlayingController()
    let remuxer = StreamRemuxer()
    let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hls", isDirectory: true)

    @ObservationIgnored
    var route: PlaybackRoute = .direct
    /// The playlist AVPlayer opens from the loopback server (its address is known once the server listens).
    @ObservationIgnored
    var streamFileName: String?
    @ObservationIgnored
    var waitingForFirstSegment = false
    @ObservationIgnored
    var attachTask: Task<Void, Never>?
    /// Watches the free space while a remote on-demand file is copied whole (its size is not always known).
    @ObservationIgnored
    var diskSpaceTask: Task<Void, Never>?
    @ObservationIgnored
    var itemCancellables = Set<AnyCancellable>()
    @ObservationIgnored
    var cancellables = Set<AnyCancellable>()
    @ObservationIgnored
    var timeObserver: Any?
    /// What playback spends on what is not on screen, and the stream quality the device can afford now (see
    /// `PlaybackEnergyProfile`). nil until the first `applyEnergyProfile()`.
    @ObservationIgnored
    var energyProfile: PlaybackEnergyProfile?
    @ObservationIgnored
    var itemRecoveryAttempts = 0
    @ObservationIgnored
    var didReachEnd = false
    @ObservationIgnored
    var itemFailure: String?
    /// The error behind `itemFailure` (AVFoundation's, for a stream AVPlayer plays itself).
    @ObservationIgnored
    var itemFailureNSError: NSError?
    /// The engine's failure of the current channel: its message (shown as `streamError`) and its error code.
    @ObservationIgnored
    var engineFailure: (message: String, error: NSError)?
    @ObservationIgnored
    var pendingRestoreCompletion: ((Bool) -> Void)?
    @ObservationIgnored
    var isPlayerUIVisible = false
    /// Local playback was stopped because a Chromecast took over (or is about to): `resumeLocalPlayback(at:)`
    /// starts it again.
    @ObservationIgnored
    var isLocalPlaybackSuspended = false
    /// A load request is on its way to the receiver.
    @ObservationIgnored
    var isCastLoading = false
    /// Identifies the latest cast load, so that the answer to an older one is ignored.
    @ObservationIgnored
    var castLoadGeneration = 0
    /// The stream the receiver accepted (the original URL or its HLS fallback).
    @ObservationIgnored
    var castMediaURL: URL?
    /// The last position the receiver reported in on-demand media, so "Try Again" continues from there (a
    /// failed receiver reports 0).
    @ObservationIgnored
    var castResumePosition: TimeInterval?
    /// Casting came from a session the SDK resumed (the app was relaunched while casting), not from local
    /// playback: when it ends there is nothing to resume on this device.
    @ObservationIgnored
    var isCastAdopted = false
    /// A session was resumed while nothing plays here: the receiver's media is adopted once its status arrives.
    @ObservationIgnored
    var adoptsResumedCastMedia = false
    /// Where to start on-demand media on the next device, while switching from one Chromecast to another.
    @ObservationIgnored
    var pendingCastStartTime: TimeInterval?
    /// Where to continue on-demand media on this device once its item is ready (after casting ends).
    @ObservationIgnored
    var pendingResumePosition: TimeInterval?
    /// The pending resume is the recovery of a seek that did not play (`recoverStuckSeek`): the seeker goes on
    /// with that recovery on the new item (one more stall fails) instead of starting it over.
    var pendingResumeContinuesRecovery = false
    /// How far the current item had buffered at the latest tick of the time observer (`itemTimeJumped(_:)`); nil
    /// until the first tick of an item.
    var sampledBufferedEnd: TimeInterval?
    @ObservationIgnored
    var castTimelineTask: Task<Void, Never>?
    /// The current movie or episode already fell back from AVPlayer to the engine (see `fallBackToEngine`).
    @ObservationIgnored
    var didFallBackToEngine = false
    /// Watches a direct on-demand item that keeps waiting for data (see `watchForStall()`).
    @ObservationIgnored
    var stallTask: Task<Void, Never>?
    /// A paused live channel through the engine: decides when the engine stops reading its input
    /// (`PausedTimeShiftPolicy`).
    @ObservationIgnored
    var pausedTimeShiftTask: Task<Void, Never>?
    /// The engine closed the input of the paused live channel (`StreamRemuxer.Event.inputSuspended`): the current item
    /// no longer follows the playlist (the engine marked it as ended meanwhile, see `PausedTimeShiftPolicy`), so playing
    /// on attaches a new item (`continueAfterSuspension`).
    @ObservationIgnored
    var suspension: Suspension?
    /// Playing on after a suspension: the new item is attached once the engine wrote a segment after the resume.
    @ObservationIgnored
    var suspensionResume: SuspensionResume?
    /// The engine was asked to close the input of the paused live channel: its `inputSuspended` event is taken even
    /// when the player plays again meanwhile (the playlist may have been marked as ended already).
    @ObservationIgnored
    var awaitsInputSuspension = false
    /// Where the new item after a suspension continues once it is ready (`resumeAfterSuspension(at:in:)`).
    @ObservationIgnored
    var pendingSuspensionResume: PendingSuspensionResume?
    @ObservationIgnored
    var suspensionResumeTask: Task<Void, Never>?
    /// The clock of the current item (`PausedTimeShiftPolicy.MediaClock`), read when it became ready.
    @ObservationIgnored
    var itemClock: (item: ObjectIdentifier, clock: PausedTimeShiftPolicy.MediaClock)?

    struct Suspension {
        /// The media sequence number of the last segment written before the input closed.
        var lastSegment: Int
        /// The old item (it stops following the playlist).
        var item: ObjectIdentifier
        /// The dates of the media of the playlist then (the one the old item stopped at), nil when it could not be read.
        var frozenDates: Range<Date>?
        /// The old item's clock (`PausedTimeShiftPolicy.MediaClock`), nil when it had no date.
        var clock: PausedTimeShiftPolicy.MediaClock?

        /// The old item's media, in its time: its seekable range while the playlist is marked as ended (AVPlayer's
        /// tells nothing then: on macOS it has no length and lies past the media).
        var itemRange: (start: TimeInterval, end: TimeInterval)? {
            guard let frozenDates, let clock else {
                return nil
            }
            return PausedTimeShiftPolicy.itemRange(of: frozenDates, clock: clock)
        }
    }

    struct PendingSuspensionResume {
        /// The date of the media to continue at (`PausedTimeShiftPolicy.MediaClock`).
        var date: Date
        /// The date of the first media written after the resume (Go Live), nil when unknown.
        var liveEdge: Date?
    }

    /// Where the new item after a suspension starts: where the old one was (the paused position, or where a seek
    /// meanwhile went), or with what the channel shows now (Go Live).
    enum SuspensionResume {
        case pausedPosition
        case liveEdge
    }

    init(recordings: RecordingStore? = nil, cast: CastController? = nil) {
        let player = AVPlayer()
        self.player = player
        self.seeker = PlayerSeeker(player: player)
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
        configureSeeker()
        observePlayer()
        observeAudioSession()
        self.cast.onEvent = { [weak self] event in
            self?.handleCast(event)
        }
        PowerMonitor.shared.addObserver { [weak self] in
            self?.applyEnergyProfile()
        }
        applyEnergyProfile()
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
        #if os(tvOS)
        if isPictureInPictureActive {
            // The system player's Picture in Picture (`TVSystemPlayer`): the app cannot stop it, and it stays active
            // while it runs, so the screen opens at once, as when its Full Screen asks for it
            // (`restoreFromSystemPictureInPicture()`). Not verified on a device: the Simulator has no PiP on tvOS.
            presentationSourceID = nil
            isPresented = true
            return
        }
        #endif
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

    func finishClosingIntoPictureInPicture() {
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

    // MARK: - Lifecycle hooks

    /// Called by the player screen when its video view is on screen.
    func playerViewDidAppear() {
        logger.debug("Player screen appeared")
        isPlayerUIVisible = true
        applyEnergyProfile()
        // Give UIKit/AppKit one run loop to finish installing the view before PiP animates back.
        DispatchQueue.main.async { [weak self] in
            self?.completePendingRestore(true)
        }
    }

    func playerViewDidDisappear() {
        logger.debug("Player screen disappeared")
        isPlayerUIVisible = false
        applyEnergyProfile()
    }

    #if os(tvOS)
    // MARK: - Apple TV's system player
    //
    // On Apple TV the player screen is `AVPlayerViewController` (`TVPlayerView`): its transport bar seeks AVPlayer
    // itself and it runs Picture in Picture itself. These hooks keep the app's model in step with it.

    /// The transport bar is about to seek to `seconds` (a skip with the clickpad, a scrub committed with a click).
    /// The seeker follows that seek (the engine is told where playback goes before AVPlayer asks for the segment
    /// there, and a seek that does not play is recovered like the app's own). Returns where to seek.
    func systemPlayerWillSeek(from oldSeconds: TimeInterval, to seconds: TimeInterval) -> TimeInterval {
        guard !isCasting, seconds.isFinite, player.currentItem != nil else {
            return seconds
        }
        logger.info("System player seeks from \(oldSeconds, format: .fixed(precision: 1)) s to \(seconds, format: .fixed(precision: 1)) s")
        if didReachEnd, seconds < oldSeconds {
            didReachEnd = false
            refreshPlaybackState()
        }
        if pendingResumePosition != nil || pendingSuspensionResume != nil || suspensionResumeTask != nil {
            // A new item is still starting (a stuck seek's recovery, the engine taking a movie over, a live channel
            // after a suspension): it starts where the viewer went now, not where the older seek went.
            pendingResumePosition = seconds
            pendingResumeContinuesRecovery = false
            pendingSuspensionResume = nil
            suspensionResumeTask?.cancel()
            suspensionResumeTask = nil
        }
        seeker.followSystemSeek(to: seconds)
        return seconds
    }

    /// The system player's Picture in Picture started or stopped. While it runs the player screen is closed (the
    /// video plays in the corner over the app) and playback goes on; `restoreFromSystemPictureInPicture()` opens it
    /// again.
    func systemPictureInPictureDidChange(_ isActive: Bool) {
        guard isPictureInPictureActive != isActive else {
            return
        }
        logger.info("Picture in Picture active (system player): \(isActive, privacy: .public)")
        isPictureInPictureActive = isActive
        applyEnergyProfile()
        if isActive {
            isPresented = false
        }
    }

    /// Picture in Picture asks for the full-screen player again ("Full Screen" in its menu).
    func restoreFromSystemPictureInPicture() -> Bool {
        guard currentChannel != nil else {
            return false
        }
        isPresented = true
        return true
    }

    /// The player screen closed (Menu on the Siri Remote, or Close): playback stops, as in the TV app, unless it goes
    /// on in Picture in Picture.
    func playerScreenDidClose() {
        guard !isPictureInPictureActive else {
            return
        }
        stop()
    }

    /// Where a live stream with a time-shift window is behind its live edge, in seconds (0 at the edge).
    var timeBehindLiveEdge: TimeInterval {
        isTimeShiftAvailable && !timeline.isAtLiveEdge ? timeline.timeBehindLive : 0
    }

    /// The time-shift window of a live stream reaches back to `date` (the start of the programme on air).
    func canWatchLive(from date: Date) -> Bool {
        guard !isCasting, isTimeShiftAvailable else {
            return false
        }
        let reach = timeline.seekableEnd - timeline.liveLatency - timeline.seekableStart
        return Date.now.timeIntervalSince(date) <= reach
    }

    /// Plays a time-shifted live stream from `date` (the start of the programme on air: Watch from the Start in the
    /// Guide tab of the info panel), when its window reaches back that far.
    func watchLive(from date: Date) {
        guard canWatchLive(from: date), let item = player.currentItem, let range = seekableRange(of: item) else {
            return
        }
        let liveEdge = range.end - liveOffset(of: item)
        seek(to: max(range.start, liveEdge - Date.now.timeIntervalSince(date)))
        player.play()
    }
    #endif

    /// Called when the app becomes active again. iOS may have reclaimed the loopback server socket
    /// while the app was suspended; start it again if a remuxed stream needs it.
    func sceneDidBecomeActive() {
        guard route != .direct, remuxer.isProcessing else {
            return
        }
        server.start(root: outputDirectory)
    }
}
