//
//  FluxoCommands.swift
//  Fluxo
//
//  Menu bar commands (macOS, and the iPad menu bar / keyboard shortcut overlay):
//  File > Add Playlist / Refresh, and a Playback menu that drives the single app-wide player.
//

import SwiftData
import SwiftUI

struct FluxoCommands: Commands {
    let player: AVPlayerViewModel
    let actions: PlaylistActions
    let importCenter: PlaylistImportCenter
    let container: ModelContainer

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Playlist…") {
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
        }

        CommandMenu("Playback") {
            // A view, so that the items observe the player and update their titles and enabled state.
            PlaybackMenuItems(player: player, actions: actions, importCenter: importCenter)
        }
    }
}

private struct PlaybackMenuItems: View {
    let player: AVPlayerViewModel
    let actions: PlaylistActions
    let importCenter: PlaylistImportCenter

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

        Divider()

        Button("Show Player") {
            player.presentationSourceID = nil
            player.isPresented = true
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(!hasChannel || player.isPresented || player.isPictureInPictureActive)

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
