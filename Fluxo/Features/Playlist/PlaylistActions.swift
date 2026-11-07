//
//  PlaylistActions.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Observation
import SwiftUI

/// Add / rename / refresh / delete requests for playlists, shared by the Home switcher, the toolbar menus and
/// the macOS sidebar. The sheets and alerts are presented once, at the root, by `playlistManagement()`.
@MainActor
@Observable
final class PlaylistActions {

    enum Sheet: Identifiable {
        case add
        case edit(Playlist)

        var id: String {
            switch self {
            case .add:
                return "add"
            case .edit(let playlist):
                return "edit-\(playlist.uuid)"
            }
        }
    }

    var sheet: Sheet?
    /// Playlist waiting for the delete confirmation.
    var playlistToDelete: Playlist?
    /// The address the Add Playlist sheet starts with (a URL dropped on the window); nil for an empty form.
    var urlToAdd: URL?
    /// The name the Add Playlist sheet starts with (the demo playlist).
    var nameToAdd: String?

    /// True while the add / rename sheet or the delete confirmation is on screen.
    var isPresenting: Bool {
        sheet != nil || playlistToDelete != nil
    }

    func add() {
        urlToAdd = nil
        nameToAdd = nil
        sheet = .add
    }

    /// The Add Playlist sheet, filled in with `url` (e.g. a link dropped on the window).
    func add(url: URL) {
        urlToAdd = url
        nameToAdd = nil
        sheet = .add
    }

    /// The Add Playlist sheet, filled in with the demo playlist (free test streams and Creative Commons films).
    func addDemo() {
        urlToAdd = DemoPlaylist.url
        nameToAdd = DemoPlaylist.name
        sheet = .add
    }

    func edit(_ playlist: Playlist) {
        sheet = .edit(playlist)
    }

    /// Asks for confirmation; nothing is deleted until the user confirms the alert.
    func requestDelete(_ playlist: Playlist) {
        playlistToDelete = playlist
    }
}

/// Menu / context menu entries for one playlist.
struct PlaylistMenuItems: View {

    let playlist: Playlist

    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(PlaylistActions.self) private var actions

    var body: some View {
        if importCenter.progress[playlist.uuid] != nil {
            Button("Cancel Update", systemImage: "xmark.circle") {
                importCenter.cancelImport(for: playlist.uuid)
            }
        } else {
            Button("Refresh", systemImage: "arrow.clockwise") {
                importCenter.refresh(playlist)
            }
        }

        Button("Edit Playlist…", systemImage: "pencil") {
            actions.edit(playlist)
        }

        Divider()

        Button("Delete", systemImage: "trash", role: .destructive) {
            actions.requestDelete(playlist)
        }
    }
}

extension View {
    /// Presents the add / rename sheet, the delete confirmation and import errors requested through
    /// `PlaylistActions`. Apply once, at the root of the window (on Apple TV, also to the player: see `AppModalsGate`).
    func playlistManagement() -> some View {
        modifier(PlaylistManagementPresenter())
    }
}

private struct PlaylistManagementPresenter: ViewModifier {

    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(ChannelLibrary.self) private var library
    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?
    @Environment(CloudSync.self) private var cloudSync: CloudSync?
    /// With several windows (iPad), each sheet and alert shows in one of them (see `WindowCoordinator`).
    @Environment(WindowCoordinator.self) private var coordinator: WindowCoordinator?
    @Environment(\.windowID) private var windowID
    /// Closed while another presenter shows them (Apple TV, while the player is up: see `AppModalsGate`).
    @Environment(\.appModalsGate) private var gate
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""

