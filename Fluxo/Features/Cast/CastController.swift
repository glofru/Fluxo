//
//  CastController.swift
//  Fluxo
//
//  Chromecast for the whole app: device discovery, the session and the receiver's media, for the views and the
//  player. The protocol work is done by a backend: the Google Cast SDK on iOS (`GoogleCastBackend`), a
//  simulated receiver in Debug builds (`SimulatedCastBackend`, for previews and the simulator harness), and
//  none on macOS, where Google ships no sender SDK: there `isSupported` is false and no cast UI shows.
//
//  The receiver is Google's Default Media Receiver (no app registration needed). Discovery starts only once the
//  user has opened the device picker, because the first discovery asks for Local Network access; from then on it
//  runs while the app is active, so the cast button can show only when a device is around.
//

import Foundation
import Observation

/// What a Cast backend reports, on the main actor.
@MainActor
protocol CastBackendDelegate: AnyObject {
    func castBackend(didUpdateDevices devices: [CastDevice])
    func castBackendWillConnect(to device: CastDevice)
    func castBackendDidConnect(to device: CastDevice, resumed: Bool)
    /// The session is suspended (the app went to the background); it is resumed with `castBackendDidConnect`.
    func castBackendDidSuspend()
    func castBackendDidDisconnect(error: CastFailure?)
    func castBackendDidFailToConnect(error: CastFailure)
    func castBackend(didUpdateMediaStatus status: CastMediaStatus?)
    func castBackend(didUpdateVolume volume: Double, isMuted: Bool)
}

/// The Cast protocol behind `CastController`.
@MainActor
protocol CastBackend: AnyObject {
    var delegate: CastBackendDelegate? { get set }
    func startDiscovery()
    func stopDiscovery()
    /// Active scanning finds devices faster but costs battery: Google recommends it only while the device
    /// picker is open, and the cheaper passive scan otherwise.
    func setActiveScan(_ isActive: Bool)
    func connect(to deviceID: String)
    /// Ends the session and stops the receiver app.
    func disconnect()
    func load(_ request: CastLoadRequest, completion: @escaping @MainActor (Result<Void, CastFailure>) -> Void)
    func play()
    func pause()
    func stop()
    func seek(to position: TimeInterval)
    func setVolume(_ volume: Double)
    func setMuted(_ isMuted: Bool)
    /// The receiver's position now, when media is loaded.
    func approximatePosition() -> TimeInterval?
}

@MainActor
@Observable
final class CastController {

    enum Connection: Equatable {
        case disconnected
        case connecting(CastDevice)
        case connected(CastDevice)
    }

    /// Session changes the player reacts to (see `AVPlayerViewModel`).
    enum Event {
        /// A session started, or resumed after the app was in the background / relaunched.
        case sessionStarted(resumed: Bool)
        /// The session ended. `switchingDevice`: another device is being connected right away.
        case sessionEnded(error: CastFailure?, switchingDevice: Bool)
        /// Connecting failed (the error is also in `connectionError`).
        case sessionFailedToStart(CastFailure)
        case mediaStatusChanged
    }

    /// A Cast backend exists on this platform (iOS with the Google Cast SDK, or the Debug simulation).
    var isSupported: Bool {
        backend != nil
    }

    private(set) var devices: [CastDevice] = []
    private(set) var connection: Connection = .disconnected
    /// The app is in the background with a session the SDK will resume.
    private(set) var isSuspended = false
    private(set) var mediaStatus: CastMediaStatus?
    /// Device volume, 0...1.
    private(set) var volume: Double = 1
    private(set) var isMuted = false
    private(set) var isDiscovering = false
    /// The last connection problem, shown in the device picker.
    private(set) var connectionError: String?
    /// The device picker sheet (iOS). Discovery scans actively while it is open.
    var isPickerPresented = false {
        didSet {
            if isPickerPresented != oldValue {
                backend?.setActiveScan(isPickerPresented)
            }
        }
    }

    /// The user opened the device picker at least once (and so was asked for Local Network access).
    private(set) var hasEnabledDiscovery: Bool {
        didSet {
            UserDefaults.fluxo.set(hasEnabledDiscovery, forKey: Self.discoveryEnabledKey)
        }
    }

    @ObservationIgnored
    var onEvent: ((Event) -> Void)?

    @ObservationIgnored
    private var backend: CastBackend?
    @ObservationIgnored
    private var pendingDeviceID: String?

    static let discoveryEnabledKey = "cast.discoveryEnabled"

    init(backend: CastBackend?) {
        self.backend = backend
        hasEnabledDiscovery = UserDefaults.fluxo.bool(forKey: Self.discoveryEnabledKey)
        backend?.delegate = self
        if backend != nil, hasEnabledDiscovery {
            startDiscovery()
        }
    }

