//
//  DebugLaunchOptions.swift
//  Fluxo
//
//  Debug test harness, compiled out of release builds. Launch arguments (Tools/Simulator/README.md):
//
//  -FluxoDebugStore memory|temp|scratch   Isolated library that never touches the real one: in memory, a fresh
//                                          on-disk store in tmp (deleted at the next launch), or a separate store
//                                          in Application Support/FluxoDebug that is kept between launches.
//                                          Settings and recordings are isolated too.
//  -FluxoDebugSeed sample|large            Seeds the isolated library (implies -FluxoDebugStore memory).
//  -FluxoDebugImportPlaylist <url>         Imports a playlist at launch (implies -FluxoDebugStore memory).
//  -FluxoDebugRoute "<route>[;<route>…]"   Opens screens once the library is ready, see `DebugRoutes`
//                                          (implies -FluxoDebugStore memory).
//  -FluxoDebugPauseAfterEachRoute YES      After each route, waits until Tools/Simulator has taken a screenshot.
//  -FluxoDebugAppearance light|dark        Forces the color scheme of the window.
//  -FluxoDebugDynamicType <size>           Forces a Dynamic Type size (xSmall … xxxLarge, accessibility1 … 5).
//  -FluxoDebugTestStreamURL <url>          Base URL of Tools/Simulator/test-stream.sh (default http://127.0.0.1:18080).
//  -FluxoDebugCast simulated               Uses the simulated Chromecast receiver (SimulatedCastBackend) instead of
//                                          the Google Cast SDK.
//  -FluxoDebugCloud memory|<folder>        iCloud sync with a simulated cloud (`DebugCloud`), in memory or in a folder
//                                          that several simulators share (implies -FluxoDebugStore memory).
//  -FluxoDebugNextLaunch "<route>[;…]"     The next launch without harness arguments (one the system makes, e.g. from a
//                                          tapped notification) opens the same scratch library and runs these routes,
//                                          once (implies -FluxoDebugStore scratch).
//
//  Only the launch arguments are read (the argument domain), never values persisted in the user defaults, so a
//  normal Debug launch without arguments behaves exactly like the app. -FluxoDebugAppearance and
//  -FluxoDebugDynamicType alone only change the window and keep the real library; every other flag uses an
//  isolated one.
//

#if DEBUG
import Foundation
import os
import SwiftData
import SwiftUI

struct DebugLaunchOptions {

    enum StoreMode: String, CaseIterable {
        case memory
        case temp
        case scratch
    }

    enum Seed: String, CaseIterable {
        case sample
        case large
    }

    var store: StoreMode?
    var seed: Seed?
    var importURL: URL?
    var routes: [String] = []
    var pausesAfterEachRoute = false
    var colorScheme: ColorScheme?
    var dynamicTypeSize: DynamicTypeSize?
    /// Tools/Simulator/test-stream.sh, on the loopback interface (the simulator shares the Mac's).
    var testStreamBaseURL = URL(string: "http://127.0.0.1:18080") ?? URL(fileURLWithPath: "/")
    /// `-FluxoDebugCloud`: "memory" or the path of a folder.
    var cloud: String?
    /// `-FluxoDebugNextLaunch`: the routes of the next launch without harness arguments (`NextLaunch`).
    var nextLaunchRoutes: String?

    /// The options of this launch: its arguments, or, for a launch without any harness argument that a run armed with
    /// `-FluxoDebugNextLaunch` (the system launching the app from a notification), the scratch library and the routes
    /// of that run.
    static let current: DebugLaunchOptions = {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let options = DebugLaunchOptions(arguments: arguments)
        guard !arguments.keys.contains(where: { $0.hasPrefix("FluxoDebug") }) else {
            NextLaunch.arm(options.store == .scratch ? options.nextLaunchRoutes : nil)
            return options
        }
        guard let routes = NextLaunch.consume() else {
            return options
        }
        DebugLaunchOptions.logger.notice("Launch armed by -FluxoDebugNextLaunch: scratch library, routes \(routes, privacy: .public)")
        return DebugLaunchOptions(arguments: ["FluxoDebugStore": "scratch", "FluxoDebugRoute": routes])
    }()

