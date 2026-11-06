//
//  TopShelfLinks.swift
//  Fluxo
//
//  Opens the fluxo:// links of the Top Shelf items (`TopShelfLink`): plays a channel, movie or episode, plays a
//  series where the viewer left off, or opens a series page on Home. Links arrive at launch or while the app runs,
//  over whatever it shows: the player switches to the new item, a series page is pushed on Home.
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
    @State private var isUnavailable = false

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                guard let link = TopShelfLink(url: url) else {
                    return
                }
                Task {
                    await open(link)
                }
            }
            .alert(
                String(localized: "TopShelf.unavailable.title", defaultValue: "Not Available", comment: "Title of the alert shown when an item of the Apple TV Top Shelf is opened but is no longer in the user's playlists."),
                isPresented: $isUnavailable
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(String(localized: "TopShelf.unavailable.message", defaultValue: "It's no longer in your playlists.", comment: "Message of the alert shown when an item of the Apple TV Top Shelf (a channel, movie, episode or series) is opened but its playlist no longer lists it."))
            }
    }

    private func open(_ link: TopShelfLink) async {
        let container = modelContext.container
        switch link {
        case .playChannel(let id):
            let item = await Task.detached(priority: .userInitiated) {
                ChannelEntityID.key(for: id, in: container).flatMap { LibraryLookup.channel(forKey: $0, in: container) }
            }.value
            guard let item else {
                isUnavailable = true
                return
            }
            playChannel(item)
        case .playSeries(let playlistID, let key, let title):
            guard let series = series(playlistID: playlistID, key: key, title: title) else {
                isUnavailable = true
                return
            }
            await SeriesPlayback.play(series, library: library, container: container, playChannel: playChannel)
        case .openSeries(let playlistID, let key, let title):
            guard let series = series(playlistID: playlistID, key: key, title: title) else {
                isUnavailable = true
                return
            }
            if player.isPresented {
                player.closePlayer()
            }
            navigation.show(.home)
            navigation.pushOnHome(series.route)
        }
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