    /// The controller of the app: the Google Cast SDK where it exists, otherwise unsupported.
    static func makeDefault() -> CastController {
        #if DEBUG
        if DebugCastOptions.usesSimulatedReceiver {
            return CastController(backend: SimulatedCastBackend())
        }
        #endif
        #if os(iOS) && canImport(GoogleCast)
        // Never in SwiftUI previews: the SDK would start networking in the preview process.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
            return CastController(backend: GoogleCastBackend())
        }
        #endif
        return CastController(backend: nil)
    }

    // MARK: - State

    var connectedDevice: CastDevice? {
        if case .connected(let device) = connection {
            return device
        }
        return nil
    }

    var connectingDevice: CastDevice? {
        if case .connecting(let device) = connection {
            return device
        }
        return nil
    }

    var isConnected: Bool {
        connectedDevice != nil
    }

    /// The cast button shows before the first use (it is how discovery gets enabled), and afterwards only while
    /// a device is around or a session exists, as Google's Cast design checklist asks.
    var showsCastButton: Bool {
        isSupported && (!hasEnabledDiscovery || !devices.isEmpty || connection != .disconnected)
    }

    /// The receiver's position now (extrapolated between status updates).
    func streamPosition() -> TimeInterval {
        if let position = backend?.approximatePosition(), position.isFinite, position >= 0 {
            return position
        }
        return mediaStatus?.position(at: Date()) ?? 0
    }

    // MARK: - Discovery

    /// Opens the device picker; the first time, this starts discovery (and the Local Network prompt).
    func presentPicker() {
        guard isSupported else {
            return
        }
        if !hasEnabledDiscovery {
            hasEnabledDiscovery = true
        }
        startDiscovery()
        isPickerPresented = true
    }

    func startDiscovery() {
        guard let backend, !isDiscovering else {
            return
        }
        isDiscovering = true
        backend.startDiscovery()
    }

    func stopDiscovery() {
        guard let backend, isDiscovering else {
            return
        }
        isDiscovering = false
        backend.stopDiscovery()
    }

    // MARK: - Session

    func connect(to device: CastDevice) {
        guard let backend else {
            return
        }
        connectionError = nil
        switch connection {
        case .connected(let current) where current.id == device.id:
            return
        case .connected, .connecting:
            // Switch devices: end this session first, then connect once it has ended.
            pendingDeviceID = device.id
            connection = .connecting(device)
            backend.disconnect()
        case .disconnected:
            connection = .connecting(device)
            backend.connect(to: device.id)
        }
    }

    /// Stops casting: the session ends and the receiver app closes.
    func disconnect() {
        pendingDeviceID = nil
        guard connection != .disconnected else {
            return
        }
        backend?.disconnect()
    }

    func clearConnectionError() {
        connectionError = nil
    }

    // MARK: - Media

    func load(_ request: CastLoadRequest, completion: @escaping @MainActor (Result<Void, CastFailure>) -> Void) {
        guard let backend, isConnected else {
            completion(.failure(CastFailure(kind: .connection, message: String(localized: "No Cast device is connected."))))
            return
        }
        backend.load(request, completion: completion)
    }

    func play() {
        backend?.play()
    }

    func pause() {
        backend?.pause()
    }

    /// Stops the media on the receiver; the session stays connected.
    func stopMedia() {
        backend?.stop()
    }

    func seek(to position: TimeInterval) {
        backend?.seek(to: max(0, position))
    }

    func setVolume(_ volume: Double) {
        let volume = min(1, max(0, volume))
        self.volume = volume
        backend?.setVolume(volume)
        if isMuted && volume > 0 {
            setMuted(false)
        }
    }

    func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
        backend?.setMuted(isMuted)
    }

    // MARK: - Debug

    #if DEBUG
    /// Switches to the simulated receiver (the simulator harness's `cast:` route), with discovery on.
    func debugUseSimulatedReceiver() {
        guard !(backend is SimulatedCastBackend) else {
            return
        }
        stopDiscovery()
        backend?.delegate = nil
        devices = []
        connection = .disconnected
        mediaStatus = nil
        let simulated = SimulatedCastBackend()
        backend = simulated
        simulated.delegate = self
        hasEnabledDiscovery = true
        startDiscovery()
    }
    #endif
}

extension CastController: CastBackendDelegate {
    func castBackend(didUpdateDevices devices: [CastDevice]) {
        self.devices = devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func castBackendWillConnect(to device: CastDevice) {
        if connectedDevice?.id != device.id {
            connection = .connecting(device)
        }
    }

    func castBackendDidConnect(to device: CastDevice, resumed: Bool) {
        let wasSuspended = isSuspended
        isSuspended = false
        connectionError = nil
        connection = .connected(device)
        onEvent?(.sessionStarted(resumed: resumed || wasSuspended))
    }

    func castBackendDidSuspend() {
        isSuspended = true
    }

    func castBackendDidDisconnect(error: CastFailure?) {
        isSuspended = false
        let next = pendingDeviceID
        pendingDeviceID = nil
        if let message = error?.message {
            connectionError = message
        }
        let nextDevice = next.flatMap { id in devices.first { $0.id == id } }
        // The player reads the last media status (the position to resume at) while handling the event.
        onEvent?(.sessionEnded(error: error, switchingDevice: nextDevice != nil))
        mediaStatus = nil
        if let nextDevice, let backend {
            connection = .connecting(nextDevice)
            backend.connect(to: nextDevice.id)
        } else {
            connection = .disconnected
        }
    }

    func castBackendDidFailToConnect(error: CastFailure) {
        isSuspended = false
        // Switching devices while the first connection was still being set up: ending that session may be
        // reported as a failure to start rather than as an end. Go on to the device the user picked.
        if let next = pendingDeviceID.flatMap({ id in devices.first { $0.id == id } }), let backend {
            pendingDeviceID = nil
            mediaStatus = nil
            onEvent?(.sessionEnded(error: nil, switchingDevice: true))
            connection = .connecting(next)
            backend.connect(to: next.id)
            return
        }
        pendingDeviceID = nil
        connection = .disconnected
        mediaStatus = nil
        connectionError = error.message
        onEvent?(.sessionFailedToStart(error))
    }

    func castBackend(didUpdateMediaStatus status: CastMediaStatus?) {
        mediaStatus = status
        onEvent?(.mediaStatusChanged)
    }

    func castBackend(didUpdateVolume volume: Double, isMuted: Bool) {
        self.volume = volume
        self.isMuted = isMuted
    }
}
