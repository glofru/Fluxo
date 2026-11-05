//
//  FluxoCommands.swift
//  Fluxo
//
//  Menu bar commands (macOS, and the iPad menu bar / keyboard shortcut overlay):
//  File > New Window (iPad) / Add Playlist / Refresh / Refresh TV Guide, a Go menu with the app's sections (⌘1 to ⌘6
//  and ⌘F, every screen from the keyboard), and a Playback menu that drives the single app-wide player (with Copy
//  Link, ⇧⌘C, of what plays). Commands act on the focused window.
//

// Menu bar and keyboard commands (Mac, iPad and iPhone keyboards). tvOS has no menu bar (SwiftUI Commands are unavailable there).
#if !os(tvOS)
import SwiftData
import SwiftUI

struct FluxoCommands: Commands {
    let player: AVPlayerViewModel
    let actions: PlaylistActions
    let importCenter: PlaylistImportCenter
    let container: ModelContainer
    let epg: EPGStore
    let windows: WindowCoordinator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            #if os(iOS)
            NewWindowButton()
            #endif

            FocusedWindowButton("Add Playlist…", windows: windows) {
                actions.add()
            }
            .keyboardShortcut("n")

            Button("Refresh All Playlists") {
                let playlists = (try? container.mainContext.fetch(FetchDescriptor<Playlist>())) ?? []
                for playlist in playlists {
                    importCenter.refresh(playlist)
                }
            }
            .keyboardShortcut("r")

            Button("Refresh TV Guide") {
                epg.refreshAll()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }

        CommandMenu("Go") {
            GoMenuItems(windows: windows)
        }

        CommandMenu("Playback") {
            // A view, so that the items observe the player and update their titles and enabled state.
            PlaybackMenuItems(player: player, actions: actions, importCenter: importCenter, windows: windows)
        }
    }
}

/// A command whose result shows in the focused window (e.g. a sheet): the window is noted first, so the
/// `WindowCoordinator` presents it there.
private struct FocusedWindowButton: View {
    let title: LocalizedStringKey
    let windows: WindowCoordinator
    let action: () -> Void

    @FocusedValue(\.windowID) private var focusedWindowID

    init(_ title: LocalizedStringKey, windows: WindowCoordinator, action: @escaping () -> Void) {
        self.title = title
        self.windows = windows
        self.action = action
    }

    var body: some View {
        Button(title) {
            windows.noteActivity(in: focusedWindowID)
            action()
        }
    }
}

#if os(iOS)
/// File › New Window (iPad): another window of the app. Replacing the New group removes the system's own item.
private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some View {
        if supportsMultipleWindows {
            Button("New Window") {
                openWindow(id: FluxoApp.mainWindowID)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
        }
    }
}
#endif

/// Go: the sections of the focused window (⌘1 … ⌘6), and Search (⌘F). Keyboard access to every screen (Full Keyboard
/// Access, Voice Control "Press Command 2").
private struct GoMenuItems: View {
    let windows: WindowCoordinator

    @FocusedValue(AppNavigation.self) private var navigation
    @FocusedValue(\.windowID) private var focusedWindowID

    var body: some View {
        item("Home", destination: .home, key: "1")
        item("TV Guide", destination: .guide, key: "2")
        item("Favorites", destination: .favorites, key: "3")
        item("Recently Watched", destination: .history, key: "4")
        item("Recordings", destination: .recordings, key: "5")
        #if os(iOS)
        Button("Settings") {
            go { navigation in
                navigation.tab = .settings
            }
        }
        .keyboardShortcut("6")
        .disabled(navigation == nil)
        #endif

        Divider()

        Button("Search") {
            go { navigation in
                navigation.show(.search)
            }
        }
        .keyboardShortcut("f")
        .disabled(navigation == nil)
    }

