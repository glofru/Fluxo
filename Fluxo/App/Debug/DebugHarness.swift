//
//  DebugHarness.swift
//  Fluxo
//
//  Debug harness: applies the launch arguments of `DebugLaunchOptions` to the main window (forced appearance and
//  Dynamic Type), seeds or imports the isolated library, then runs the `-FluxoDebugRoute` steps.
//
//  Progress is reported to Tools/Simulator through files in tmp/FluxoDebug/Status:
//  - `step-<n>` after route n has run and the UI has settled, for every step, also an unknown or failed one
//    (the file then holds the problem). With `-FluxoDebugPauseAfterEachRoute YES` the harness waits until the
//    file is deleted (the script deletes it once its screenshots are taken).
//  - `ready` once everything has run.
//

#if DEBUG
import os
import SwiftData
import SwiftUI

extension View {
    /// Applies the debug launch arguments. Without any, it changes nothing.
    func debugHarness(player: AVPlayerViewModel, navigation: AppNavigation) -> some View {
        modifier(DebugHarnessModifier(player: player, navigation: navigation))
    }
}

private struct DebugHarnessModifier: ViewModifier {

    let player: AVPlayerViewModel
    let navigation: AppNavigation

    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(ChannelLibrary.self) private var library
    @Environment(PlaylistActions.self) private var playlistActions
    @Environment(EPGStore.self) private var epg
    @Environment(\.modelContext) private var modelContext
    @Environment(WindowCoordinator.self) private var windows: WindowCoordinator?
    #if os(iOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    #endif
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    @State private var status: String?

    private let options = DebugLaunchOptions.current

    func body(content: Content) -> some View {
        if options.isActive {
            content
                .preferredColorScheme(options.colorScheme)
                .modifier(OptionalDynamicTypeSize(size: options.dynamicTypeSize))
                .overlay(alignment: .top) {
                    if let status {
                        DebugStatusBadge(text: status)
                            .padding(.top, 8)
                            .transition(.opacity)
                    }
                }
                .task {
                    await DebugHarnessRunner.runOnce(context: routeContext, options: options) { text in
                        status = text
                    }
                }
        } else {
            content
        }
    }

    private var routeContext: DebugRouteContext {
        #if os(macOS)
        let openSettings: (() -> Void)? = { self.openSettings() }
        #else
        let openSettings: (() -> Void)? = nil
        #endif
        var context = DebugRouteContext(
            navigation: navigation,
            player: player,
            library: library,
            importCenter: importCenter,
            playlistActions: playlistActions,
            modelContext: modelContext,
            epg: epg,
            openSettings: openSettings
        )
        #if os(iOS)
        if supportsMultipleWindows, let windows {
            context.openChannelWindow = OpenChannelWindowAction(openWindow: openWindow, coordinator: windows)
        }
        #endif
        return context
    }
}

private struct OptionalDynamicTypeSize: ViewModifier {
    let size: DynamicTypeSize?

    func body(content: Content) -> some View {
        if let size {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}

@MainActor
private enum DebugHarnessRunner {

    private static var didRun = false
    /// Time for animations and lazy content after a step, before it is reported as done.
    private static let settleDelay: Duration = .milliseconds(1_200)

    static func runOnce(context: DebugRouteContext, options: DebugLaunchOptions, status: @escaping (String?) -> Void) async {
        guard !didRun else {
            return
        }
        didRun = true
        let logger = DebugLaunchOptions.logger
        let statusDirectory = DebugEnvironment.statusDirectory
        try? FileManager.default.removeItem(at: statusDirectory)
        try? FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)

        // Report typos before seeding, which can take a while.
        let unknownSteps = options.routes.filter { DebugRoutes.resolve($0) == nil }
        if !unknownSteps.isEmpty {
            logger.error("Unknown debug route \(unknownSteps.joined(separator: ", "), privacy: .public). \(DebugRoutes.helpText, privacy: .public)")
        }

        let services = DebugSeeder.Services(importCenter: context.importCenter, library: context.library, recordings: context.player.recordings, modelContext: context.modelContext)
        if let environment = DebugEnvironment.shared {
            if let seed = options.seed {
                await DebugSeeder.seed(seed, environment: environment, testStreamBaseURL: options.testStreamBaseURL, services: services, status: status)
            }
            if let url = options.importURL {
                await DebugSeeder.importPlaylist(from: url, services: services, status: status)
            }
        }
        status(nil)

        for (index, step) in options.routes.enumerated() {
            // Every step writes its marker, even an unknown or failed one: Tools/Simulator waits for them in order.
            var report = step
            if let (route, argument) = DebugRoutes.resolve(step) {
                logger.notice("Route \(index + 1): \(step, privacy: .public)")
                do {
                    try await route.run(context, argument)
                } catch {
                    logger.error("Route \"\(step, privacy: .public)\" failed: \(error.localizedDescription, privacy: .public)")
                    report += " (failed: \(error.localizedDescription))"
                }
            } else {
                report += " (unknown route)"
            }
            try? await Task.sleep(for: settleDelay)
            let marker = statusDirectory.appendingPathComponent("step-\(index + 1)")
            write(report, to: marker)
            if options.pausesAfterEachRoute {
                // Up to 60 s for the screenshots.
                for _ in 0..<600 where FileManager.default.fileExists(atPath: marker.path) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        if options.routes.isEmpty {
            try? await Task.sleep(for: settleDelay)
        }
        write("ready", to: statusDirectory.appendingPathComponent("ready"))
        logger.notice("Debug harness ready")
    }

    private static func write(_ text: String, to url: URL) {
        try? Data((text + "\n").utf8).write(to: url, options: .atomic)
    }
}

/// Small capsule shown while the library is being seeded.
private struct DebugStatusBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "hammer.fill")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .accessibilityLabel(Text(verbatim: "Debug: \(text)"))
    }
}

#Preview("Status badge") {
    DebugStatusBadge(text: "Importing Sky Italia…")
        .padding()
}
#endif
