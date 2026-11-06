//
//  TopShelfLinks.swift
//  Fluxo
//
//  Opens the fluxo:// links of the Top Shelf items (`TopShelfLink`): plays a channel, movie or episode, plays a
//  series where the viewer left off, or opens a series page on Home. Links arrive at launch or while the app runs,
//  over whatever it shows: the player switches to the new item, a series page is pushed on Home.
//
//  A Top Shelf link is a request like Siri's or a `FluxoLink`'s (`AppServices.beginTVRequest()`): it takes down the
//  alert of an earlier link, drops one still to come, and keeps the tab it opens behind the player or an alert while
//  tvOS gives the focus back (`AppNavigation.keepTab(for:)`). Its "Not Available" is the navigation's link failure
//  (`AppNavigation.linkFailure`, shown by `TVLinkHandler`), so Siri or the next link take it down the same way.
//

#if os(tvOS)
import SwiftData
import SwiftUI

extension View {
    /// Handles the links of the Top Shelf (see `TopShelfLinkHandler`).
    func topShelfLinks(player: AVPlayerViewModel) -> some View {
        modifier(TopShelfLinkHandler(player: player))
    }
}

private struct TopShelfLinkHandler: ViewModifier {
    let player: AVPlayerViewModel

    @Environment(ChannelLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.playChannel) private var playChannel
    @Environment(\.modelContext) private var modelContext

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
        guard let link = TopShelfLink(url: url) else {
            return
        }
        Task {
            await open(link)
        }
    }

    private func open(_ link: TopShelfLink) async {
        navigation.noteRequest()
        let request = navigation.requestCount
        let container = modelContext.container
        switch link {
        case .playChannel(let id):
            let item = await Task.detached(priority: .userInitiated) {
                ChannelEntityID.key(for: id, in: container).flatMap { LibraryLookup.channel(forKey: $0, in: container) }
            }.value
            guard let item else {
                await fail(request)
                return
            }
            await play(request) {
                playChannel(item)
            }
        case .playSeries(let playlistID, let key, let title):
            guard let series = series(playlistID: playlistID, key: key, title: title) else {
                await fail(request)
                return
            }
            await play(request) {
                await SeriesPlayback.play(series, library: library, container: container, playChannel: playChannel)
            }
        case .openSeries(let playlistID, let key, let title):
            guard let series = series(playlistID: playlistID, key: key, title: title) else {
                await fail(request)
                return
            }
            // As `AppServices.reveal`: the player, a channel schedule and a link's alert get out of the way, and the
            // tab is kept against the focus they give back.
            let isCovered = player.isPresented || navigation.linkFailure != nil
            if player.isPresented {
                player.closePlayer()
            }
            navigation.scheduleChannel = nil
            navigation.linkFailure = nil
            navigation.show(.home)
            navigation.pushOnHome(series.route)
            if isCovered {
                navigation.keepTab(for: AppServices.keptTabDuration)
            }
        }
    }

    /// Plays the link's item, as `AppServices.play`: over the alert of an earlier link, which goes first (the tab
    /// under it is kept against the focus it gives back). A newer request that came while the item was looked up
    /// wins: the item is not played over it.
    private func play(_ request: Int, _ start: () async -> Void) async {
        guard navigation.requestCount == request else {
            return
        }
        let hadAlert = navigation.linkFailure != nil
        navigation.linkFailure = nil
        if hadAlert {
            navigation.keepTab(for: AppServices.keptTabDuration)
        }
        await start()
    }

    /// The link's item is gone: "Not Available", unless a newer request came meanwhile (the alert would be about
    /// the request before it). An earlier link's alert still on screen goes first: an alert keeps the title it was
    /// presented with, so it would go on saying what that link could not do. As when Siri takes it down
    /// (`AppServices.reveal`), the tab under it is kept against the focus it gives back, and the new alert comes
    /// once that focus has settled.
    private func fail(_ request: Int) async {
        guard navigation.requestCount == request else {
            return
        }
        if navigation.linkFailure != nil {
            navigation.linkFailure = nil
            navigation.keepTab(for: AppServices.keptTabDuration)
            try? await Task.sleep(for: .milliseconds(600))
            guard navigation.requestCount == request else {
                return
            }
        }
        navigation.linkFailure = .topShelfItemUnavailable
    }

    /// The series of a link: its bookmark (a favorite series), else the series of its playlist's visible import.
    private func series(playlistID: UUID, key: String, title: String) -> SeriesItem? {
        if let bookmark = try? modelContext.fetch(SeriesQueries.bookmark(key: SeriesBookmark.key(playlistID: playlistID, seriesKey: key))).first {
            return SeriesItem(bookmark)
        }
        guard let importID = try? modelContext.fetch(HomeQueries.playlist(uuid: playlistID)).first?.currentImportID,
              let series = try? modelContext.fetch(SeriesQueries.series(importID: importID, key: key)).first else {
            return nil
        }
        return SeriesItem(series)
    }
}
#endif
