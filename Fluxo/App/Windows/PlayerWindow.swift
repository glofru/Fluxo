//
//  PlayerWindow.swift
//  Fluxo
//
//  iPad: a channel in a window of its own ("Open in New Window" in the context menu of a channel). The window
//  plays the channel with the regular player screen, edge to edge, so it can sit next to the app in Split View or
//  Stage Manager and be resized freely.
//
//  The app still has a single player: opening a channel in a window moves playback there, and the other windows
//  show the mini player. Playing something in another window moves the player out of this one, which then offers
//  to play its channel again. Closing the player (its chevron) or the window ends the window; playback continues in
//  the mini player (or in Picture in Picture).
//

import SwiftData
import SwiftUI

/// Identifies the channel of a player window. It holds no stream URL: window values are kept by the system,
/// and stream URLs can embed account credentials. The channel is read from the store when the window appears.
struct PlayerWindowValue: Codable, Hashable, Sendable {
    let channelID: UUID
    let playlistID: UUID
    let groupName: String
    let name: String?

    init(_ item: ChannelItem) {
        channelID = item.id
        playlistID = item.playlistID
        groupName = item.groupName
        name = item.name
    }

    init(channelID: UUID, playlistID: UUID, groupName: String, name: String?) {
        self.channelID = channelID
        self.playlistID = playlistID
        self.groupName = groupName
        self.name = name
    }

    /// The `WindowGroup` of player windows.
    static let windowID = "player"
}

/// Opens a channel in a new player window, where the platform supports several windows (iPad).
struct OpenChannelWindowAction {
    private let openWindow: OpenWindowAction?
    private let coordinator: WindowCoordinator?

    init(openWindow: OpenWindowAction? = nil, coordinator: WindowCoordinator? = nil) {
        self.openWindow = openWindow
        self.coordinator = coordinator
    }

    var isAvailable: Bool {
        openWindow != nil && coordinator != nil
    }

    @MainActor
    func callAsFunction(_ item: ChannelItem) {
        guard let openWindow, let coordinator, item.url != nil else {
            return
        }
        let value = PlayerWindowValue(item)
        coordinator.pendingPlayerWindows.insert(value)
        openWindow(id: PlayerWindowValue.windowID, value: value)
    }
}

extension View {
    /// Provides `OpenChannelWindowAction` to the channel menus of this window: on iOS when the device can show
    /// several windows (iPad), never on macOS (its single main window owns the player).
    func channelWindowOpening(coordinator: WindowCoordinator) -> some View {
        modifier(ChannelWindowOpening(coordinator: coordinator))
    }
}

private struct ChannelWindowOpening: ViewModifier {
    let coordinator: WindowCoordinator

    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .environment(\.openChannelWindow, supportsMultipleWindows ? OpenChannelWindowAction(openWindow: openWindow, coordinator: coordinator) : OpenChannelWindowAction())
        #else
        content
        #endif
    }
}

extension EnvironmentValues {
    @Entry var openChannelWindow = OpenChannelWindowAction()
}

/// The content of a player window.
struct PlayerWindowView: View {

    let value: PlayerWindowValue?
    let player: AVPlayerViewModel

    @Environment(WindowCoordinator.self) private var coordinator
    @Environment(ChannelLibrary.self) private var library
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    #if os(iOS)
    /// This window's scene, to bring the app's main window forward when it closes.
    @State private var windowScene: UIWindowScene?
    #endif

    @State private var windowID = UUID()
    @State private var item: ChannelItem?
    /// The channel is no longer in its playlist (it was refreshed or deleted).
    @State private var isMissing = false

    private var showsPlayer: Bool {
        coordinator.shows(.player, in: windowID, isActive: player.isPresented) && player.currentChannel != nil
    }

    private var isPending: Bool {
        value.map(coordinator.pendingPlayerWindows.contains) ?? false
    }

