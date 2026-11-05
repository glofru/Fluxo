//
//  NetworkMonitor.swift
//  Fluxo
//
//  Whether the device has a network path at all (`NWPathMonitor`), so the app can say "You're offline" at once
//  instead of spinning until a stream or a guide download times out, and whether that path is cellular (Wi-Fi only
//  downloads wait for Wi-Fi).
//
//  "Online" means the system has a usable path (`.satisfied`), not that the internet answers: a Wi-Fi network
//  without internet still reaches IPTV servers of the local network. With no path at all, only the loopback
//  interface works, so the player still opens loopback URLs (the debug test streams) offline.
//
//  The monitor costs nothing between path changes (the system calls it back), so it runs for the whole life of the
//  app.
//

import Foundation
import Network
import Observation
import os

@MainActor
@Observable
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Network")

    /// The system has a network path (Wi-Fi, cellular, Ethernet). True until the first update says otherwise.
    private(set) var isOnline = true
    /// The path goes over a cellular interface only (no Wi-Fi or Ethernet).
    private(set) var isCellularOnly = false
    /// The path is expensive (cellular, or a personal hotspot) or constrained (Low Data Mode).
    private(set) var isExpensive = false

    var isOffline: Bool {
        !isOnline
    }

    /// Called on the main actor after every change of `isOnline` (the player retries a stream that failed
    /// offline, the downloads and the guide resume).
    @ObservationIgnored
    private var observers: [UUID: @MainActor (Bool) -> Void] = [:]
    @ObservationIgnored
    private let monitor = NWPathMonitor()
    @ObservationIgnored
    private var isStarted = false

    #if DEBUG
    /// Debug harness (`-FluxoDebugOffline YES`, the `offline:` route): pretends the device is offline (true),
    /// online (false), or follows the system (nil).
    var debugOverride: Bool? {
        didSet {
            apply(online: debugOverride.map { !$0 } ?? systemIsOnline, cellularOnly: systemIsCellularOnly, expensive: systemIsExpensive)
        }
    }
    @ObservationIgnored private var systemIsOnline = true
    @ObservationIgnored private var systemIsCellularOnly = false
    @ObservationIgnored private var systemIsExpensive = false
    #endif

    private init() {}

    /// Starts following the network. Safe to call more than once.
    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        #if DEBUG
        // Launch arguments only (the argument domain), like the rest of the harness.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let value = arguments["FluxoDebugOffline"].map({ "\($0)".lowercased() }), ["yes", "true", "1"].contains(value) {
            debugOverride = true
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let cellularOnly = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in
                self?.update(online: online, cellularOnly: cellularOnly, expensive: expensive)
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.watermelon.Fluxo.network", qos: .utility))
    }

    /// Calls `handler` with the new state after every change between online and offline. Returns a token for
    /// `removeObserver(_:)`.
    @discardableResult
    func addObserver(_ handler: @escaping @MainActor (Bool) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    /// True when `url` can be reached without a network path: a file, or the loopback interface.
    nonisolated static func isReachableOffline(_ url: URL) -> Bool {
        if url.isFileURL {
            return true
        }
        guard let host = url.host()?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private func update(online: Bool, cellularOnly: Bool, expensive: Bool) {
        #if DEBUG
        systemIsOnline = online
        systemIsCellularOnly = cellularOnly
        systemIsExpensive = expensive
        if let debugOverride {
            apply(online: !debugOverride, cellularOnly: cellularOnly, expensive: expensive)
            return
        }
        #endif
        apply(online: online, cellularOnly: cellularOnly, expensive: expensive)
    }

    private func apply(online: Bool, cellularOnly: Bool, expensive: Bool) {
        if isCellularOnly != cellularOnly {
            isCellularOnly = cellularOnly
        }
        if isExpensive != expensive {
            isExpensive = expensive
        }
        guard isOnline != online else {
            return
        }
        isOnline = online
        Self.logger.notice("Network \(online ? "online" : "offline", privacy: .public)")
        for handler in observers.values {
            handler(online)
        }
    }
}
