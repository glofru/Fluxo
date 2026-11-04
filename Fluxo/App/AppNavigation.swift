//
//  AppNavigation.swift
//  Fluxo
//
//  Navigation state of the main window that is not local to one screen: the selected iOS tab or macOS
//  sidebar item, the navigation paths of Home, Library and Search, and the search text. `ContentView` owns it and
//  shares it through the environment, so code outside the screens (the debug launch routes, and deep links or App
//  Intents) can move the UI to a given place.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class AppNavigation {

    /// The iOS tabs: Home, Guide, Library, Settings and Search. The iPad sidebar also lists every playlist (hidden
    /// from its tab bar, and never declared on iPhone; see `AppTabView`).
    enum Tab: Hashable {
        case home
        case guide
        /// What the user keeps: links to Favorites and Recently Watched, then the recordings (see `LibraryView`).
        case library
        case settings
        case search
        case playlist(UUID)
    }

    /// Places that exist on every platform; `show(_:)` maps them to a tab (iOS) or a sidebar item (macOS).
    enum Destination: Hashable {
        case home
        case guide
        case search
        /// The Library tab (iOS); the Recordings item of the macOS sidebar's Library section.
        case library
        case favorites
        case history
        case recordings
    }

    var tab: Tab = .home

    /// The macOS sidebar. Selecting another item starts the detail from its root; leaving Search clears its
    /// text and pushed screens, so Search starts empty the next time it is picked.
    var sidebarSelection: SidebarItem? = .home {
        didSet {
            guard sidebarSelection != oldValue else {
                return
            }
            homePath = NavigationPath()
            if oldValue == .search {
                searchPath = NavigationPath()
                searchText = ""
            }
        }
    }

    var homePath = NavigationPath()
    /// The Library tab (Favorites and Recently Watched are pushed on it).
    var libraryPath = NavigationPath()
    var searchPath = NavigationPath()
    var searchText = ""
    /// The live channel whose schedule (today's programmes from the TV guide) is shown in a sheet.
    var scheduleChannel: ChannelItem?

    #if DEBUG
    /// Debug harness (`overscroll:<points>`): Home's content is pushed down as if pulled by this much.
    var debugHomeOverscroll: CGFloat = 0
    /// Debug harness (`home-section:<name>`): the `HomeSection` Home scrolls to.
    var debugHomeSection: String?
    /// Debug harness (`programme:<channel>`): the programme the TV Guide opens (a sheet, or the inspector on iPad).
    var debugGuideSelection: GuideSelection?
    #endif

    /// iPad: the window has room for an inspector next to its content (see `AppTabView.isWide(_:)`). Narrower
    /// windows, portrait ones included, show the channel schedule in a sheet: an inspector would cover the content.
    var isWideWindow = false

    /// The selected tab shows the channel schedule in an inspector in a wide window (iPad), rather than in a sheet
    /// (see `channelScheduleInspector()`).
    var tabHostsScheduleInspector: Bool {
        switch tab {
        case .home, .library, .search, .playlist:
            return true
        case .guide, .settings:
            return false
        }
    }

    /// Shows `destination` from its root.
    func show(_ destination: Destination) {
        #if os(macOS)
        switch destination {
        case .home:
            sidebarSelection = .home
        case .guide:
            sidebarSelection = .guide
        case .search:
            sidebarSelection = .search
            searchPath = NavigationPath()
        case .library, .recordings:
            sidebarSelection = .recordings
        case .favorites:
            sidebarSelection = .favorites
        case .history:
            sidebarSelection = .history
        }
        homePath = NavigationPath()
        #else
        switch destination {
        case .home:
            tab = .home
            homePath = NavigationPath()
        case .guide:
            tab = .guide
        case .search:
            tab = .search
            searchPath = NavigationPath()
        case .library, .recordings:
            // The recordings are listed in the Library itself.
            tab = .library
            libraryPath = NavigationPath()
        case .favorites:
            tab = .library
            libraryPath = NavigationPath([ChannelRoute.favorites(playlistIDs: nil)])
        case .history:
            tab = .library
            libraryPath = NavigationPath([ChannelRoute.history(playlistIDs: nil)])
        }
        #endif
    }

    /// Pushes a channel screen (a group's grid, favorites, history) on Home.
    func pushOnHome(_ route: ChannelRoute) {
        #if os(macOS)
        if sidebarSelection != .home && !(sidebarSelection?.isPlaylist ?? false) {
            sidebarSelection = .home
        }
        #else
        tab = .home
        #endif
        homePath.append(route)
    }
}

extension SidebarItem {
    var isPlaylist: Bool {
        if case .playlist = self {
            return true
        }
        return false
    }
}
