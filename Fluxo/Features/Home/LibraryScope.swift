//
//  LibraryScope.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation

/// Which playlists Home and Search show. Persisted as a string in `@AppStorage(PlaylistSelection.storageKey)`
/// so the Home switcher, the macOS sidebar and Search share it.
enum PlaylistSelection: Hashable {
    case all
    case playlist(UUID)

    static let storageKey = "home.playlistSelection"

    init(rawValue: String) {
        if let uuid = UUID(uuidString: rawValue) {
            self = .playlist(uuid)
        } else {
            self = .all
        }
    }

    var rawValue: String {
        switch self {
        case .all:
            return ""
        case .playlist(let uuid):
            return uuid.uuidString
        }
    }

    /// The selection, or `.all` when the selected playlist no longer exists.
    func resolved(in playlists: [Playlist]) -> PlaylistSelection {
        if case .playlist(let uuid) = self, !playlists.contains(where: { $0.uuid == uuid }) {
            return .all
        }
        return self
    }
}

/// The playlists a screen shows, reduced to the keys the queries need.
struct LibraryScope: Equatable {
    let playlistIDs: [UUID]
    /// Visible imports (`Playlist.currentImportID`) of those playlists.
    let importIDs: [UUID]
    let playlistNames: [UUID: String]
    let selection: PlaylistSelection

    init(playlists: [Playlist], selection: PlaylistSelection) {
        let selection = selection.resolved(in: playlists)
        let selected: [Playlist]
        switch selection {
        case .all:
            selected = playlists
        case .playlist(let uuid):
            selected = playlists.filter { $0.uuid == uuid }
        }
        self.selection = selection
        playlistIDs = selected.map(\.uuid)
        importIDs = selected.compactMap(\.currentImportID)
        playlistNames = Dictionary(selected.map { ($0.uuid, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var showsPlaylistNames: Bool {
        playlistIDs.count > 1
    }

    /// Bookmark filter: nil (no filter) when every playlist is shown.
    var bookmarkFilter: [UUID]? {
        selection == .all ? nil : playlistIDs
    }
}
