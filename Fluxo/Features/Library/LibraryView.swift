//
//  LibraryView.swift
//  Fluxo
//
//  The Library tab (iPhone and iPad, in the tab bar and the sidebar alike): what the user keeps. The first section
//  links to Favorites and Recently Watched (both also on Home, as rows with See All), then come the recordings,
//  listed in place, so they are one tap from every screen instead of behind a Home toolbar button or the player's
//  menu.
//
//  The macOS sidebar has no tabs: it lists the same places as separate entries of a Library section (see
//  `MacRootView`).
//
//  Layout: one `Section` per kind of saved content, each its own view, in this order:
//    1. `LibraryShortcutsSection` (Favorites, Recently Watched),
//    2. `LibraryDownloadsSections`, when there are downloads: the transfers in progress, then the downloaded
//       movies and series (content the user chose to keep comes before what was recorded live),
//    3. `LibraryRecordingsSection`.
//  The More menu of the toolbar acts on the recordings.
//

import SwiftData
import SwiftUI

/// Texts shared by the Library tab and the Library sections of the sidebars.
enum LibraryText {
    /// "Library": the tab and its title (iOS), and the sidebar section of the same places (iPad, macOS).
    static let title = LocalizedStringResource("Library", comment: "The place with the favorites, recently watched and recordings: a tab and its title, and a sidebar section.")
}

#if os(iOS)
struct LibraryView: View {

    let player: AVPlayerViewModel

    @State private var prompts = RecordingPrompts()

    var body: some View {
        let store = player.recordings
        List {
            LibraryShortcutsSection()

            // Offline downloads (the transfers in progress, then what is downloaded), before the recordings.
            LibraryDownloadsSections()

            LibraryRecordingsSection(store: store, isRecordingActive: player.isRecording, prompts: $prompts) { recording in
                player.playRecording(recording)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(LibraryText.title))
        .largeTitleAdaptingToTextSize()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RecordingsMoreMenu(store: store, isRecordingActive: player.isRecording, prompts: $prompts)
            }
        }
        .recordingPrompts($prompts, store: store) { recording in
            player.playRecording(recording)
        }
        .onAppear {
            store.reload()
        }
    }
}

/// Favorites (how many) and Recently Watched (the last thing watched), pushed on the Library's navigation stack.
/// Channels dragged onto the Favorites row become favorites, like on the Favorites entry of the iPad sidebar.
private struct LibraryShortcutsSection: View {

    @Query(LibraryShortcutsSection.favoritesDescriptor) private var favorites: [ChannelBookmark]
    /// Series kept as a whole (`SeriesBookmark`): the Favorites screen lists them in a section of their own.
    @Query(LibraryShortcutsSection.favoriteSeriesDescriptor) private var favoriteSeries: [SeriesBookmark]
    @Query(HomeQueries.recents(playlistIDs: nil, limit: 1)) private var recents: [ChannelBookmark]
    @Environment(ChannelLibrary.self) private var library
    @State private var isFavoritesDropTarget = false

    /// Every favorite: only counted, so no sort.
    private static var favoritesDescriptor: FetchDescriptor<ChannelBookmark> {
        FetchDescriptor<ChannelBookmark>(predicate: #Predicate { $0.isFavorite == true })
    }

    private static var favoriteSeriesDescriptor: FetchDescriptor<SeriesBookmark> {
        FetchDescriptor<SeriesBookmark>(predicate: #Predicate { $0.isFavorite == true })
    }

    /// Favorite channels, movies and episodes, and favorite series.
    private var favoritesCount: Int {
        favorites.count + favoriteSeries.count
    }

    /// The last thing watched: for an episode, its series.
    private var lastWatched: String? {
        recents.first.map { bookmark in
            let item = ChannelItem(bookmark)
            return item.series?.seriesTitle ?? item.displayName
        }
    }

    var body: some View {
        Section {
            NavigationLink(value: ChannelRoute.favorites(playlistIDs: nil)) {
                LabeledContent {
                    if favoritesCount > 0 {
                        Text(favoritesCount, format: .number)
                            .monospacedDigit()
                    }
                } label: {
                    LibraryRowLabel(
                        title: String(localized: "Favorites", comment: "Library tab: the row that opens the favorites."),
                        subtitle: favoritesCount == 0
                            ? String(localized: "Star a channel to keep it here.", comment: "Library tab: subtitle of the Favorites row when there are no favorites yet.")
                            : nil,
                        systemImage: "star.fill",
                        tint: Theme.favoriteFill
                    )
                }
            }
            .listRowBackground(isFavoritesDropTarget ? Theme.favorite.opacity(0.18) : nil)
            .favoritesDropDestination(library: library, isTargeted: $isFavoritesDropTarget)

            NavigationLink(value: ChannelRoute.history(playlistIDs: nil)) {
                LibraryRowLabel(
                    title: String(localized: "Recently Watched"),
                    subtitle: lastWatched,
                    systemImage: "clock.arrow.circlepath",
                    tint: Theme.accentFill
                )
            }
        }
    }
}

/// The recordings, in place: a tap plays one, a swipe shares or deletes it.
private struct LibraryRecordingsSection: View {
    let store: RecordingStore
    let isRecordingActive: Bool
    @Binding var prompts: RecordingPrompts
    let onPlay: (Recording) -> Void

    var body: some View {
        Section {
            if store.recordings.isEmpty {
                RecordingsEmptyState()
                    .listRowBackground(Color.clear)
            } else {
                RecordingRows(store: store, isRecordingActive: isRecordingActive, prompts: $prompts, onPlay: onPlay)
            }
        } header: {
            Text("Recordings")
        } footer: {
            if !store.recordings.isEmpty {
                RecordingsFooter(store: store)
            }
        }
    }
}

/// A row of the Library's first section: a tinted symbol tile, the title and an optional line under it. Not a
/// `Label`: at the accessibility text sizes a list row's label lets the title flow under the icon. There the tile
/// goes above the title, so the title has the row's whole width (beside the tile, "Favoriten" broke into
/// "Favo-riten").
private struct LibraryRowLabel: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let tint: Color

    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 30
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        AdaptiveStack(verticalAlignment: .center, spacing: dynamicTypeSize.prefersStackedLayout ? 8 : 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: tileSize, height: tileSize)
                .background(tint.gradient, in: .rect(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    NavigationStack {
        LibraryView(player: AVPlayerViewModel())
            .channelDestinations()
    }
    .fluxoPreviewEnvironment()
}
#endif
