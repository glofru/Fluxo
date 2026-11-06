//
//  TVSearchScreen.swift
//  Fluxo
//
//  The Search tab of Apple TV: the system search field (the tvOS keyboard, and dictation from the Siri Remote's
//  microphone or the Continuity Keyboard of an iPhone) over the results as shelves: live channels, movies, series
//  and the programmes of the TV guide. The app's token search (`ChannelSearchIndex`: typos allowed, best matches
//  first). Before anything is typed, the favorites and what was watched last are suggested.
//
//  What is said to the Siri Remote is a sentence more often than a name: "football tonight", "italian news
//  channels", "films tomorrow". Such a search (two or more words with a time, a kind, a country or "like …", or one
//  the name search finds nothing for) also gets Smart Results first: the words as understood (chips in the shelf's
//  title: the words said, not the synonyms searched with them) and the programmes, channels, series and categories
//  they match (a series opens its page), from the rules of `SmartSearch` (Apple TV has no on-device model; the same
//  rules back up the model on iPhone). They join the regular results when ready. Search in Fluxo (Siri) types its
//  words in here too.
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
        /// Smart Results (`SmartSearch`): how the words were understood ("Football", "Tonight"), and what matches.
        var smartChips: [String] = []
        var smartProgrammes: [GuideSearchResult] = []
        var smartChannels: [ChannelItem] = []
        var smartGroups: [GroupItem] = []
        /// The name search found nothing, and Smart Results are still being looked for.
        var isPending = false

        var isEmpty: Bool {
            channels.isEmpty && movies.isEmpty && series.isEmpty && programmes.isEmpty && !hasSmartResults
        }

        var hasSmartResults: Bool {
            !smartProgrammes.isEmpty || !smartChannels.isEmpty || !smartGroups.isEmpty
        }

        var count: Int {
            channels.count + movies.count + series.count + programmes.count + smartProgrammes.count + smartChannels.count + smartGroups.count
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
                    } else if results.term == typed, results.isPending {
                        TVSearchPending(term: typed)
                    } else if results.term == typed, results.isEmpty {
                        TVEmptyState(
                            title: String(localized: "TV.search.noResults", defaultValue: "No Results for “\(typed)”", comment: "Apple TV Search: nothing matches what was typed; the placeholder is the text."),
                            message: String(localized: "TV.search.noResults.message", defaultValue: "Check the spelling, or search for a channel, a movie, a series or a programme.", comment: "Apple TV Search: what to try when nothing matches."),
                            systemImage: "magnifyingglass"
                        )
                    } else {
                        if results.hasSmartResults {
                            smartShelves
                        }
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
            var found = Results(term: text, channels: await channels, movies: await movies, series: await series, programmes: programmes)
            guard !Task.isCancelled else {
                return
            }
            let wantsSmartResults = SmartSearch.shouldRun(for: text, regularResultCount: found.channels.count + found.movies.count + found.series.count)
            // The regular results show at once, as on iPhone; Smart Results join them when their plan has run (it
            // searches each keyword, so it takes longer on a large library). A search the name search finds
            // nothing for waits for them, rather than saying "No Results" first.
            if !wantsSmartResults || !found.isEmpty {
                results = found
            } else {
                // Not the shelves of the words searched before (still focusable) meanwhile.
                results = Results(term: text, isPending: true)
            }
            if wantsSmartResults {
                await addSmartResults(to: &found, importIDs: importIDs, container: container)
                guard !Task.isCancelled else {
                    return
                }
                results = found
            }
            AccessibilityAnnouncer.announce(found.isEmpty ? String(localized: "No results") : String(localized: "TV.search.found", defaultValue: "\(found.count) results", comment: "VoiceOver announcement on Apple TV when search results arrive; the placeholder is how many."))
        }
    }

    /// Plans the sentence with the rules of `SmartSearch` and runs the plan. What Smart Results show leaves the
    /// regular shelves, so nothing is listed twice.
    private func addSmartResults(to found: inout Results, importIDs: [UUID], container: ModelContainer) async {
        let plan = await SmartSearch.plan(for: found.term, useModel: false)
        guard !plan.isEmpty, !Task.isCancelled else {
            return
        }
        let smart = await SmartSearch.run(plan, query: found.term, importIDs: importIDs, container: container, epg: epg, includeGuide: epg.hasGuide)
        guard !smart.isEmpty else {
            return
        }
        found.smartChips = Self.chips(of: plan, query: found.term)
        found.smartProgrammes = Array(smart.programmes.prefix(Self.smartProgrammeLimit))
        found.smartChannels = Array(smart.channels.prefix(Self.smartChannelLimit))
        found.smartGroups = smart.groups
        let programmeIDs = Set(found.smartProgrammes.map(\.id))
        let channelIDs = Set(found.smartChannels.map(\.id))
        // A series is in Smart Results as one of its episodes (`SmartSearch` keeps one per series), shown as the
        // series' card.
        let seriesIDs = Set(found.smartChannels.compactMap { $0.seriesItem?.id })
        found.programmes.removeAll { programmeIDs.contains($0.id) }
        found.channels.removeAll { channelIDs.contains($0.id) }
        found.movies.removeAll { channelIDs.contains($0.id) }
        found.series.removeAll { seriesIDs.contains($0.id) }
    }

    /// The chips of the Smart Results title: the viewer's own words, with the time, kind, country or "like …" as
    /// understood. Not the synonyms and translations the rules search as well ("Soccer", "Calcio" for "football"):
    /// on a shelf title read from the sofa they are noise. When every keyword is one the rules made (a word said
    /// differently), the first one stands for them.
    private static func chips(of plan: SmartSearchPlan, query: String) -> [String] {
        let said = Set(SmartSearchRules.words(query))
        var shown = plan
        shown.keywords = plan.keywords.filter { keyword in
            let words = SmartSearchRules.words(keyword)
            return !words.isEmpty && words.allSatisfy(said.contains)
        }
        if shown.keywords.isEmpty {
            shown.keywords = Array(plan.keywords.prefix(1))
        }
        return shown.summaryChips
    }

    private static let smartProgrammeLimit = 20
    private static let smartChannelLimit = 20

    /// Smart Results: the programmes, then the channels, in one shelf titled with the words as understood; the
    /// categories after it, as tiles.
    @ViewBuilder
    private var smartShelves: some View {
        let understood = results.smartChips.joined(separator: " · ")
        if !results.smartProgrammes.isEmpty || !results.smartChannels.isEmpty {
            TVShelf(title: String(localized: "Smart Results"), subtitle: understood.isEmpty ? nil : understood, systemImage: "sparkles") {
                ForEach(results.smartProgrammes) { result in
                    TVProgrammeResultCard(result: result) {
                        selection = GuideSelection(programme: result.programme, channel: GuideChannel(item: result.channel, ref: result.ref))
                    }
                }
                // An episode stands for its series here (`SmartSearch` keeps one per series, whichever matched): its
                // card opens the series page, as the iPhone's row does, rather than playing that episode.
                ForEach(results.smartChannels) { item in
                    TVChannelCard(item: item, opensSeries: true)
                }
            }
        }
        if !results.smartGroups.isEmpty {
            TVShelf(title: String(localized: "Categories"), subtitle: results.smartProgrammes.isEmpty && results.smartChannels.isEmpty ? understood.nilIfEmpty : nil, systemImage: "square.grid.2x2") {
                ForEach(results.smartGroups) { group in
                    TVCategoryTile(group: group)
                }
            }
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

/// Smart Results are being looked for, and the name search found nothing: says so where the shelves will be.
private struct TVSearchPending: View {
    let term: String

    var body: some View {
        VStack(spacing: 28) {
            ProgressView()
                .controlSize(.large)
            Text(String(localized: "TV.search.pending", defaultValue: "Searching for “\(term)”…", comment: "Apple TV Search: Smart Results are being looked for (the name search found nothing yet); the placeholder is the text."))
                .font(.title3)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(TVLayout.margin)
        .frame(maxWidth: .infinity, minHeight: 640)
        .accessibilityElement(children: .combine)
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
