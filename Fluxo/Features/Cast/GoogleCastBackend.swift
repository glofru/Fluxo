//
//  GoogleCastBackend.swift
//  Fluxo
//
//  `CastBackend` on the official Google Cast iOS Sender SDK (Swift Package `googlecast/google-cast-ios-sdk`,
//  product GoogleCastDynamic, linked on iOS only). The SDK does discovery (Bonjour `_googlecast._tcp`, see
//  NSBonjourServices in Info.plist), device authentication, the TLS session, the Cast terms of service prompt,
//  session resumption and the media channel. Fluxo only translates between it and `CastController`.
//
//  The SDK calls back on the main thread.
//

#if os(iOS) && canImport(GoogleCast)
@preconcurrency import GoogleCast
import OSLog

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Cast")

@MainActor
final class GoogleCastBackend: CastBackend {

    weak var delegate: CastBackendDelegate?

    private let context: GCKCastContext
    private let listener = Listener()
    /// Pending load requests: the SDK only keeps a weak reference to a request's delegate.
    private var loads: [Int: LoadObserver] = [:]
    private weak var observedClient: GCKRemoteMediaClient?
    /// The device picker is open: discovery uses active rather than passive scans.
    private var scansActively = false

    init() {
        if !GCKCastContext.isSharedInstanceInitialized() {
            let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
            let options = GCKCastOptions(discoveryCriteria: criteria)
            // Discovery starts when the user first opens the device picker (it triggers the Local Network
            // prompt), never at launch.
            options.disableDiscoveryAutostart = true
            options.startDiscoveryAfterFirstTapOnCastButton = false
            // The volume buttons change the TV's volume while casting (with Fluxo in the foreground). The session
            // is suspended in the background (the SDK default): local playback is stopped while casting, so iOS
            // would suspend the app anyway; the receiver keeps playing and the session resumes on return.
            options.physicalVolumeButtonsWillControlDeviceVolume = true
            // "Stop Casting" closes the receiver app instead of leaving its idle screen on the TV.
            options.stopReceiverApplicationWhenEndingSession = true
            options.disableAnalyticsLogging = true
            GCKCastContext.setSharedInstanceWith(options)
        }
        context = GCKCastContext.sharedInstance()
        listener.owner = self
        context.discoveryManager.add(listener)
        context.sessionManager.add(listener)
        // A session the SDK resumes at launch (the app was closed while casting) is reported through the listener.
    }

    // MARK: - CastBackend

    func startDiscovery() {
        context.discoveryManager.passiveScan = !scansActively
        context.discoveryManager.startDiscovery()
        publishDevices()
    }

    func setActiveScan(_ isActive: Bool) {
        scansActively = isActive
        context.discoveryManager.passiveScan = !isActive
    }

    func stopDiscovery() {
        context.discoveryManager.stopDiscovery()
    }

    func connect(to deviceID: String) {
        guard let device = context.discoveryManager.device(withUniqueID: deviceID) else {
            delegate?.castBackendDidFailToConnect(error: CastFailure(kind: .connection, message: String(localized: "The device is no longer available.")))
            return
        }
        if !context.sessionManager.startSession(with: device) {
            delegate?.castBackendDidFailToConnect(error: CastFailure(kind: .connection, message: String(localized: "Couldn't start casting to \(Self.name(of: device)).")))
        }
    }

    func disconnect() {
        _ = context.sessionManager.endSessionAndStopCasting(true)
    }

