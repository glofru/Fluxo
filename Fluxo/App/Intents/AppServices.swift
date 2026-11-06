//
//  AppServices.swift
//  Fluxo
//
//  The app's long-lived objects, for code outside the view hierarchy: App Intents (Siri, Shortcuts, Spotlight)
//  and the Spotlight indexer. `FluxoApp` creates it once and registers it with `AppDependencyManager`, so intents
//  get it with `@Dependency`. Intents run in the app's process, so they drive the same player, library, guide and
//  navigation as the screens (on iPad, the navigation of the main window used last).
//

import AppIntents
import Foundation
import SwiftData

@MainActor
final class AppServices {

    nonisolated let container: ModelContainer
    let library: ChannelLibrary
    let player: AVPlayerViewModel
    let epg: EPGStore
    let windows: WindowCoordinator
    let intelligence: FluxoIntelligence
    let spotlight: ChannelSpotlightIndexer

    init(container: ModelContainer, library: ChannelLibrary, player: AVPlayerViewModel, epg: EPGStore, windows: WindowCoordinator, intelligence: FluxoIntelligence) {
        self.container = container
        self.library = library
        self.player = player
        self.epg = epg
        self.windows = windows
        self.intelligence = intelligence
        spotlight = ChannelSpotlightIndexer(container: container)
        #if DEBUG
        Self.debugShared = self
        #endif
    }

    #if DEBUG
    /// The app's instance, for the debug harness (`intent:` routes run the intents in process).
    private(set) static weak var debugShared: AppServices?
    #endif

    /// The navigation of the main window used last (iPad windows each have their own).
    var navigation: AppNavigation {
        windows.intentNavigation
    }

    /// Plays a channel like a tap on its card: it goes to the top of the watch history and the player opens. A
    /// player already on screen stays in its window; otherwise it opens in the main window used last.
    func play(_ item: ChannelItem) {
        let windowID = player.isPresented ? nil : windows.preferredMainWindowID
        #if os(tvOS)
        // The player is presented over the alert of a link that failed, which would then be under it. (A player
        // on screen stays: the tab under it does not change.)
        let hadAlert = navigation.linkFailure != nil
        navigation.noteRequest()
        navigation.linkFailure = nil
        if hadAlert {
            navigation.keepTab(for: Self.keptTabDuration)
        }
        #endif
        if windowID != nil {
            // The player opens under a sheet of the window: a channel schedule shown by an earlier request would
            // hide it.
            dismissSheets()
        }
        PlayChannelAction(library: library, player: player, coordinator: windows, windowID: windowID)(item)
    }

    /// Shows a screen of the main window used last. A full-screen player gets out of the way (playback continues
    /// in the mini player), since it would cover the screen. Apple TV has no mini player: closing its player stops
    /// playback, as the Menu button does.
    func reveal(_ destination: AppNavigation.Destination) {
        #if os(tvOS)
        let isCovered = beginTVRequest()
        #endif
        // As the close button does: into Picture in Picture when the user chose it, else the mini player.
        player.closePlayer()
        dismissSheets()
        navigation.show(destination)
        #if os(tvOS)
        if isCovered {
            navigation.keepTab(for: Self.keptTabDuration)
        }
        #endif
    }

    #if os(tvOS)
    /// Apple TV: notes a request that changes the screen, and returns whether the player or a link's alert covers
    /// the tab bar now. Taking either down gives the focus back to what had it before; when that was an item of the
    /// tab bar, it would select its tab again over the one the request opens (`AppNavigation.keepTab(for:)`).
    func beginTVRequest() -> Bool {
        navigation.noteRequest()
        return player.isPresented || navigation.linkFailure != nil
    }

    /// How long a tab opened behind the player or an alert is kept (from the moment the player's cover is gone,
    /// `TVContentView`): the focus comes back within about a second.
    static let keptTabDuration: Duration = .seconds(2)
    #endif

    /// Closes the sheet an earlier request may have left open over the main window (a channel schedule; on Apple TV,
    /// the alert of a link that failed), so what the next request shows is not hidden behind it. Recordings are a
    /// screen of the Library tab, not a sheet.
    private func dismissSheets() {
        navigation.scheduleChannel = nil
        #if os(tvOS)
        navigation.linkFailure = nil
        #endif
    }

    /// Search with `term` typed in.
    func showSearch(_ term: String) {
        reveal(.search)
        navigation.searchText = term
    }

