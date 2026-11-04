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
    }

    /// The navigation of the main window used last (iPad windows each have their own).
    var navigation: AppNavigation {
        windows.intentNavigation
    }

    /// Plays a channel like a tap on its card: it goes to the top of the watch history and the player opens. A
    /// player already on screen stays in its window; otherwise it opens in the main window used last.
    func play(_ item: ChannelItem) {
        let windowID = player.isPresented ? nil : windows.preferredMainWindowID
        PlayChannelAction(library: library, player: player, coordinator: windows, windowID: windowID)(item)
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
    case cannotRecord(String)
    case notRecording
    case noGuide
    case noProgrammes(String)
    case programmeNotFound
    case programmeStarted(String)
    case notificationsOff
    case noPlaylists
    case noSuggestions

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .channelNotFound(let name):
            return "Fluxo has no channel called “\(name)”."
        case .nothingPlaying:
            return "Nothing is playing in Fluxo."
        case .cannotRecord(let reason):
            return "Fluxo can't record this channel: \(reason)"
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
        }
    }
}
