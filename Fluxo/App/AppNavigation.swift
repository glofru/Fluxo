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
        #if os(tvOS)
        /// Apple TV: the movies of the playlists, a tab of their own (the top tab bar has room for them).
        case movies
        /// Apple TV: the series of the playlists.
        case series
        #endif
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
        /// The offline downloads: listed in the Library tab (iOS); the Downloads item of the macOS sidebar.
        case downloads
        #if os(tvOS)
        /// Apple TV: the Movies tab.
        case movies
        /// Apple TV: the Series tab.
        case series
        /// Apple TV: the Settings tab.
        case settings
        #endif
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
    #if os(tvOS)
    /// Apple TV: what a fluxo:// link could not do, shown in an alert (`TVLinkHandler`). Whatever opens a screen
    /// next (Siri, another link) clears it with the other sheets (`AppServices.reveal`), so it never stays over the
    /// screen that follows.
    var linkFailure: AppServices.LinkOutcome?

    /// Apple TV: a request to show a tab from its root, for the tabs whose stack belongs to their screen (Live TV,
    /// Movies, Series and Settings pop it when it is for them). Each request is new.
    struct RootRequest: Equatable {
        let tab: Tab
        let id = UUID()
    }

    /// Apple TV: the last `show(_:)`, for the screens that keep their own stack.
    var rootRequest: RootRequest?

    /// Apple TV: counts the requests (Siri, a link) that changed the screen, so a link's alert that comes a moment
    /// after its screen opened is not shown over what a later request opened (`TVLinkHandler`).
    @ObservationIgnored private(set) var requestCount = 0

    /// Apple TV: the tab a request opened while the player or an alert covered the tab bar, and until when it is
    /// kept (see `keepTab(for:)`).
    @ObservationIgnored private var keptTab: (tab: Tab, until: ContinuousClock.Instant)?

    /// Apple TV: a request (Siri, a link) is changing the screen.
    func noteRequest() {
        requestCount &+= 1
    }

    /// Apple TV: keeps the selected tab against focus restoration for `duration`. When a full-screen cover (the
    /// player) or an alert goes away, tvOS gives the focus back to what had it before; when that was an item of the
    /// tab bar, focusing it selects its tab again, which would undo the tab a request just opened behind the
    /// cover. The first other tab selected within `duration` is undone once (`tabDidChange()`); after that, or
    /// after `duration`, the tab bar is the viewer's again. Only for a cover or alert taken down by a request: never
    /// after Menu or OK, where the viewer is the one moving.
    func keepTab(for duration: Duration) {
        keptTab = (tab, .now + duration)
    }

    /// Apple TV: the player's cover finished going away; the focus is given back now, so the kept tab (if any) is
    /// kept from now on for `duration`.
    func coverDidDismiss(keepingFor duration: Duration) {
        guard let kept = keptTab, ContinuousClock.now < kept.until else {
            return
        }
        keptTab = (kept.tab, max(kept.until, .now + duration))
    }

    /// Apple TV: the viewer took a cover down themselves (Menu): nothing is kept.
    func releaseKeptTab() {
        keptTab = nil
    }

    /// Apple TV: the selected tab changed (`TVContentView`); undoes it once when it was focus restoration taking
    /// back the tab a request opened (see `keepTab(for:)`).
    func tabDidChange() {
        guard let kept = keptTab else {
            return
        }
        guard ContinuousClock.now < kept.until else {
            keptTab = nil
            return
        }
        if tab != kept.tab {
            keptTab = nil
            tab = kept.tab
        }
    }
    #endif
    /// A channel the TV guide is to show (scrolled to now and to its row, highlighted), e.g. Full Guide in the
    /// player; the guide clears it once it has (see `showInGuide(_:)`).
    var guideFocus: GuideFocus?

    /// A request to show a channel in the TV guide. Each request is new, so asking again for the same channel
    /// scrolls to it again.
    struct GuideFocus: Equatable {
        let item: ChannelItem
        let id = UUID()
    }

    #if DEBUG
    /// Debug harness (`overscroll:<points>`): Home's content is pushed down as if pulled by this much.
    var debugHomeOverscroll: CGFloat = 0
    /// Debug harness (`home-section:<name>`): the `HomeSection` Home scrolls to.
    var debugHomeSection: String?
    /// Debug harness (`programme:<channel>`): the programme the TV Guide opens (a sheet, or the inspector on iPad).
    var debugGuideSelection: GuideSelection?
    /// Debug harness (`focus:<name>`, Apple TV): the name of the card, button or programme that takes the focus.
    var debugFocusName: String?
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
        #if os(tvOS)
        case .movies, .series:
            return false
        #endif
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
        case .downloads:
            sidebarSelection = .downloads
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
        case .library, .recordings, .downloads:
            // The recordings and the downloads are listed in the Library itself.
            tab = .library
            libraryPath = NavigationPath()
        case .favorites:
            tab = .library
            libraryPath = NavigationPath([ChannelRoute.favorites(playlistIDs: nil)])
        case .history:
            tab = .library
            libraryPath = NavigationPath([ChannelRoute.history(playlistIDs: nil)])
        #if os(tvOS)
        case .movies:
            tab = .movies
        case .series:
            tab = .series
        case .settings:
            tab = .settings
        #endif
        }
        #if os(tvOS)
        rootRequest = RootRequest(tab: tab)
        #endif
        #endif
    }

    /// Shows the TV guide at a live channel: today, scrolled to now and to the channel's row, which is highlighted.
    func showInGuide(_ item: ChannelItem) {
        show(.guide)
        guideFocus = GuideFocus(item: item)
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