    var body: some View {
        ZStack {
            if showsPlayer {
                WatchChannelView(viewModel: player)
                    .transition(.opacity)
            } else {
                PlayerWindowPlaceholder(
                    name: item?.displayName ?? value?.name ?? String(localized: "Channel"),
                    item: item,
                    isMissing: isMissing,
                    isPlayingElsewhere: isPlayingElsewhere,
                    play: playHere,
                    close: closeWindow
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsPlayer)
        .navigationTitle(item?.displayName ?? value?.name ?? "")
        #if os(iOS)
        .background {
            WindowSceneReader { scene in
                windowScene = scene
            }
        }
        #endif
        #if os(iOS)
        // The Cast button of the player in this window opens the device picker here.
        .castDevicePickerSheet(player: player)
        #endif
        .windowPresentation(.player, isActive: player.isPresented)
        .windowScene(windowID, kind: .player, coordinator: coordinator)
        .task(id: value) {
            resolve()
            if isPending {
                startPending()
            }
        }
        .onChange(of: isPending) { _, pending in
            // The window was already open and its channel was opened in a new window again.
            if pending, item != nil {
                startPending()
            }
        }
        .onChange(of: showsPlayer) { wasShowing, isShowing in
            // The player was closed here (chevron, swipe, Stop, or it went into Picture in Picture): the window has
            // done its job. When the player only moved to another window, `isPresented` is still true.
            if wasShowing, !isShowing, !player.isPresented {
                closeWindow()
            }
        }
        .onDisappear {
            // The window was closed while it showed the player: playback continues in the mini player.
            if coordinator.owner(of: .player) == windowID, player.isPresented {
                player.isPresented = false
            }
        }
    }

    /// Closes this window and shows the app's main window (the mini player continues there). Without this, a
    /// player window closed in full screen would leave the user on the Home Screen.
    private func closeWindow() {
        #if os(iOS)
        let application = UIApplication.shared
        if let windowScene {
            // Another window of the app (player windows close themselves, so it is nearly always a main window),
            // preferably one that is on screen.
            let others = application.openSessions.filter { $0 != windowScene.session && $0.role == .windowApplication }
            let onScreen = others.first { session in
                session.scene.map { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive } ?? false
            }
            if let main = onScreen ?? others.first {
                application.activateSceneSession(for: UISceneSessionActivationRequest(session: main))
            } else {
                openWindow(id: FluxoApp.mainWindowID)
            }
            application.requestSceneSessionDestruction(windowScene.session, options: nil)
            return
        }
        #endif
        dismissWindow()
    }

    private var isPlayingElsewhere: Bool {
        guard let item, let current = player.currentItem else {
            return false
        }
        return current.id == item.id && player.isPresented
    }

    private func startPending() {
        guard let value else {
            return
        }
        coordinator.pendingPlayerWindows.remove(value)
        playHere()
    }

    private func playHere() {
        guard let item else {
            return
        }
        library.recordWatch(item)
        coordinator.move(.player, to: windowID)
        player.presentationSourceID = nil
        player.play(item)
    }

    /// Finds the channel in the visible import of its playlist: by row, then by name in its group.
    private func resolve() {
        guard let value else {
            isMissing = true
            return
        }
        guard let importID = try? modelContext.fetch(HomeQueries.playlist(uuid: value.playlistID)).first?.currentImportID else {
            isMissing = true
            return
        }
        if let channel = try? modelContext.fetch(HomeQueries.channel(importID: importID, groupName: value.groupName, uuid: value.channelID)).first {
            item = ChannelItem(channel)
            isMissing = false
            return
        }
        let groupName = value.groupName
        let name = value.name
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName && $0.name == name },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchLimit = 1
        if let channel = try? modelContext.fetch(descriptor).first {
            item = ChannelItem(channel)
            isMissing = false
        } else {
            isMissing = true
        }
    }
}

/// What a player window shows while the player is elsewhere: the channel, and a button to play it here.
private struct PlayerWindowPlaceholder: View {
    let name: String
    let item: ChannelItem?
    let isMissing: Bool
    let isPlayingElsewhere: Bool
    let play: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            Theme.brandGradient
                .ignoresSafeArea()

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close Window")
            .help("Close this window")
            .keyboardShortcut("w")
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            VStack(spacing: 18) {
                if let item {
                    ChannelLogoTile(item: item, size: CGSize(width: 180, height: 120), cornerRadius: 22)
                        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 6) {
                    Text(name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)

                if item != nil {
                    Button(action: play) {
                        Label("Play Here", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentFill)
                    .controlSize(.large)
                }
            }
            .padding(32)
            .frame(maxWidth: 460)
        }
        .environment(\.colorScheme, .dark)
    }

    private var message: String {
        if isMissing {
            return String(localized: "This channel is no longer in its playlist.")
        }
        if isPlayingElsewhere {
            return String(localized: "Playing in another window.")
        }
        return String(localized: "The player is in another window.")
    }
}

#Preview("Placeholder") {
    PlayerWindowPlaceholder(name: "Sky Sport F1", item: PreviewSampleData.sampleItems.first, isMissing: false, isPlayingElsewhere: true, play: {}, close: {})
        .fluxoPreviewEnvironment()
}

#if os(iOS)
/// Reports the window scene a view is in.
private struct WindowSceneReader: UIViewRepresentable {
    let onChange: (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            let scene = window?.windowScene
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(scene)
            }
        }
    }
}
#endif