    func load(_ request: CastLoadRequest, completion: @escaping @MainActor (Result<Void, CastFailure>) -> Void) {
        guard let client = remoteMediaClient else {
            completion(.failure(CastFailure(kind: .connection, message: String(localized: "The Cast session isn't ready."))))
            return
        }
        let metadata = GCKMediaMetadata(metadataType: request.streamType == .live ? .generic : .movie)
        metadata.setString(request.title, forKey: kGCKMetadataKeyTitle)
        if let subtitle = request.subtitle, !subtitle.isEmpty {
            metadata.setString(subtitle, forKey: kGCKMetadataKeySubtitle)
        }
        if let imageURL = request.imageURL {
            metadata.addImage(GCKImage(url: imageURL, width: 480, height: 270))
        }

        let media = GCKMediaInformationBuilder(contentURL: request.url)
        media.contentID = request.url.absoluteString
        media.contentType = request.contentType
        media.streamType = request.streamType == .live ? .live : .buffered
        media.metadata = metadata
        // Subtitles on the TV in the caption style chosen on this device (Accessibility > Subtitles & Captioning).
        media.textTrackStyle = GCKMediaTextTrackStyle.createDefault()

        let load = GCKMediaLoadRequestDataBuilder()
        load.mediaInformation = media.build()
        load.autoplay = true
        if let startTime = request.startTime, startTime > 1 {
            load.startTime = startTime
        }

        let gckRequest = client.loadMedia(with: load.build())
        let id = gckRequest.requestID
        let observer = LoadObserver { [weak self] result in
            self?.loads[id] = nil
            completion(result)
        }
        loads[id] = observer
        gckRequest.delegate = observer
        logger.info("Loading \(request.contentType, privacy: .public) on the receiver")
    }

    func play() {
        remoteMediaClient?.play()
    }

    func pause() {
        remoteMediaClient?.pause()
    }

    func stop() {
        remoteMediaClient?.stop()
    }

    func seek(to position: TimeInterval) {
        let options = GCKMediaSeekOptions()
        options.interval = position
        options.resumeState = .unchanged
        remoteMediaClient?.seek(with: options)
    }

    func setVolume(_ volume: Double) {
        context.sessionManager.currentSession?.setDeviceVolume(Float(volume))
    }

    func setMuted(_ isMuted: Bool) {
        context.sessionManager.currentSession?.setDeviceMuted(isMuted)
    }

    func setActiveTracks(_ trackIDs: [Int]) {
        _ = remoteMediaClient?.setActiveTrackIDs(trackIDs.map { NSNumber(value: $0) })
    }

    func approximatePosition() -> TimeInterval? {
        guard let client = remoteMediaClient, client.mediaStatus != nil else {
            return nil
        }
        let position = client.approximateStreamPosition()
        return GCKIsValidTimeInterval(position) ? position : nil
    }

    // MARK: - Listener callbacks

    private var remoteMediaClient: GCKRemoteMediaClient? {
        context.sessionManager.currentSession?.remoteMediaClient
    }

    fileprivate func publishDevices() {
        let manager = context.discoveryManager
        let devices = (0..<manager.deviceCount).map { Self.device(manager.device(at: $0)) }
        delegate?.castBackend(didUpdateDevices: devices)
    }

    fileprivate func sessionWillStart(_ session: GCKSession) {
        delegate?.castBackendWillConnect(to: Self.device(session.device))
    }

    fileprivate func sessionDidStart(_ session: GCKSession, resumed: Bool) {
        logger.info("Cast session \(resumed ? "resumed" : "started", privacy: .public)")
        observe(session.remoteMediaClient)
        delegate?.castBackendDidConnect(to: Self.device(session.device), resumed: resumed)
        delegate?.castBackend(didUpdateVolume: Double(session.currentDeviceVolume), isMuted: session.currentDeviceMuted)
        publishMediaStatus()
    }

    fileprivate func sessionDidEnd(error: Error?) {
        logger.info("Cast session ended\(error.map { ": \($0.localizedDescription)" } ?? "", privacy: .public)")
        observe(nil)
        delegate?.castBackendDidDisconnect(error: error.map(Self.failure(for:)).flatMap { $0.kind == .cancelled ? nil : $0 })
        // After the player has handled the end of the session, so these failures are not reported as load errors.
        failPendingLoads()
    }

    fileprivate func sessionDidFailToStart(error: Error) {
        logger.error("Cast session failed to start: \(error.localizedDescription, privacy: .public)")
        observe(nil)
        delegate?.castBackendDidFailToConnect(error: Self.failure(for: error))
    }

    fileprivate func sessionDidSuspend() {
        delegate?.castBackendDidSuspend()
    }

