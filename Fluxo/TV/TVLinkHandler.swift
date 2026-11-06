//
//  TVLinkHandler.swift
//  Fluxo
//
//  Opens the fluxo:// links of `FluxoLink` on Apple TV, where the scheme is registered: at launch or while the app
//  runs, over whatever it shows (a player in front closes, as it does for Siri). A link whose channel is gone, or
//  Continue Watching with nothing watched, says so in an alert instead of doing nothing. The alert's state is the
//  navigation's (`AppNavigation.linkFailure`), so whatever opens a screen next (Siri, another link) takes it down
//  first. The Top Shelf's own links are not `FluxoLink`s and are left to its handler (`TopShelfLink`), which shows
//  its "Not Available" through the same state, so this is the one alert of every link. `TVContentView` presents it
//  (`linkFailureAlert(_:epg:)`) with the other app-wide alerts, over the player when one is up.
//

#if os(tvOS)
import SwiftUI

extension View {
    /// Opens `FluxoLink`s through `services` (see `TVLinkHandler`).
    func fluxoLinks(_ services: AppServices) -> some View {
        modifier(TVLinkHandler(services: services))
    }

    /// The alert of a link that could not open (`AppNavigation.linkFailure`). One of the app-wide alerts
    /// `TVContentView` presents from the tab bar or the player, whichever is on top (see `AppModalsGate`): a link that
    /// fails while the player is up (the Top Shelf's "Not Available", Continue Watching with nothing watched) leaves
    /// it playing.
    func linkFailureAlert(_ navigation: AppNavigation, epg: EPGStore) -> some View {
        modifier(TVLinkFailureAlert(navigation: navigation, epg: epg))
    }
}

private struct TVLinkHandler: ViewModifier {
    let services: AppServices

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                open(url)
            }
            #if DEBUG
            // Debug harness (`link:<url>`): the same path as a link the system opens.
            .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugOpenLink)) { notification in
                if let url = notification.object as? URL {
                    open(url)
                }
            }
            #endif
    }

    private func open(_ url: URL) {
        guard let link = FluxoLink(url: url) else {
            return
        }
        Task {
            let outcome = await services.open(link)
            guard outcome != .opened else {
                services.navigation.linkFailure = nil
                return
            }
            // The screen the link opened first, so the focus moves there before the alert takes it (it comes back
            // to the same place after OK).
            let request = services.navigation.requestCount
            try? await Task.sleep(for: .milliseconds(600))
            // Siri or another link opened something meanwhile (even the same tab): the alert would be about the
            // request before it.
            guard services.navigation.requestCount == request else {
                return
            }
            services.navigation.linkFailure = outcome
        }
    }
}

private struct TVLinkFailureAlert: ViewModifier {
    let navigation: AppNavigation
    let epg: EPGStore

    /// Closed while the other presenter shows the alert (see `AppModalsGate`).
    @Environment(\.appModalsGate) private var gate

    private var failure: AppServices.LinkOutcome? {
        gate.isOpen() ? navigation.linkFailure : nil
    }

    func body(content: Content) -> some View {
        content
            // OK lands back on the link's tab: the alert comes once the focus has followed the link there (`open`).
            // When Siri or another link takes the alert down instead, it keeps the tab it opens against the focus
            // given back (`AppServices.reveal`, `AppNavigation.keepTab(for:)`).
            .alert(title, isPresented: Binding { failure != nil } set: { isPresented in
                // Handed over to the other presenter (the gate closed): the failure stays, for that one.
                if !isPresented, gate.isOpen() {
                    navigation.linkFailure = nil
                }
            }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message)
            }
    }

    private var title: String {
        switch failure {
        case .nothingWatched:
            return String(localized: "TV.link.nothingWatched.title", defaultValue: "Nothing to Continue", comment: "Apple TV: title of the alert when a link asks to continue watching but nothing was watched yet.")
        case .topShelfItemUnavailable:
            return String(localized: "TopShelf.unavailable.title", defaultValue: "Not Available", comment: "Title of the alert shown when an item of the Apple TV Top Shelf is opened but is no longer in the user's playlists.")
        default:
            return String(localized: "TV.link.unavailable.title", defaultValue: "Channel Not Available", comment: "Apple TV: title of the alert when a link opens the TV guide at a channel that is no longer in the playlists.")
        }
    }

    private var message: String {
        switch failure {
        case .nothingWatched:
            return String(localized: "TV.link.nothingWatched.message", defaultValue: "Movies and episodes you start watching show up in Continue Watching.", comment: "Apple TV: message of the alert when a link asks to continue watching but nothing was watched yet.")
        case .topShelfItemUnavailable:
            return String(localized: "TopShelf.unavailable.message", defaultValue: "It's no longer in your playlists.", comment: "Message of the alert shown when an item of the Apple TV Top Shelf (a channel, movie, episode or series) is opened but its playlist no longer lists it.")
        default:
            // Without a guide, the Live TV tab shows the channels (and Add a TV Guide), not what is on now.
            guard epg.hasGuide else {
                return String(localized: "TV.link.unavailable.noGuide.message", defaultValue: "It's no longer in your playlists. Live TV shows the channels you have.", comment: "Apple TV: message of the alert when a link opens a channel that is no longer in the playlists and there is no TV guide; the Live TV tab opens instead.")
            }
            return String(localized: "TV.link.unavailable.message", defaultValue: "It's no longer in your playlists. The TV guide shows what's on now.", comment: "Apple TV: message of the alert when a link opens the TV guide at a channel that is no longer in the playlists; the guide opens at now instead.")
        }
    }
}

#if DEBUG
extension Notification.Name {
    /// Debug harness (`link:<url>`): opens a fluxo:// link in process (`TVLinkHandler`).
    static let fluxoDebugOpenLink = Notification.Name("FluxoDebugOpenLink")
}
#endif
#endif
