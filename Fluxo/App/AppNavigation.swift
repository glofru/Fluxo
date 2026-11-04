//
//  AppNavigation.swift
//  Fluxo
//
//  Navigation state of the main window that is not local to one screen: the selected iOS tab or macOS
//  sidebar item, the navigation paths of Home, Favorites and Search, the search text and the Recordings
//  sheet. `ContentView` owns it and shares it through the environment, so code outside the screens (the
//  debug launch routes, and deep links or App Intents) can move the UI to a given place.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class AppNavigation {

    /// The iOS tabs. On iPad the sidebar also lists Recently Watched, Recordings and every playlist (hidden from
    /// the tab bar, and so never shown on iPhone).
    enum Tab: Hashable {
        case home
        case guide
        case favorites
        case settings
        case search
        case history
        case recordings
        case playlist(UUID)
    }

    /// Places that exist on every platform; `show(_:)` maps them to a tab (iOS) or a sidebar item (macOS).
    enum Destination: Hashable {
        case home
        case guide
        case search
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
    var favoritesPath = NavigationPath()
    var searchPath = NavigationPath()
    var searchText = ""
    /// The Recordings sheet of Home (iOS; macOS lists recordings in the sidebar).
    var isShowingRecordings = false
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
        case .home, .favorites, .history, .search, .playlist:
            return true
        case .guide, .settings, .recordings:
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
        case .favorites:
            sidebarSelection = .favorites
        case .history:
            sidebarSelection = .history
        case .recordings:
            sidebarSelection = .recordings
        }
        homePath = NavigationPath()
        #else
        isShowingRecordings = false
        switch destination {
        case .home:
            tab = .home
            homePath = NavigationPath()
        case .guide:
            tab = .guide
        case .search:
            tab = .search
            searchPath = NavigationPath()
        case .favorites:
            tab = .favorites
            favoritesPath = NavigationPath()
        case .history:
            tab = .favorites
            favoritesPath = NavigationPath([ChannelRoute.history(playlistIDs: nil)])
        case .recordings:
            tab = .home
            isShowingRecordings = true
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
        isShowingRecordings = false
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
