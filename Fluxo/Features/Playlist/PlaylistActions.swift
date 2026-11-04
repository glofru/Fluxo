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

    /// True while the add / rename sheet or the delete confirmation is on screen.
    var isPresenting: Bool {
        sheet != nil || playlistToDelete != nil
    }

    func add() {
        urlToAdd = nil
        sheet = .add
    }

    /// The Add Playlist sheet, filled in with `url` (e.g. a link dropped on the window).
    func add(url: URL) {
        urlToAdd = url
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
    /// `PlaylistActions`. Apply once, at the root of the window.
    func playlistManagement() -> some View {
        modifier(PlaylistManagementPresenter())
    }
}

private struct PlaylistManagementPresenter: ViewModifier {

    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(ChannelLibrary.self) private var library
    /// With several windows (iPad), each sheet and alert shows in one of them (see `WindowCoordinator`).
    @Environment(WindowCoordinator.self) private var coordinator: WindowCoordinator?
    @Environment(\.windowID) private var windowID
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""

    func body(content: Content) -> some View {
        content
            .windowPresentation(.playlistSheet, isActive: actions.sheet != nil)
            .windowPresentation(.playlistDelete, isActive: actions.playlistToDelete != nil)
            .windowPresentation(.playlistFailure, isActive: importCenter.failure != nil)
            .sheet(item: sheetBinding) { sheet in
                NavigationStack {
                    switch sheet {
                    case .add:
                        AddPlaylistView(initialURL: actions.urlToAdd)
                    case .edit(let playlist):
                        AddPlaylistView(playlist: playlist)
                    }
                }
                .presentationDetents([.medium, .large])
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 300)
                #endif
            }
            .alert("Delete Playlist?", isPresented: deleteAlertBinding, presenting: actions.playlistToDelete) { playlist in
                Button("Delete", role: .destructive) {
                    delete(playlist)
                }
                Button("Cancel", role: .cancel) {}
            } message: { playlist in
                Text("\"\(playlist.name)\" and its \(playlist.channelCount.formatted()) channels, favorites and watch history will be removed from this device.")
            }
            .alert("Playlist Error", isPresented: failureAlertBinding, presenting: importCenter.failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text("\(failure.playlistName): \(failure.message)")
            }
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
        coordinator?.shows(presentation, in: windowID, isActive: isActive) ?? isActive
    }

    private var sheetBinding: Binding<PlaylistActions.Sheet?> {
        Binding(
            get: { shows(.playlistSheet, isActive: actions.sheet != nil) ? actions.sheet : nil },
            set: { actions.sheet = $0 }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { shows(.playlistDelete, isActive: actions.playlistToDelete != nil) }, set: { if !$0 { actions.playlistToDelete = nil } })
    }

    private var failureAlertBinding: Binding<Bool> {
        Binding(get: { shows(.playlistFailure, isActive: importCenter.failure != nil) }, set: { if !$0 { importCenter.failure = nil } })
    }
}
