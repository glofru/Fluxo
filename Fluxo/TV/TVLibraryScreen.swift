//
//  TVLibraryScreen.swift
//  Fluxo
//
//  The Library tab of Apple TV: what the user keeps, as shelves: Continue Watching, the favorite channels and
//  movies, the favorite series, Recently Watched and the recordings. Favorites and Recently Watched end with a See
//  All card (the full grid, the history by day), pushed on the tab's own path (`AppNavigation.libraryPath`, which
//  App Intents and the debug routes set).
//

#if os(tvOS)
import SwiftData
import SwiftUI

struct TVLibraryScreen: View {

    let player: AVPlayerViewModel

    @Query(HomeQueries.favorites(playlistIDs: nil, limit: 40)) private var favorites: [ChannelBookmark]
    @Query(SeriesQueries.favorites(playlistIDs: nil, limit: 40)) private var favoriteSeries: [SeriesBookmark]
    @Query(HomeQueries.recents(playlistIDs: nil, limit: 40)) private var recents: [ChannelBookmark]
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        let recordings = player.recordings.recordings
        NavigationStack(path: $navigation.libraryPath) {
            Group {
                if favorites.isEmpty, favoriteSeries.isEmpty, recents.isEmpty, recordings.isEmpty {
                    TVEmptyState(
                        title: String(localized: LibraryText.title),
                        message: String(localized: "TV.library.empty", defaultValue: "Your favorites, what you watched and your recordings show here.", comment: "Apple TV Library, when it is empty."),
                        systemImage: "rectangle.stack"
                    )
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: TVLayout.shelfSpacing) {
                            TVContinueWatchingShelf(playlistIDs: nil)
                            if !favorites.isEmpty {
                                TVShelf(title: String(localized: "Favorites"), systemImage: "star.fill") {
                                    ForEach(favorites) { bookmark in
                                        TVChannelCard(item: ChannelItem(bookmark))
                                    }
                                    TVSeeAllCard(route: .favorites(playlistIDs: nil), focusName: "see-all-favorites")
                                }
                            }
                            if !favoriteSeries.isEmpty {
                                TVShelf(title: String(localized: "TV.library.favoriteSeries", defaultValue: "Favorite Series", comment: "Apple TV Library: the shelf of the favorite series."), systemImage: "square.stack.fill") {
                                    ForEach(favoriteSeries) { bookmark in
                                        TVSeriesCard(series: SeriesItem(bookmark))
                                    }
                                }
                            }
                            if !recents.isEmpty {
                                TVShelf(title: String(localized: "Recently Watched"), systemImage: "clock") {
                                    ForEach(recents) { bookmark in
                                        TVChannelCard(item: ChannelItem(bookmark), subtitle: bookmark.lastWatchedAt.map { $0.formatted(.relative(presentation: .named)) })
                                    }
                                    TVSeeAllCard(route: .history(playlistIDs: nil), focusName: "see-all-history")
                                }
                            }
                            if !recordings.isEmpty {
                                TVShelf(title: String(localized: "Recordings"), subtitle: recordings.count.formatted(), systemImage: "record.circle") {
                                    ForEach(recordings) { recording in
                                        TVRecordingCard(recording: recording, player: player)
                                    }
                                }
                            }
                        }
                        .padding(.top, TVLayout.tabBarClearance)
                        .padding(.bottom, TVLayout.verticalMargin)
                    }
                    .scrollClipDisabled()
                    .ignoresSafeArea()
                }
            }
            .tvDestinations()
        }
        .onAppear {
            player.recordings.reload()
        }
    }
}

/// A recording: the channel's logo, its title, when it was made and how long it is. Selecting it plays it; the
/// long-press menu deletes it.
private struct TVRecordingCard: View {
    let recording: Recording
    let player: AVPlayerViewModel

    @State private var confirmsDelete = false

    var body: some View {
        let isBusy = recording.isRecording || recording.isFinalizing
        TVCard(
            size: TVLayout.landscapeCard,
            action: .perform { player.playRecording(recording) },
            focusName: recording.title,
            accessibilityLabel: Text(TextParts.spoken([recording.title, recording.createdOn.formatted(date: .abbreviated, time: .shortened), isBusy ? String(localized: "Recording") : nil])),
            accessibilityHint: Text(TVText.playsHint)
        ) {
            ZStack {
                Theme.tileBackground
                Image(systemName: isBusy ? "record.circle.fill" : "play.rectangle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Theme.recording)
                    .symbolEffect(.pulse, isActive: isBusy)
            }
        } caption: { isFocused in
            TVCardCaption(
                title: recording.title,
                subtitle: TextParts.line([recording.createdOn.formatted(.dateTime.day().month().hour().minute()), recording.duration.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) }]),
                isFocused: isFocused
            )
        } menu: {
            Button(role: .destructive) {
                confirmsDelete = true
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
            .disabled(isBusy)
        }
        .disabled(isBusy)
        .confirmationDialog(String(localized: "TV.recording.delete", defaultValue: "Delete this recording?", comment: "Apple TV Library: confirmation before deleting a recording."), isPresented: $confirmsDelete) {
            Button(String(localized: "Delete"), role: .destructive) {
                player.recordings.delete(recording)
            }
        } message: {
            Text(recording.title)
        }
    }
}
#endif
