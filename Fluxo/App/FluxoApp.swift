//
//  FluxoApp.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-05-31.
//

import AppIntents
import SwiftData
import SwiftUI

@main
struct FluxoApp: App {

    /// The library and, once it is open, the app's objects (`AppGraph`). A library that cannot be opened shows
    /// `LibraryRecoveryView` in every window instead.
    @State private var session: LibrarySession

    init() {
        // First: the player, the guide and the downloads ask whether the device is online.
        NetworkMonitor.shared.start()
        // Low Power Mode, the thermal state and the background: the player and the guide adapt to them.
        PowerMonitor.shared.start()
        // Crash, hang and performance reports from MetricKit, kept on this device only (Settings › About ›
        // Diagnostic Reports).
        DiagnosticsCollector.shared.start()
        // Before the library opens: a reminder notification that launched the app is delivered as the launch ends,
        // which can be before the library is open (the launch that updates it). It waits for the guide.
        PlatformReminderDelivery.installEarly()
        let session = LibrarySession()
        // Before any intent runs: intents launched by Siri or Shortcuts read it with @Dependency (an error when the
        // library cannot be opened).
        AppDependencyManager.shared.add(dependency: { @Sendable in
            try await session.services()
        })
        _session = State(initialValue: session)
    }

    var body: some Scene {
        #if os(macOS)
        // A single main window: the player, its PiP surface and the local server are app-wide.
        Window("Fluxo", id: "main") {
            LibraryGate(session: session) { graph in
                mainContent(graph)
            }
            .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 1_240, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            if let graph = session.graph {
                FluxoCommands(player: graph.player, actions: graph.playlistActions, importCenter: graph.importCenter, container: graph.container, epg: graph.epg, windows: graph.windows)
            }
        }

        Settings {
            LibraryGate(session: session) { graph in
                SettingsView(player: graph.player)
                    .environment(graph.library)
                    .environment(graph.downloads)
                    .environment(graph.epg)
                    .environment(graph.intelligence)
                    .environment(graph.cloudSync)
                    .environment(graph.importCenter)
                    .modelContainer(graph.container)
                    .defaultAppStorage(.fluxo)
                    // Copy Address (Settings › TV Guide) confirms in this window: the login warning and the expiry.
                    .linkCopyFeedbackHost()
            }
        }
        #elseif os(tvOS)
        // Apple TV: one full-screen window. The player is the system's, presented over the tabs (`TVContentView`).
        WindowGroup(id: Self.mainWindowID) {
            LibraryGate(session: session) { graph in
                mainContent(graph)
            }
        }
        .backgroundTask(.appRefresh(EPGBackgroundRefresh.taskIdentifier)) { [session] in
            // Ask for the next run first, so a refresh that runs out of time is still followed by another.
            EPGBackgroundRefresh.schedule()
            if let epg = await session.graph?.epg {
                await epg.performBackgroundRefresh()
            }
        }
        #else
        // iPad: several windows of the app (File › New Window, or the app's windows in Stage Manager). They share
        // the single player, which shows in one window at a time (see `WindowCoordinator`).
        WindowGroup(id: Self.mainWindowID) {
            LibraryGate(session: session) { graph in
                mainContent(graph)
            }
        }
        .commands {
            if let graph = session.graph {
                FluxoCommands(player: graph.player, actions: graph.playlistActions, importCenter: graph.importCenter, container: graph.container, epg: graph.epg, windows: graph.windows)
            }
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(EPGBackgroundRefresh.taskIdentifier)) { [session] in
            // Ask for the next run first, so a refresh that runs out of time is still followed by another.
            EPGBackgroundRefresh.schedule()
            if let epg = await session.graph?.epg {
                await epg.performBackgroundRefresh()
            }
        }
        // Downloads that progressed or finished while the app was suspended or not running: the system relaunches
        // it in the background to deliver their events, and waits until they are handled.
        .backgroundTask(.urlSession(matching: { $0.hasPrefix(DownloadTransport.identifierPrefix) })) { identifier in
            await DownloadTransport.shared.handleBackgroundEvents(for: identifier)
        }
        #endif

        #if os(iOS)
        // iPad: a channel in a window of its own ("Open in New Window"). A window restored at the next launch waits
        // for a tap instead of playing on its own (see `WindowCoordinator.pendingPlayerWindows`).
        WindowGroup("Player", id: PlayerWindowValue.windowID, for: PlayerWindowValue.self) { $value in
            LibraryGate(session: session) { graph in
                PlayerWindowView(value: value, player: graph.player)
                    .modifier(AppEnvironment(graph: graph))
                    .modelContainer(graph.container)
            }
        }
        .defaultSize(width: 960, height: 600)
        #endif
        #endif
    }

    /// The main window group (iOS, tvOS).
    static let mainWindowID = "main"

    private func mainContent(_ graph: AppGraph) -> some View {
        rootView(graph)
            .appServicesLifecycle(graph.services)
            .environment(graph.intelligence)
            .environment(graph.importCenter)
            .environment(graph.library)
            .environment(graph.playlistActions)
            .environment(graph.epg)
            .environment(graph.windows)
            .environment(graph.downloads)
            .environment(graph.cloudSync)
            .modelContainer(graph.container)
    }

    /// Each main window has its own navigation; the first one adopts the navigation App Intents may already have
    /// moved at launch.
    @ViewBuilder
    private func rootView(_ graph: AppGraph) -> some View {
        #if os(tvOS)
        TVContentView(viewModel: graph.player, navigation: graph.windows.makeMainWindowNavigation())
        #else
        ContentView(viewModel: graph.player, navigation: graph.windows.makeMainWindowNavigation())
        #endif
    }
}

/// The content of a window once the library is open; the recovery screen while it cannot be.
private struct LibraryGate<Content: View>: View {
    let session: LibrarySession
    @ViewBuilder let content: (AppGraph) -> Content

    var body: some View {
        switch session.state {
        case .upgrading:
            LibraryUpgradeView()
        case .ready(let graph):
            content(graph)
        case .unavailable(let failure):
            LibraryRecoveryView(session: session, failure: failure)
        }
    }
}

#if !os(tvOS)
/// The app's shared objects, for a window that is not a `ContentView` (the iPad player window).
private struct AppEnvironment: ViewModifier {
    let graph: AppGraph

    @State private var navigation = AppNavigation()

    func body(content: Content) -> some View {
        content
            // The player is already in this window: playing another channel from it keeps it here.
            .environment(\.playChannel, PlayChannelAction(library: graph.library, player: graph.player))
            .environment(graph.importCenter)
            .environment(graph.library)
            .environment(graph.playlistActions)
            .environment(graph.epg)
            .environment(graph.intelligence)
            .environment(graph.windows)
            .environment(graph.downloads)
            .environment(graph.cloudSync)
            .environment(navigation)
            .defaultAppStorage(.fluxo)
            .tint(Theme.accent)
    }
}
#endif
