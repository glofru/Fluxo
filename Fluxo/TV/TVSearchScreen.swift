//
//  TVSearchScreen.swift
//  Fluxo
//
//  The Search tab of Apple TV: the system search field (the tvOS keyboard, and dictation from the Siri Remote's
//  microphone or the Continuity Keyboard of an iPhone) over the results as shelves: live channels, movies, series
//  and the programmes of the TV guide. The app's token search (`ChannelSearchIndex`: typos allowed, best matches
//  first). Before anything is typed, the favorites and what was watched last are suggested.
//

#if os(tvOS)
import SwiftData
import SwiftUI

struct TVSearchScreen: View {

    @Environment(AppNavigation.self) private var navigation
    @Environment(\.modelContext) private var modelContext
    @Environment(EPGStore.self) private var epg
    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""
    @State private var results = Results()
    @State private var selection: GuideSelection?

    struct Results: Equatable {
        var term = ""
        var channels: [ChannelItem] = []
        var movies: [ChannelItem] = []
        var series: [SeriesItem] = []
        var programmes: [GuideSearchResult] = []

        var isEmpty: Bool {
            channels.isEmpty && movies.isEmpty && series.isEmpty && programmes.isEmpty
        }

        var seriesFirst: Bool {
            series.contains { $0.title.compare(term, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
    }

    private var scope: LibraryScope {
        LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
    }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.searchPath) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: TVLayout.shelfSpacing) {
                    let typed = navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if typed.isEmpty {
                        TVSearchSuggestions()
                    } else if results.term == typed, results.isEmpty {
                        TVEmptyState(
                            title: String(localized: "TV.search.noResults", defaultValue: "No Results for “\(typed)”", comment: "Apple TV Search: nothing matches what was typed; the placeholder is the text."),
                            message: String(localized: "TV.search.noResults.message", defaultValue: "Check the spelling, or search for a channel, a movie, a series or a programme.", comment: "Apple TV Search: what to try when nothing matches."),
                            systemImage: "magnifyingglass"
                        )
                    } else {
                        if !results.channels.isEmpty {
                            TVShelf(title: String(localized: "Live TV"), systemImage: "dot.radiowaves.left.and.right") {
                                ForEach(results.channels) { item in
                                    TVChannelCard(item: item)
                                }
                            }
                        }
                        if !results.programmes.isEmpty {
                            TVShelf(title: String(localized: "TV.search.programmes", defaultValue: "On the TV Guide", comment: "Apple TV Search: the shelf of the matching programmes of the TV guide."), systemImage: "calendar.day.timeline.left") {
                                ForEach(results.programmes) { result in
                                    TVProgrammeResultCard(result: result) {
                                        selection = GuideSelection(programme: result.programme, channel: GuideChannel(item: result.channel, ref: result.ref))
                                    }
                                }
                            }
                        }
                        // A series named exactly as typed comes before the movies that only contain the words.
                        if results.seriesFirst {
                            seriesShelf
                            moviesShelf
                        } else {
                            moviesShelf
                            seriesShelf
                        }
                    }
                }
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
            .ignoresSafeArea(edges: .horizontal)
            .tvDestinations()
        }
        .searchable(text: $navigation.searchText, prompt: Text("Channels, Movies and Series", comment: "Apple TV Search field: what can be searched."))
        .sheet(item: $selection) { selection in
            TVProgrammeScreen(programme: selection.programme, channel: selection.channel.item, ref: selection.channel.ref)
        }
        .task(id: SearchKey(text: navigation.searchText, importIDs: scope.importIDs)) {
            let text = navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                results = Results()
                return
            }
            // After the last letter of the on-screen keyboard.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else {
                return
            }
            let container = modelContext.container
            let importIDs = scope.importIDs
            async let channels = LibraryLookup.searchChannels(text, importIDs: importIDs, kind: .live, limit: 30, in: container)
            async let movies = LibraryLookup.searchChannels(text, importIDs: importIDs, kind: .movie, limit: 30, in: container)
            async let series = SeriesLookup.series(matching: text, importIDs: importIDs, limit: 30, in: container)
            let programmes = epg.hasGuide ? await epg.searchProgrammes(text, importIDs: importIDs, limit: 30) : []
            let found = Results(term: text, channels: await channels, movies: await movies, series: await series, programmes: programmes)
            guard !Task.isCancelled else {
                return
            }
            results = found
            AccessibilityAnnouncer.announce(found.isEmpty ? String(localized: "No results") : String(localized: "TV.search.found", defaultValue: "\(found.channels.count + found.movies.count + found.series.count + found.programmes.count) results", comment: "VoiceOver announcement on Apple TV when search results arrive; the placeholder is how many."))
        }
    }

    @ViewBuilder
    private var moviesShelf: some View {
        if !results.movies.isEmpty {
            TVShelf(title: ChannelContentKind.movie.title, systemImage: ChannelContentKind.movie.systemImage) {
                ForEach(results.movies) { item in
                    TVPosterCard(item: item)
                }
            }
        }
    }

    @ViewBuilder
    private var seriesShelf: some View {
        if !results.series.isEmpty {
            TVShelf(title: ChannelContentKind.series.title, systemImage: ChannelContentKind.series.systemImage) {
                ForEach(results.series) { series in
                    TVSeriesCard(series: series)
                }
            }
        }
    }

    private struct SearchKey: Hashable {
        let text: String
        let importIDs: [UUID]
    }
}

