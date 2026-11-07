//
//  AppGraph.swift
//  Fluxo
//
//  The app's long-lived objects, created once, when the library is open (`LibrarySession`).
//

import SwiftData
import SwiftUI

@MainActor
final class AppGraph {

    let container: ModelContainer
    let importCenter: PlaylistImportCenter
    /// Favorites and watch history.
    let library: ChannelLibrary
    /// Add / rename / delete requests, shared by the screens and the menu bar commands.
    let playlistActions: PlaylistActions
    /// The single player of the app. It owns the AVPlayer, the Picture in Picture surface, the remux
    /// engine, the loopback HLS server and the recordings, so there must never be more than one.
    let player: AVPlayerViewModel
    /// The TV guide: sources, refreshes, matching and reminders.
    let epg: EPGStore
    /// Apple Intelligence (on device): availability, recommendations and summaries.
    let intelligence: FluxoIntelligence
    /// The windows of the app (iPad): which one shows the player and the app-wide sheets, and the navigation
    /// App Intents move.
    let windows: WindowCoordinator
    /// Offline downloads of movies and episodes (the transfers continue in the background).
    let downloads: DownloadCenter
    /// iCloud sync of playlists, guides, favorites, watch progress and settings across the user's devices.
    let cloudSync: CloudSync
    /// The objects above, for App Intents (Siri, Shortcuts, Spotlight).
    let services: AppServices

    init(container: ModelContainer) {
        self.container = container
        let library = ChannelLibrary(container: container)
        // Chromecast through the Google Cast SDK on iOS; unsupported (no cast UI) on macOS and tvOS.
        let player = AVPlayerViewModel(cast: .makeDefault())
        player.zapper = ChannelZapper(container: container, library: library)
        player.resumePosition = { [weak library] item in
            library?.watchProgress(for: item)?.position
        }
        let downloads = DownloadCenter(container: container)
        player.downloads = downloads
        downloads.currentlyPlayingItem = { [weak player] in
            player?.currentItem
        }
        downloads.willDeleteMedia = { [weak player] in
            player?.stopIfPlayingDownload()
        }
        library.onFinishedWatching = { [weak downloads] item in
            downloads?.itemWasWatched(item)
        }
        // Now, not when a view appears: transfers that finished while the app was not running are collected, and
        // the queue goes on.
        downloads.start()
        let importCenter = PlaylistImportCenter(container: container)
        let epg = EPGStore(container: container)
        importCenter.onPlaylistImported = { [weak epg] playlistID in
            epg?.playlistDidImport(playlistID)
        }
        importCenter.onPlaylistDeleted = { [weak epg, weak downloads] playlistID in
            epg?.playlistWasDeleted(playlistID)
            downloads?.playlistWasDeleted(playlistID)
        }
        // Now, not when the first view appears: the reminder notification delegate must be installed before a
        // notification that launched the app is delivered.
        epg.start()
        // After the library, the imports and the guide it applies other devices' changes through.
        let playlistActions = PlaylistActions()
        let cloudSync = CloudSync(container: container, importCenter: importCenter, library: library, epg: epg)
        // The "Your Playlists from iCloud" offer never covers playback or the Add Playlist sheet.
        cloudSync.mayPresentImportOffer = { [weak player, weak playlistActions] in
            !(player?.isPresented ?? false) && !(playlistActions?.isPresenting ?? false)
        }
        cloudSync.start()
        let intelligence = FluxoIntelligence(container: container, epg: epg)
        let windows = WindowCoordinator()
        services = AppServices(container: container, library: library, player: player, epg: epg, windows: windows, intelligence: intelligence)
        self.importCenter = importCenter
        self.library = library
        self.playlistActions = playlistActions
        self.player = player
        self.epg = epg
        self.intelligence = intelligence
        self.windows = windows
        self.downloads = downloads
        self.cloudSync = cloudSync
    }
}