    /// The schedule of a live channel (today and the next days from the guide), over the current screen. Apple TV
    /// has no schedule sheet: its TV guide grid opens at the channel's row instead, where the remote moves along the
    /// channel's programmes (and each one has Remind Me).
    func showSchedule(of item: ChannelItem) {
        #if os(tvOS)
        showInGuide(item)
        #else
        player.closePlayer()
        navigation.scheduleChannel = item
        #endif
    }

    /// Donates "Play <channel>" to the system after a channel starts, however it was started (an intent run by Siri
    /// or Shortcuts is donated by the system as well; a repeat costs nothing).
    func donatePlay(_ item: ChannelItem) {
        #if DEBUG && os(macOS)
        // A debug run on an isolated library shares the bundle identifier, and so the donations Siri learns from,
        // with the user's copy of the app (as for Spotlight in `ChannelSpotlightIndexer`).
        if DebugEnvironment.shared != nil {
            return
        }
        #endif
        let names = ChannelEntityQuery.playlistNames(container)
        guard let entity = ChannelEntity(item, playlistName: names[item.playlistID]) else {
            return
        }
        _ = PlayChannelIntent(channel: entity).donate()
    }

    /// The import IDs of every playlist with channels (intents search the whole library).
    nonisolated func allImportIDs() -> [UUID] {
        LibraryLookup.visiblePlaylists(in: container).map(\.importID)
    }

    /// Waits until the guide has loaded its channel matching (at most `timeout`), so an intent that launched the
    /// app in the background does not answer "no guide" while the guide is still opening. Returns whether a
    /// guide is available.
    func waitForGuide(timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !epg.isReady, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return epg.hasGuide
    }

    /// What "Continue watching" resumes: the most recently watched movie or episode with a saved position, else the
    /// channel watched last.
    func continueWatchingItem() -> (item: ChannelItem, progress: WatchProgress?)? {
        let history = LibraryLookup.bookmarks(playlistIDs: nil, historyLimit: 60, favoriteLimit: 0, in: container).history
        for entry in history {
            if let progress = library.watchProgress(for: entry.item) {
                return (entry.item, progress)
            }
        }
        return history.first.map { ($0.item, nil) }
    }

    /// The channel an intent without a channel parameter is about: the one playing, else the last watched.
    func currentOrLastChannel() -> ChannelItem? {
        if let item = player.currentItem {
            return item
        }
        return LibraryLookup.bookmarks(playlistIDs: nil, historyLimit: 1, favoriteLimit: 0, in: container).history.first?.item
    }
}

/// Errors App Intents report to Siri and Shortcuts.
enum FluxoIntentError: Error, CustomLocalizedStringResourceConvertible {
    case channelNotFound(String)
    case nothingPlaying
    /// The recording failed; the associated value is the error of the recording engine.
    case cannotRecord(String)
    /// The channel cannot be recorded; the associated value is the full explanation.
    case recordingUnavailable(LocalizedStringResource)
    case notRecording
    case noGuide
    case noProgrammes(String)
    case programmeNotFound
    case programmeStarted(String)
    case notificationsOff
    case noPlaylists
    case noSuggestions
    case nothingWatched
    case noFavorites

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .channelNotFound(let name):
            return "Fluxo has no channel called “\(name)”."
        case .nothingPlaying:
            return "Nothing is playing in Fluxo."
        case .cannotRecord(let reason):
            return "Fluxo can't record this channel: \(reason)"
        case .recordingUnavailable(let explanation):
            return explanation
        case .notRecording:
            return "Fluxo is not recording."
        case .noGuide:
            return "Fluxo has no TV guide for this channel. Add a guide in Settings › TV Guide."
        case .noProgrammes(let query):
            return "No programme in the TV guide matches “\(query)”."
        case .programmeNotFound:
            return "This programme is no longer in the TV guide."
        case .programmeStarted(let title):
            return "“\(title)” has already started."
        case .notificationsOff:
            return "Allow notifications for Fluxo in Settings to get reminders."
        case .noPlaylists:
            return "Add a playlist in Fluxo first."
        case .noSuggestions:
            return "Fluxo has no suggestions yet. Watch a few channels or add favorites first."
        case .nothingWatched:
            return "You haven't watched anything in Fluxo yet."
        case .noFavorites:
            return "You have no favorite channels in Fluxo yet."
        }
    }
}