    static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "DebugHarness")

    /// True when any harness argument was passed. Without one the harness does nothing at all.
    var isActive: Bool {
        store != nil || !routes.isEmpty || colorScheme != nil || dynamicTypeSize != nil
    }

    init(arguments: [String: Any]) {
        func string(_ key: String) -> String? {
            guard let value = arguments[key] else {
                return nil
            }
            let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        if let value = string("FluxoDebugStore") {
            if let mode = StoreMode(rawValue: value.lowercased()) {
                store = mode
            } else {
                // Never fall back to the real library because of a typo.
                Self.logger.error("Unknown -FluxoDebugStore \(value, privacy: .public); using memory")
                store = .memory
            }
        }
        if let value = string("FluxoDebugSeed") {
            seed = Seed(rawValue: value.lowercased())
            if seed == nil {
                Self.logger.error("Unknown -FluxoDebugSeed \(value, privacy: .public) (sample, large)")
            }
        }
        if let value = string("FluxoDebugImportPlaylist") {
            importURL = URL(string: value)
            if importURL == nil {
                Self.logger.error("Invalid -FluxoDebugImportPlaylist URL \(value, privacy: .public)")
            }
        }
        if let value = string("FluxoDebugRoute") {
            routes = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        cloud = string("FluxoDebugCloud")
        nextLaunchRoutes = string("FluxoDebugNextLaunch")
        if nextLaunchRoutes != nil {
            // The next launch reopens the library of this one: only the scratch library outlives a launch.
            if store == nil {
                store = .scratch
            } else if store != .scratch {
                Self.logger.error("-FluxoDebugNextLaunch needs -FluxoDebugStore scratch; ignored")
                nextLaunchRoutes = nil
            }
        }
        if seed != nil || importURL != nil || !routes.isEmpty || cloud != nil, store == nil {
            // Seeding, importing and routes always run on an isolated library: some routes write watch history
            // or settings, which must never reach the real ones.
            store = .memory
        }
        if let value = string("FluxoDebugPauseAfterEachRoute") {
            pausesAfterEachRoute = ["yes", "true", "1"].contains(value.lowercased())
        }
        if let value = string("FluxoDebugAppearance") {
            switch value.lowercased() {
            case "dark":
                colorScheme = .dark
            case "light":
                colorScheme = .light
            default:
                Self.logger.error("Unknown -FluxoDebugAppearance \(value, privacy: .public) (light, dark)")
            }
        }
        if let value = string("FluxoDebugDynamicType") {
            dynamicTypeSize = Self.dynamicTypeSizes[value.lowercased()]
            if dynamicTypeSize == nil {
                Self.logger.error("Unknown -FluxoDebugDynamicType \(value, privacy: .public)")
            }
        }
        if let value = string("FluxoDebugTestStreamURL"), let url = URL(string: value) {
            testStreamBaseURL = url
        }
    }

    /// The one-shot hand-over of `-FluxoDebugNextLaunch` to the next launch: a file in the app's tmp folder, read and
    /// deleted by the first launch without harness arguments. Any launch with harness arguments replaces or removes it,
    /// so a run never leaves a stale one behind for a later, unrelated launch.
    enum NextLaunch {
        private static let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxoDebug", isDirectory: true)
            .appendingPathComponent("next-launch", isDirectory: false)

        static func arm(_ routes: String?) {
            let fileManager = FileManager.default
            guard let routes else {
                try? fileManager.removeItem(at: file)
                return
            }
            try? fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(routes.utf8).write(to: file, options: .atomic)
        }

        static func consume() -> String? {
            guard let data = try? Data(contentsOf: file) else {
                return nil
            }
            try? FileManager.default.removeItem(at: file)
            return String(data: data, encoding: .utf8)
        }
    }

    /// SwiftUI names and the `simctl ui content_size` names.
    private static let dynamicTypeSizes: [String: DynamicTypeSize] = [
        "xsmall": .xSmall, "extra-small": .xSmall,
        "small": .small,
        "medium": .medium,
        "large": .large,
        "xlarge": .xLarge, "extra-large": .xLarge,
        "xxlarge": .xxLarge, "extra-extra-large": .xxLarge,
        "xxxlarge": .xxxLarge, "extra-extra-extra-large": .xxxLarge,
        "accessibility1": .accessibility1, "accessibility-medium": .accessibility1,
        "accessibility2": .accessibility2, "accessibility-large": .accessibility2,
        "accessibility3": .accessibility3, "accessibility-extra-large": .accessibility3,
        "accessibility4": .accessibility4, "accessibility-extra-extra-large": .accessibility4,
        "accessibility5": .accessibility5, "accessibility-extra-extra-extra-large": .accessibility5,
    ]
}

/// Where an isolated debug run keeps its library, settings, recordings and generated playlists.
/// `shared` is nil unless the app was launched with `-FluxoDebugStore` (or a flag that implies it).
///
/// Unchecked `Sendable`: every property is an immutable value, and `userDefaults` is a `UserDefaults`, which Apple
/// documents as thread-safe but does not mark `Sendable`.
final class DebugEnvironment: @unchecked Sendable {

    static let shared: DebugEnvironment? = DebugLaunchOptions.current.store.map(DebugEnvironment.init)

    /// Status files for Tools/Simulator (`ready`, `step-<n>`), always in tmp.
    static let statusDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FluxoDebug", isDirectory: true)
        .appendingPathComponent("Status", isDirectory: true)

    let mode: DebugLaunchOptions.StoreMode
    /// The folder of the isolated run (the store, recordings, downloads, the sync ledger).
    let rootDirectory: URL
    /// nil for the in-memory store.
    let storeURL: URL?
    let recordingsDirectory: URL
    /// Offline downloads (their manifest and files; HLS packages stay where AVFoundation puts them).
    let downloadsDirectory: URL
    /// Generated M3U files of `-FluxoDebugSeed`.
    let seedDirectory: URL
    let userDefaults: UserDefaults

    private init(mode: DebugLaunchOptions.StoreMode) {
        let fileManager = FileManager.default
        let root: URL
        let suiteName: String
        switch mode {
        case .memory, .temp:
            root = fileManager.temporaryDirectory
                .appendingPathComponent("FluxoDebug", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
            // A fresh library every launch.
            try? fileManager.removeItem(at: root)
            suiteName = "dev.watermelon.Fluxo.debug-harness"
        case .scratch:
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
            root = support.appendingPathComponent("FluxoDebug", isDirectory: true).appendingPathComponent("Scratch", isDirectory: true)
            suiteName = "dev.watermelon.Fluxo.debug-scratch"
        }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        self.mode = mode
        rootDirectory = root
        storeURL = mode == .memory ? nil : root.appendingPathComponent("Fluxo.store")
        recordingsDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
        downloadsDirectory = root.appendingPathComponent("Downloads", isDirectory: true)
        seedDirectory = root.appendingPathComponent("Seed", isDirectory: true)
        try? fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: seedDirectory, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if mode != .scratch {
            defaults.removePersistentDomain(forName: suiteName)
        }
        userDefaults = defaults
        DebugLaunchOptions.logger.notice("Isolated \(mode.rawValue, privacy: .public) library at \(root.path, privacy: .public)")
    }

    func makeContainer(schema: Schema) -> ModelContainer {
        // Never SwiftData's CloudKit mirroring (see `ModelContainerFactory.make()`): a signed build has the iCloud
        // entitlement, and an isolated library must not reach iCloud anyway.
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Could not create the debug store: \(error)")
        }
    }
}
#endif
