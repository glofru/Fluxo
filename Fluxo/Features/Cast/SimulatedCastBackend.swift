//
//  SimulatedCastBackend.swift
//  Fluxo
//
//  Debug only: a pretend Default Media Receiver, so the cast UI can be seen and exercised in previews and in the
//  simulator without a Chromecast (Tools/Simulator: `-FluxoDebugCast simulated` or the `cast:<device>` route).
//  It has three devices, connects after a short delay, "plays" media on a clock, and behaves like the real
//  receiver with raw MPEG-TS: it refuses `video/mp2t` and accepts the HLS fallback. Nothing goes on the network.
//

#if DEBUG
import Foundation

enum DebugCastOptions {
    /// `-FluxoDebugCast simulated`: use the simulated receiver instead of the Google Cast SDK.
    static var usesSimulatedReceiver: Bool {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return (arguments["FluxoDebugCast"] as? String)?.lowercased() == "simulated"
    }
}

@MainActor
final class SimulatedCastBackend: CastBackend {

    weak var delegate: CastBackendDelegate?

    static let devices = [
        CastDevice(id: "sim-living-room", name: "Living Room TV", model: "Chromecast with Google TV", kind: .tv),
        CastDevice(id: "sim-bedroom", name: "Bedroom", model: "Chromecast", kind: .tv),
        CastDevice(id: "sim-kitchen", name: "Kitchen Speaker", model: "Nest Audio", kind: .speaker),
    ]

    /// Delays of the pretend network, shorter in previews.
    private let delay: Duration
    private var connected: CastDevice?
    private var status: CastMediaStatus?
    private var volume = 0.6
    private var isMuted = false

    init(delay: Duration = .milliseconds(700)) {
        self.delay = delay
    }

    func startDiscovery() {
        after(delay) { backend in
            backend.delegate?.castBackend(didUpdateDevices: Self.devices)
        }
    }

    func stopDiscovery() {
    }

    func setActiveScan(_ isActive: Bool) {
    }

    func connect(to deviceID: String) {
        guard let device = Self.devices.first(where: { $0.id == deviceID }) else {
            delegate?.castBackendDidFailToConnect(error: CastFailure(kind: .connection, message: "Unknown simulated device."))
            return
        }
        delegate?.castBackendWillConnect(to: device)
        after(delay * 1.5) { backend in
            backend.connected = device
            backend.delegate?.castBackendDidConnect(to: device, resumed: false)
            backend.delegate?.castBackend(didUpdateVolume: backend.volume, isMuted: backend.isMuted)
        }
    }

    func disconnect() {
        after(.milliseconds(250)) { backend in
            backend.connected = nil
            backend.status = nil
            backend.delegate?.castBackendDidDisconnect(error: nil)
        }
    }

    func load(_ request: CastLoadRequest, completion: @escaping @MainActor (Result<Void, CastFailure>) -> Void) {
        after(delay) { backend in
            guard backend.connected != nil else {
                completion(.failure(CastFailure(kind: .connection, message: "Not connected.")))
                return
            }
            // Like the real receiver: raw MPEG-TS never plays, and "HLS" only when the URL really is a playlist.
            let isPlaylist = ["m3u8", "m3u"].contains(request.url.pathExtension.lowercased())
            if request.contentType == CastMedia.transportStreamType || (request.contentType == CastMedia.hlsType && !isPlaylist) {
                completion(.failure(CastFailure(kind: .media, message: "The stream couldn't be opened on the receiver.")))
                return
            }
            let isLive = request.streamType == .live
            backend.publish(CastMediaStatus(
                playerState: .buffering,
                contentURL: request.url,
                title: request.title,
                isLive: isLive,
                duration: isLive ? 0 : 5_400,
                position: request.startTime ?? 0,
                canSeek: !isLive,
                tracks: Self.tracks(for: request.url),
                activeTrackIDs: Self.tracks(for: request.url).first.map { [$0.id] } ?? []
            ))
            completion(.success(()))
            backend.after(backend.delay) { backend in
                backend.update { $0.playerState = .playing }
            }
        }
    }

    func play() {
        update { $0.playerState = .playing }
    }

    func pause() {
        update { $0.playerState = .paused }
    }

    func stop() {
        update {
            $0.playerState = .idle
            $0.idleReason = .cancelled
        }
    }

    func seek(to position: TimeInterval) {
        update { $0.position = $0.duration > 0 ? min(position, $0.duration) : position }
    }

    func setVolume(_ volume: Double) {
        self.volume = volume
    }

    func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
    }

    func approximatePosition() -> TimeInterval? {
        status?.position(at: Date())
    }

    func setActiveTracks(_ trackIDs: [Int]) {
        update { $0.activeTrackIDs = trackIDs }
    }

    /// The renditions a receiver finds in the test stream with audio and subtitle tracks (Tools/Simulator's
    /// `/tracks/master.m3u8`); other media has none.
    private static func tracks(for url: URL) -> [CastTrack] {
        guard url.pathExtension.lowercased() == "m3u8", url.pathComponents.contains("tracks") else {
            return []
        }
        return [
            CastTrack(id: 1, kind: .audio, name: "English", language: "en", isCaptions: false),
            CastTrack(id: 2, kind: .audio, name: "Italiano", language: "it", isCaptions: false),
            CastTrack(id: 3, kind: .text, name: "English", language: "en", isCaptions: true),
            CastTrack(id: 4, kind: .text, name: "Italiano", language: "it", isCaptions: false),
        ]
    }

    // MARK: -

    /// Changes the status, carrying the extrapolated position forward.
    private func update(_ change: (inout CastMediaStatus) -> Void) {
        guard var status else {
            return
        }
        status.position = status.position(at: Date())
        status.positionDate = Date()
        change(&status)
        publish(status)
    }

    private func publish(_ status: CastMediaStatus) {
        var status = status
        status.positionDate = Date()
        self.status = status
        delegate?.castBackend(didUpdateMediaStatus: status)
    }

    private func after(_ delay: Duration, _ body: @escaping @MainActor (SimulatedCastBackend) -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else {
                return
            }
            body(self)
        }
    }
}
#endif
