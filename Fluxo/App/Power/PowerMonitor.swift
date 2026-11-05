//
//  PowerMonitor.swift
//  Fluxo
//
//  What the app knows about the energy situation of the device, so that it can spend less while it plays:
//  - Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`) and the thermal state (`ProcessInfo.thermalState`): the
//    player limits the quality of adaptive streams (`PlaybackEnergyProfile`), status symbols stop animating, optional
//    work waits while the device is hot and runs less often in Low Power Mode;
//  - whether the app is in the background (iOS) or hidden / fully covered (macOS): nothing on screen needs to follow
//    the playback position;
//  - whether something plays (`isPlaybackActive`, set by the player): optional work (a TV guide refresh) waits until
//    playback ends, so it never competes with the video for the network, the CPU and the storage.
//
//  The system notifies every change, so the monitor costs nothing in between. It runs for the whole life of the app.
//

import Foundation
import Observation
import os
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class PowerMonitor {

    static let shared = PowerMonitor()

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Power")

    /// Low Power Mode is on (iOS, and macOS on battery when the user turned it on).
    private(set) var isLowPowerModeEnabled = false
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    /// The app is in the background (iOS), or hidden or completely covered by other windows (macOS).
    private(set) var isInBackground = false
    /// Something plays or is about to (connecting, buffering, playing, reconnecting), here or on a Chromecast.
    /// Set by the player.
    var isPlaybackActive = false {
        didSet {
            if isPlaybackActive != oldValue {
                notify()
            }
        }
    }

    /// The player screen is open (full screen on iPhone, or over the window that shows it): the screens behind it
    /// do not refresh what nobody sees (the Apple Intelligence suggestions). Set by the player.
    var isPlayerScreenOpen = false

    /// The device asks apps to save energy: Low Power Mode, or a thermal state at which the system itself starts
    /// to slow down (serious or critical).
    var isConstrained: Bool {
        isLowPowerModeEnabled || thermalState.isThrottling
    }

    /// Optional work (refreshing a stale TV guide) should wait: something plays, or the device is hot. (In Low Power
    /// Mode such work runs less often instead, see `EPGStore.staleInterval(lowPowerMode:)`: it could otherwise wait
    /// for days.) Work the user asks for is never deferred.
    var defersOptionalWork: Bool {
        isPlaybackActive || thermalState.isThrottling
    }

    @ObservationIgnored
    private var observers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored
    private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored
    private var isStarted = false

    #if DEBUG
    /// Debug harness (`-FluxoDebugPower`, the `power:` route): pretends Low Power Mode is on or off, or a thermal
    /// state; nil follows the system.
    @ObservationIgnored
    var debugLowPowerMode: Bool? {
        didSet {
            refresh()
        }
    }
    @ObservationIgnored
    var debugThermalState: ProcessInfo.ThermalState? {
        didSet {
            refresh()
        }
    }
    #endif

    private init() {}

    /// Starts following the system. Safe to call more than once.
    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        #if DEBUG
        // Launch arguments only (the argument domain), like the rest of the harness.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let value = arguments["FluxoDebugPower"].map({ "\($0)" }) {
            applyDebugPower(value)
        }
        #endif
        let center = NotificationCenter.default
        let refreshState: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        // Posted on an arbitrary thread.
        notificationTokens.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil, using: refreshState))
        notificationTokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil, using: refreshState))
        #if canImport(UIKit)
        notificationTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setInBackground(true)
            }
        })
        notificationTokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setInBackground(false)
            }
        })
        #elseif os(macOS)
        let visibility: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setInBackground(NSApplication.shared.isHidden || !NSApplication.shared.occlusionState.contains(.visible))
            }
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification, NSApplication.didChangeOcclusionStateNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main, using: visibility))
        }
        #endif
        refresh()
    }

    /// Calls `handler` on the main actor after every change of the properties above. Returns a token for
    /// `removeObserver(_:)`.
    @discardableResult
    func addObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func setInBackground(_ isInBackground: Bool) {
        guard self.isInBackground != isInBackground else {
            return
        }
        self.isInBackground = isInBackground
        notify()
    }

    private func refresh() {
        let info = ProcessInfo.processInfo
        var lowPower = info.isLowPowerModeEnabled
        var thermal = info.thermalState
        #if DEBUG
        lowPower = debugLowPowerMode ?? lowPower
        thermal = debugThermalState ?? thermal
        #endif
        guard lowPower != isLowPowerModeEnabled || thermal != thermalState else {
            return
        }
        isLowPowerModeEnabled = lowPower
        thermalState = thermal
        Self.logger.notice("Low Power Mode \(lowPower ? "on" : "off", privacy: .public), thermal state \(thermal.logName, privacy: .public)")
        notify()
    }

    private func notify() {
        for handler in observers.values {
            handler()
        }
    }

    #if DEBUG
    /// `low-power`, `normal`, `fair`, `serious`, `critical` or `system`.
    func applyDebugPower(_ value: String) {
        switch value.lowercased() {
        case "low-power", "lowpower", "on":
            debugLowPowerMode = true
            debugThermalState = nil
        case "normal", "nominal", "off":
            debugLowPowerMode = false
            debugThermalState = .nominal
        case "fair":
            debugLowPowerMode = false
            debugThermalState = .fair
        case "serious":
            debugLowPowerMode = false
            debugThermalState = .serious
        case "critical":
            debugLowPowerMode = false
            debugThermalState = .critical
        default:
            debugLowPowerMode = nil
            debugThermalState = nil
        }
    }
    #endif
}

extension ProcessInfo.ThermalState {
    /// The system slows the device down at these states; apps should do less.
    var isThrottling: Bool {
        self == .serious || self == .critical
    }

    var logName: String {
        switch self {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }
    }
}
