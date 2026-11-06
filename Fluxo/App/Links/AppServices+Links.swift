//
//  AppServices+Links.swift
//  Fluxo
//
//  Opens a `FluxoLink` the way the App Intent of the same name runs: Open Screen, Search in Fluxo, Show in TV Guide
//  and Continue Watching go through the same `AppServices` calls, so a link and Siri leave the app in the same state
//  (a channel schedule or a full-screen player moved out of the way first, the tab shown from its root).
//  Apple TV only, as `FluxoLink`.
//

#if os(tvOS)
import Foundation

extension AppServices {

    /// What opening a link did.
    enum LinkOutcome: Equatable {
        case opened
        /// The link names a channel this library no longer has (or one made on another device: see `FluxoLink`).
        case channelUnavailable
        /// Continue Watching with nothing watched yet.
        case nothingWatched
        /// A Top Shelf item (a channel, movie, episode or series, `TopShelfLink`) its playlist no longer lists.
        case topShelfItemUnavailable
    }

    @discardableResult
    func open(_ link: FluxoLink) async -> LinkOutcome {
        switch link {
        case .screen(let screen):
            reveal(screen.destination)
            return .opened
        case .search(let term):
            showSearch(term)
            return .opened
        case .guide(nil):
            reveal(.guide)
            return .opened
        case .guide(let channelID?):
            let container = container
            let item = await Task.detached(priority: .userInitiated) {
                ChannelEntityID.key(for: channelID, in: container).flatMap { LibraryLookup.channel(forKey: $0, in: container) }
            }.value
            guard let item, item.kind == .live else {
                // Still somewhere useful: the guide at now.
                reveal(.guide)
                return .channelUnavailable
            }
            showInGuide(item)
            return .opened
        case .continueWatching:
            guard let entry = continueWatchingItem() else {
                return .nothingWatched
            }
            play(entry.item)
            return .opened
        }
    }

    /// The TV guide at a live channel's row (today, at now), with the player and any sheet out of the way.
    func showInGuide(_ item: ChannelItem) {
        let isCovered = beginTVRequest()
        player.closePlayer()
        navigation.scheduleChannel = nil
        navigation.linkFailure = nil
        navigation.showInGuide(item)
        if isCovered {
            navigation.keepTab(for: Self.keptTabDuration)
        }
    }
}

extension FluxoLink.Screen {
    /// Where the screen is: each one is a tab of Apple TV, or a page of its Library tab.
    var destination: AppNavigation.Destination {
        switch self {
        case .home:
            return .home
        case .guide:
            return .guide
        case .search:
            return .search
        case .library:
            return .library
        case .favorites:
            return .favorites
        case .history:
            return .history
        case .recordings:
            return .recordings
        case .movies:
            return .movies
        case .series:
            return .series
        case .settings:
            return .settings
        }
    }
}
#endif