    private func item(_ title: LocalizedStringKey, destination: AppNavigation.Destination, key: KeyEquivalent) -> some View {
        Button(title) {
            go { navigation in
                navigation.show(destination)
            }
        }
        .keyboardShortcut(key)
        .disabled(navigation == nil)
    }

    private func go(_ change: (AppNavigation) -> Void) {
        guard let navigation else {
            return
        }
        windows.noteActivity(in: focusedWindowID)
        change(navigation)
    }
}

private struct PlaybackMenuItems: View {
    let player: AVPlayerViewModel
    let actions: PlaylistActions
    let importCenter: PlaylistImportCenter
    let windows: WindowCoordinator

    @FocusedValue(\.windowID) private var focusedWindowID
    @FocusedValue(\.linkCopyFeedback) private var linkCopyFeedback

    var body: some View {
        let hasChannel = player.currentChannel != nil
        // Shortcuts without ⌘, and the arrow keys, would also fire while typing in a text field: they are
        // only enabled while the player is on screen (it has no text fields) and no playlist sheet or alert
        // is shown over it (⌘N can open the Add Playlist sheet on top of the player).
        let isModalShown = actions.isPresenting || importCenter.failure != nil
        let isOnScreen = hasChannel && player.isPresented && !isModalShown

        Button(isPaused ? "Play" : "Pause") {
            player.togglePlayPause()
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!isOnScreen)

        Button("Skip Back \(Int(AVPlayerViewModel.skipBackwardInterval)) Seconds") {
            player.skipBackward()
        }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(!isOnScreen || !player.canSeek)

        Button("Skip Forward \(Int(AVPlayerViewModel.skipForwardInterval)) Seconds") {
            player.skipForward()
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(!isOnScreen || !player.canSeek)

        Button("Go Live") {
            player.goLive()
        }
        .keyboardShortcut("l")
        .disabled(!hasChannel || !player.isTimeShiftAvailable)

        Divider()

        Button("Channel Up") {
            player.nextChannel()
        }
        .keyboardShortcut(.upArrow, modifiers: .command)
        .disabled(!isOnScreen || !player.canZap)

        Button("Channel Down") {
            player.previousChannel()
        }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .disabled(!isOnScreen || !player.canZap)

        Divider()

        Button(player.isRecording ? "Stop Recording" : "Record") {
            player.toggleRecording()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!player.canRecord && !player.isRecording)

        Button(player.isPictureInPictureActive ? "Exit Picture in Picture" : "Picture in Picture") {
            player.togglePictureInPicture()
        }
        .keyboardShortcut("p", modifiers: [.command, .option])
        .disabled(!player.isPictureInPictureSupported || (!player.isPictureInPicturePossible && !player.isPictureInPictureActive))

        Button(player.fillsScreen ? "Fit Video" : "Fill Video") {
            player.toggleFillsScreen()
        }
        .disabled(!hasChannel)

        // Audio tracks and subtitles of what plays (keyboard and menu bar access to the player's menu).
        Menu("Audio and Subtitles") {
            MediaSelectionMenuContent(controller: player.mediaSelection)
        }
        .disabled(!player.mediaSelection.hasChoices)

        Divider()

        // The stream link of what plays (a playlist entry; recordings have none), confirmed in the focused window.
        Button("Copy Link") {
            if let link = StreamLink(player.currentItem?.url) {
                LinkCopyFeedback.copy(link, feedback: linkCopyFeedback)
            }
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(StreamLink(player.currentItem?.url) == nil || isModalShown)

        Divider()

        Button("Show Player") {
            // In the focused window (iPad).
            if let focusedWindowID {
                windows.move(.player, to: focusedWindowID)
            }
            player.presentationSourceID = nil
            player.presentPlayer()
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(!hasChannel || player.isPresented)

        Button("Stop Playback") {
            player.stop()
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(!hasChannel)
    }

    private var isPaused: Bool {
        switch player.playbackState {
        case .paused, .ended, .failed, .idle:
            return true
        default:
            return false
        }
    }
}
#endif