/// Before anything is typed: the favorites and the history, so the page is never empty.
private struct TVSearchSuggestions: View {
    @Query(HomeQueries.favorites(playlistIDs: nil, limit: 20)) private var favorites: [ChannelBookmark]
    @Query(HomeQueries.recents(playlistIDs: nil, limit: 20)) private var recents: [ChannelBookmark]

    var body: some View {
        if !recents.isEmpty {
            TVShelf(title: String(localized: "Recently Watched"), systemImage: "clock") {
                ForEach(recents) { bookmark in
                    TVChannelCard(item: ChannelItem(bookmark))
                }
            }
        }
        if !favorites.isEmpty {
            TVShelf(title: String(localized: "Favorites"), systemImage: "star.fill") {
                ForEach(favorites) { bookmark in
                    TVChannelCard(item: ChannelItem(bookmark))
                }
            }
        }
        if recents.isEmpty, favorites.isEmpty {
            TVEmptyState(
                title: String(localized: "TV.search.prompt", defaultValue: "Search Your Playlists", comment: "Apple TV Search, before anything is typed."),
                message: String(localized: "TV.search.prompt.message", defaultValue: "Type with the remote, or hold the microphone button on the Siri Remote and say what you are looking for.", comment: "Apple TV Search, before anything is typed: how to search (the keyboard, or dictation with the Siri Remote)."),
                systemImage: "magnifyingglass"
            )
        }
    }
}

/// A programme of the guide found by search: the channel's artwork, the title, the channel and when it airs.
private struct TVProgrammeResultCard: View {
    let result: GuideSearchResult
    let action: () -> Void

    var body: some View {
        TVCard(
            size: TVLayout.landscapeCard,
            action: .perform(action),
            focusName: result.programme.title,
            accessibilityLabel: Text(TextParts.spoken([result.programme.title, result.channel.displayName, GuideFormat.dayAndTime(result.programme)])),
            accessibilityHint: Text(String(localized: "TV.hint.programme", defaultValue: "Shows the programme", comment: "VoiceOver hint of a programme found by search on Apple TV."))
        ) {
            ZStack {
                TVLandscapeArtwork(item: result.channel)
                if let icon = result.programme.icon {
                    LogoImage(source: icon, size: TVLayout.landscapeCard, contentMode: .fill) { _ in
                        Color.clear
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if result.programme.isOnAir(at: .now) {
                    LiveBadge()
                        .padding(14)
                }
            }
        } caption: { isFocused in
            TVCardCaption(title: result.programme.title, subtitle: TextParts.line([result.channel.displayName, GuideFormat.dayAndTime(result.programme)]), isFocused: isFocused)
        }
    }
}
#endif