    func body(content: Content) -> some View {
        content
            .windowPresentation(.playlistSheet, isActive: actions.sheet != nil)
            .windowPresentation(.playlistDelete, isActive: actions.playlistToDelete != nil)
            .windowPresentation(.playlistFailure, isActive: importCenter.failure != nil)
            #if os(tvOS)
            // Apple TV: a page of its own, opaque and wide enough for a whole address (a sheet there is a narrow
            // translucent card that cuts it off).
            .fullScreenCover(item: sheetBinding) { sheet in
                sheetContent(sheet)
                    .tvFormPage()
            }
            #else
            .sheet(item: sheetBinding) { sheet in
                sheetContent(sheet)
                    .mediumAndLargeDetentsAdaptingToTextSize()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 300)
                    #endif
            }
            #endif
            .alert("Delete Playlist?", isPresented: deleteAlertBinding, presenting: actions.playlistToDelete) { playlist in
                Button("Delete", role: .destructive) {
                    delete(playlist)
                }
                Button("Cancel", role: .cancel) {}
            } message: { playlist in
                deletionMessage(playlist)
            }
            .alert("Playlist Error", isPresented: failureAlertBinding, presenting: importCenter.failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text("\(failure.playlistName): \(failure.message)")
            }
    }

    private func sheetContent(_ sheet: PlaylistActions.Sheet) -> some View {
        NavigationStack {
            switch sheet {
            case .add:
                AddPlaylistView(initialURL: actions.urlToAdd, initialName: actions.nameToAdd)
            case .edit(let playlist):
                AddPlaylistView(playlist: playlist)
            }
        }
    }

    /// What goes with the playlist: its offline downloads (`DownloadCenter.playlistWasDeleted`), and its copies on
    /// the user's other devices when it is synced with iCloud. Each is said only when it applies.
    private func deletionMessage(_ playlist: Playlist) -> Text {
        let downloads = hasDownloads(playlist)
        if cloudSync?.syncsPlaylist(playlist.uuid) == true {
            return downloads
                ? Text("“\(playlist.name)” and its \(playlist.channelCount) channels, favorites and watch history will be removed from this device and from your other devices that sync with iCloud. Its downloads on this device will be deleted.", comment: "Message of the Delete Playlist alert when the playlist is synced with iCloud and movies or episodes of it are downloaded on this device; the placeholders are the playlist name and its number of channels.")
                : Text("“\(playlist.name)” and its \(playlist.channelCount) channels, favorites and watch history will be removed from this device and from your other devices that sync with iCloud.", comment: "Message of the Delete Playlist alert when the playlist is synced with iCloud; the placeholders are the playlist name and its number of channels.")
        }
        return downloads
            ? Text("“\(playlist.name)” and its \(playlist.channelCount) channels, favorites, watch history and downloads will be removed from this device.", comment: "Message of the Delete Playlist alert when movies or episodes of the playlist are downloaded; the placeholders are the playlist name and its number of channels.")
            : Text("“\(playlist.name)” and its \(playlist.channelCount) channels, favorites and watch history will be removed from this device.", comment: "Message of the Delete Playlist alert; the placeholders are the playlist name and its number of channels.")
    }

    private func hasDownloads(_ playlist: Playlist) -> Bool {
        let uuid = playlist.uuid
        return downloads?.records.contains { $0.item.playlistID == uuid } ?? false
    }

    private func delete(_ playlist: Playlist) {
        let uuid = playlist.uuid
        if PlaylistSelection(rawValue: selectionRawValue) == .playlist(uuid) {
            selectionRawValue = PlaylistSelection.all.rawValue
        }
        library.forgetPlaylist(uuid)
        LocalPlaylistFiles.remove(playlist.url)
        importCenter.delete(playlist)
    }

    private func shows(_ presentation: WindowCoordinator.Presentation, isActive: Bool) -> Bool {
        gate.isOpen() && (coordinator?.shows(presentation, in: windowID, isActive: isActive) ?? isActive)
    }

    // A presentation handed over to the other presenter (its gate closed) is dismissed without being answered: the
    // setters then leave the request alone, so the other presenter shows it (see `AppModalsGate`).

    private var sheetBinding: Binding<PlaylistActions.Sheet?> {
        Binding(
            get: { shows(.playlistSheet, isActive: actions.sheet != nil) ? actions.sheet : nil },
            set: { sheet in
                if gate.isOpen() {
                    actions.sheet = sheet
                }
            }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { shows(.playlistDelete, isActive: actions.playlistToDelete != nil) }, set: { if !$0, gate.isOpen() { actions.playlistToDelete = nil } })
    }

    private var failureAlertBinding: Binding<Bool> {
        Binding(get: { shows(.playlistFailure, isActive: importCenter.failure != nil) }, set: { if !$0, gate.isOpen() { importCenter.failure = nil } })
    }
}