    fileprivate func volumeDidChange(_ volume: Float, muted: Bool) {
        delegate?.castBackend(didUpdateVolume: Double(volume), isMuted: muted)
    }

    fileprivate func publishMediaStatus() {
        guard let client = remoteMediaClient, let status = client.mediaStatus else {
            delegate?.castBackend(didUpdateMediaStatus: nil)
            return
        }
        delegate?.castBackend(didUpdateMediaStatus: Self.status(status, client: client))
    }

    private func observe(_ client: GCKRemoteMediaClient?) {
        guard observedClient !== client else {
            return
        }
        observedClient?.remove(listener)
        observedClient = client
        client?.add(listener)
    }

    private func failPendingLoads() {
        let pending = loads.values
        loads.removeAll()
        for load in pending {
            load.finish(.failure(CastFailure(kind: .connection, message: String(localized: "The Cast session ended."))))
        }
    }

    // MARK: - Conversions

    private static func name(of device: GCKDevice) -> String {
        device.friendlyName ?? device.modelName ?? String(localized: "Cast device")
    }

    private static func device(_ device: GCKDevice) -> CastDevice {
        let kind: CastDevice.Kind
        switch device.type {
        case .TV:
            kind = .tv
        case .speaker:
            kind = .speaker
        case .speakerGroup:
            kind = .group
        default:
            kind = device.hasCapabilities(.videoOut) ? .tv : .generic
        }
        return CastDevice(id: device.uniqueID, name: name(of: device), model: device.modelName, kind: kind)
    }

    private static func status(_ status: GCKMediaStatus, client: GCKRemoteMediaClient) -> CastMediaStatus {
        let state: CastMediaStatus.PlayerState
        switch status.playerState {
        case .playing:
            state = .playing
        case .paused:
            state = .paused
        case .buffering:
            state = .buffering
        case .idle:
            state = .idle
        default:
            state = .loading
        }
        let reason: CastMediaStatus.IdleReason
        switch status.idleReason {
        case .finished:
            reason = .finished
        case .cancelled:
            reason = .cancelled
        case .interrupted:
            reason = .interrupted
        case .error:
            reason = .error
        default:
            reason = .none
        }
        let information = status.mediaInformation
        let isLive = information?.streamType == .live || client.isPlayingLiveStream
        let duration = information?.streamDuration ?? 0
        return CastMediaStatus(
            playerState: state,
            idleReason: reason,
            contentURL: information?.contentURL ?? information?.contentID.flatMap(URL.init(string:)),
            title: information?.metadata?.string(forKey: kGCKMetadataKeyTitle),
            isLive: isLive,
            duration: !isLive && GCKIsValidTimeInterval(duration) && duration.isFinite ? max(0, duration) : 0,
            position: status.streamPosition.isFinite ? max(0, status.streamPosition) : 0,
            positionDate: Date(),
            playbackRate: Double(status.playbackRate),
            canSeek: status.isMediaCommandSupported(kGCKMediaCommandSeek),
            canPause: status.isMediaCommandSupported(kGCKMediaCommandPause),
            tracks: (information?.mediaTracks ?? []).compactMap(track),
            activeTrackIDs: (status.activeTrackIDs ?? []).map(\.intValue)
        )
    }

    /// The audio and text tracks the receiver lists (video tracks are not a choice).
    private static func track(_ track: GCKMediaTrack) -> CastTrack? {
        switch track.type {
        case .audio:
            return CastTrack(id: track.identifier, kind: .audio, name: track.name, language: track.languageCode, isCaptions: false)
        case .text where track.textSubtype == .subtitles || track.textSubtype == .captions || track.textSubtype == .unknown:
            return CastTrack(id: track.identifier, kind: .text, name: track.name, language: track.languageCode, isCaptions: track.textSubtype == .captions)
        default:
            return nil
        }
    }

