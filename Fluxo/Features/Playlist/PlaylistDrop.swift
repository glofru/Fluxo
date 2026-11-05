//
//  PlaylistDrop.swift
//  Fluxo
//
//  Adding playlists by drag and drop (iPad, macOS) and from the Files app ("Open in Fluxo", iOS):
//  - a web link (http or https) dropped on a window opens Add Playlist with the address filled in;
//  - an M3U / M3U8 file is copied into the app (Application Support/Playlists) and imported from that copy.
//    Refreshing such a playlist reads the copy again.
//

import CoreTransferable
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Playlist files copied into the app. The stored playlist URL points at the copy; it is resolved against the
/// current container on every import, because the absolute path of the container changes with app updates (iOS).
enum LocalPlaylistFiles {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "LocalPlaylistFiles")
    private static let folderName = "Playlists"

    static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Where the copy of playlist `uuid` lives.
    static func url(for uuid: UUID) -> URL {
        directory.appendingPathComponent("\(uuid.uuidString).m3u")
    }

    /// `url` is the copy of a playlist file (wherever the container was when it was stored).
    static func isLocal(_ url: URL) -> Bool {
        guard url.isFileURL, url.deletingLastPathComponent().lastPathComponent == folderName else {
            return false
        }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    /// The copy in the current container for a stored playlist URL; other URLs are returned unchanged.
    static func resolve(_ url: URL) -> URL {
        isLocal(url) ? directory.appendingPathComponent(url.lastPathComponent) : url
    }

    /// Copies a playlist file into the app for a new playlist `uuid`.
    static func adopt(_ file: URL, for uuid: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url(for: uuid)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Deletes the copy of a deleted playlist (nothing for other URLs).
    static func remove(_ url: URL) {
        guard isLocal(url) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: resolve(url))
        } catch {
            logger.error("Could not delete a playlist file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A name for a playlist imported from `file` ("World TV" for "World TV.m3u").
    static func suggestedName(for file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Playlist") : name
    }
}

/// What can be dropped on a window to add a playlist.
enum PlaylistDrop: Transferable {
    /// A web link: opens Add Playlist with it.
    case link(URL)
    /// A playlist file, copied to a temporary file the app owns (the original is only readable during the drop).
    case file(URL, name: String)

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .m3uPlaylist) { received in
            let name = LocalPlaylistFiles.suggestedName(for: received.file)
            let staged = URL.temporaryDirectory.appendingPathComponent("DroppedPlaylist-\(UUID().uuidString).m3u")
            try FileManager.default.copyItem(at: received.file, to: staged)
            return PlaylistDrop.file(staged, name: name)
        }
        ProxyRepresentation(importing: { (url: URL) in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            return PlaylistDrop.link(url)
        })
    }
}

extension PlaylistImportCenter {
    /// Imports the playlist file at `file` (a copy the app owns, deleted afterwards) as a new playlist. Progress
    /// shows on Home; a failure is reported through `failure`.
    func importPlaylistFile(_ file: URL, name: String) {
        let uuid = UUID()
        defer {
            try? FileManager.default.removeItem(at: file)
        }
        let copy: URL
        do {
            copy = try LocalPlaylistFiles.adopt(file, for: uuid)
        } catch {
            failure = Failure(playlistName: name, message: error.localizedDescription)
            return
        }
        Task {
            do {
                try await addPlaylist(uuid: uuid, name: name, url: copy)
            } catch is CancellationError {
                LocalPlaylistFiles.remove(copy)
            } catch {
                LocalPlaylistFiles.remove(copy)
                failure = Failure(playlistName: name, message: error.localizedDescription)
            }
        }
    }

    /// A playlist file opened from another app ("Open in Fluxo", Finder's Open With). The file may be outside the
    /// sandbox: it is
    /// read once, into a copy the app owns.
    func importOpenedFile(_ url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let name = LocalPlaylistFiles.suggestedName(for: url)
        let staged = URL.temporaryDirectory.appendingPathComponent("OpenedPlaylist-\(UUID().uuidString).m3u")
        do {
            try FileManager.default.copyItem(at: url, to: staged)
        } catch {
            failure = Failure(playlistName: name, message: error.localizedDescription)
            return
        }
        importPlaylistFile(staged, name: name)
    }
}

extension View {
    /// Accepts playlist links and files dropped anywhere on the window (see `PlaylistDrop`), with a highlight
    /// while something that can be dropped hovers over it. Apply once, at the root of the window.
    @ViewBuilder
    func playlistDropDestination() -> some View {
        #if os(tvOS)
        // No drag and drop, and no files to open, on Apple TV (`PlatformFeatures.files`).
        self
        #else
        modifier(PlaylistDropModifier())
        #endif
    }
}

#if !os(tvOS)

private struct PlaylistDropModifier: ViewModifier {

    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: PlaylistDrop.self) { drops, _ in
                guard let drop = drops.first else {
                    return false
                }
                switch drop {
                case .link(let url):
                    actions.add(url: url)
                case .file(let file, let name):
                    importCenter.importPlaylistFile(file, name: name)
                    // Home shows the import's progress.
                    navigation?.show(.home)
                }
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
            .overlay {
                if isTargeted {
                    PlaylistDropHighlight()
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isTargeted)
            .onOpenURL { url in
                if url.isFileURL {
                    importCenter.importOpenedFile(url)
                    navigation?.show(.home)
                }
            }
    }
}

#endif

/// The window's outline and a label while a playlist hovers over it.
private struct PlaylistDropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 4, dash: [14, 8]))
                .padding(10)
            Label("Drop to Add Playlist", systemImage: "plus.rectangle.on.rectangle")
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular.tint(Theme.accent.opacity(0.35)), in: .capsule)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview("Drop highlight") {
    Color.appBackground
        .overlay {
            PlaylistDropHighlight()
        }
}
