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

/// A recording: the channel's logo (a tile with its initials for recordings made before the logo was kept), its
/// title, when it was made and how long it is. Selecting it plays it; the long-press menu deletes it. One that is
/// still written (Picture in Picture records) or converted shows it over its artwork and cannot be played yet.
private struct TVRecordingCard: View {
    let recording: Recording
    let player: AVPlayerViewModel

    @State private var confirmsDelete = false

    var body: some View {
        let isBusy = recording.isRecording || recording.isFinalizing
        let date = recording.createdOn.formatted(.dateTime.day().month().hour().minute())
        TVCard(
            size: TVLayout.landscapeCard,
            action: .perform { player.playRecording(recording) },
            focusName: recording.title,
            accessibilityLabel: Text(TextParts.spoken([recording.title, recording.createdOn.formatted(date: .abbreviated, time: .shortened), recording.duration.map(PlayerTime.spoken), state])),
            accessibilityHint: isBusy ? nil : Text(TVText.playsRecordingHint)
        ) {
            TVLandscapeArtworkView(logo: recording.logo, name: recording.title, kind: .live)
                .overlay(alignment: .topLeading) {
                    if let state {
                        HStack(spacing: 10) {
                            if recording.isRecording {
                                Image(systemName: "record.circle.fill")
                                    .foregroundStyle(Theme.recording)
                                    .ambientSymbolEffect(.pulse)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(state)
                        }
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: .capsule)
                        .foregroundStyle(.white)
                        .environment(\.colorScheme, .dark)
                        .padding(14)
                    }
                }
        } caption: { isFocused in
            TVCardCaption(
                title: recording.title,
                subtitle: TextParts.line([date, recording.duration.map(Self.duration)]),
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

    /// "Recording" while the engine writes it, "Saving…" while it is converted; nil once it can be played.
    private var state: String? {
        if recording.isRecording {
            return String(localized: "TV.recording.inProgress", defaultValue: "Recording", comment: "Apple TV Library: a recording the engine is still writing (the channel is being recorded now, in Picture in Picture).")
        }
        if recording.isFinalizing {
            return String(localized: "TV.recording.saving", defaultValue: "Saving…", comment: "Apple TV Library: a recording that just stopped and is being saved (converted to a file that can be played).")
        }
        return nil
    }

    /// "45 sec" under a minute, "12 min" or "1 hr, 5 min" after (never "0 min").
    static func duration(_ seconds: TimeInterval) -> String {
        let duration = Duration.seconds(max(0, seconds.rounded()))
        if seconds < 59.5 {
            return duration.formatted(.units(allowed: [.seconds], width: .abbreviated))
        }
        return duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
#endif