    nonisolated fileprivate static func failure(for error: Error) -> CastFailure {
        let nsError = error as NSError
        guard nsError.domain == kGCKErrorDomain, let code = GCKErrorCode(rawValue: nsError.code) else {
            return CastFailure(kind: .connection, message: error.localizedDescription)
        }
        switch code {
        case .cancelled, .replaced, .launchRequestCancelled:
            return .cancelled
        case .mediaLoadFailed, .mediaError, .invalidMediaPlayerState, .noMediaSession, .invalidRequest:
            return CastFailure(kind: .media, message: String(localized: "The stream couldn't be opened on the receiver."))
        case .networkError, .networkNotReachable, .timeout, .deviceNotConnected, .disconnected, .socketInvalidAddress:
            return CastFailure(kind: .connection, message: String(localized: "The device can't be reached. Check that it's on the same Wi-Fi network as this device."))
        case .deviceAuthenticationFailure, .deviceAuthorizationFailure, .deviceCertificateNotTrusted, .sslCertificateNotTrusted, .authenticationErrorReceived:
            return CastFailure(kind: .connection, message: String(localized: "The device couldn't be verified as a genuine Cast device."))
        case .applicationNotFound, .applicationNotRunning:
            return CastFailure(kind: .connection, message: String(localized: "The device can't start Google's media player."))
        case .maxUsersConnected:
            return CastFailure(kind: .connection, message: String(localized: "Too many devices are connected to it."))
        case .appDidEnterBackground:
            return .cancelled
        default:
            // The SDK's description is English developer text: it goes to the log, not to the user.
            logger.error("Cast error \(code.rawValue, privacy: .public): \(GCKError.enumDescription(for: code), privacy: .public)")
            return CastFailure(kind: .connection, message: String(localized: "Couldn't connect to the Cast device.", comment: "Cast: shown when connecting to or playing on a Chromecast fails for a reason that has no specific message."))
        }
    }
}

// MARK: - SDK delegates

/// Receives the SDK's listener calls (main thread) and forwards them to the backend.
private final class Listener: NSObject, GCKDiscoveryManagerListener, GCKSessionManagerListener, GCKRemoteMediaClientListener {
    weak var owner: GoogleCastBackend?

    private func onMain(_ body: @MainActor (GoogleCastBackend) -> Void) {
        MainActor.assumeIsolated {
            if let owner {
                body(owner)
            }
        }
    }

    // Discovery

    func didUpdateDeviceList() {
        onMain { $0.publishDevices() }
    }

    // Session

    func sessionManager(_ sessionManager: GCKSessionManager, willStart session: GCKSession) {
        onMain { $0.sessionWillStart(session) }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        onMain { $0.sessionDidStart(session, resumed: false) }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        onMain { $0.sessionDidStart(session, resumed: true) }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: (any Error)?) {
        onMain { $0.sessionDidEnd(error: error) }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: any Error) {
        onMain { $0.sessionDidFailToStart(error: error) }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didSuspend session: GCKSession, with reason: GCKConnectionSuspendReason) {
        onMain { $0.sessionDidSuspend() }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, session: GCKSession, didReceiveDeviceVolume volume: Float, muted: Bool) {
        onMain { $0.volumeDidChange(volume, muted: muted) }
    }

    // Media

    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        onMain { $0.publishMediaStatus() }
    }
}

/// Completes one load request.
private final class LoadObserver: NSObject, GCKRequestDelegate {
    private var completion: (@MainActor (Result<Void, CastFailure>) -> Void)?

    init(completion: @escaping @MainActor (Result<Void, CastFailure>) -> Void) {
        self.completion = completion
    }

    func finish(_ result: Result<Void, CastFailure>) {
        MainActor.assumeIsolated {
            let completion = self.completion
            self.completion = nil
            completion?(result)
        }
    }

    func requestDidComplete(_ request: GCKRequest) {
        finish(.success(()))
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        let failure = GoogleCastBackend.failure(for: error)
        // A load the receiver rejects is a media problem even when the SDK reports a generic code.
        finish(.failure(failure.kind == .connection ? CastFailure(kind: .media, message: failure.message) : failure))
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        finish(.failure(.cancelled))
    }
}
#endif
