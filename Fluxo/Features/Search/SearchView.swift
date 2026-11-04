//
//  SearchView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// Searches channels and groups by name across every playlist or the selected one.
///
/// The query runs 250 ms after the last keystroke, on a background context, with a fetch limit; results are
/// `ChannelItem` / `GroupItem` values, so typing never blocks the main thread and no models are kept alive.
struct SearchView: View {

    enum Scope: Hashable, CaseIterable {
        case all
        case live
        case movies
        case series

        var kind: ChannelContentKind? {
            switch self {
            case .all:
                return nil
            case .live:
                return .live
            case .movies:
                return .movie
            case .series:
                return .series
            }
        }

        var title: String {
            kind?.segmentTitle ?? String(localized: "All", comment: "Search scope: every content type (live TV, movies and series).")
        }
    }

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""
    @Environment(\.modelContext) private var modelContext
    /// The search text and the navigation path.
    @Environment(AppNavigation.self) private var navigation

    @State private var scope = Scope.all
    @State private var results: ChannelSearch.Results?
    /// Natural-language results ("football tonight"), for queries of two or more words.
    @State private var smartResults: SmartSearchResults?
    @State private var isSmartSearching = false
    /// A sentence waits for smart search (its debounce): "No Results" would be premature.
    @State private var isSmartPending = false
    @State private var selectedProgramme: GuideSearchResult?

    @Environment(EPGStore.self) private var epg
    @Environment(FluxoIntelligence.self) private var intelligence: FluxoIntelligence?
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled

    private var libraryScope: LibraryScope {
        LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
    }

    var body: some View {
        let libraryScope = libraryScope
        let request = ChannelSearch.Request(term: navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines), importIDs: libraryScope.importIDs, kind: scope.kind)
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.searchPath) {
            content(request: request, libraryScope: libraryScope)
                .navigationTitle("Search")
                .searchable(text: $navigation.searchText, prompt: "Channels, movies and series")
                .searchScopes($scope, activation: .onSearchPresentation) {
                    ForEach(Scope.allCases, id: \.self) { scope in
                        Text(scope.title)
                            .tag(scope)
                    }
                }
                .toolbar {
                    if playlists.count > 1 {
                        ToolbarItem {
                            playlistPicker(libraryScope: libraryScope)
                        }
                    }
                }
                .task(id: request) {
                    await run(request)
                }
                .task(id: results?.request) {
                    // VoiceOver hears how many results a query found, once typing pauses (the results only
                    // replace what the list shows, the focus stays in the search field).
                    guard isVoiceOverEnabled, let results, !results.request.term.isEmpty else {
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else {
                        return
                    }
                    let count = results.channels.count
                    let announcement: String
                    if count == 0 && results.groups.isEmpty && results.series.isEmpty {
                        announcement = String(localized: "No results")
                    } else if results.series.isEmpty {
                        announcement = String(localized: "\(count) channels, \(results.groups.count) categories")
                    } else {
                        announcement = String(localized: "\(results.series.count) series, \(count) channels, \(results.groups.count) categories", comment: "VoiceOver: how many results a search found.")
                    }
                    AccessibilityAnnouncer.announce(announcement, priority: .low)
                }
                .task(id: SmartSearchKey(request: request, usesModel: intelligence?.isAvailable ?? false)) {
                    await runSmartSearch(request)
                }
                .task(id: libraryScope.importIDs) {
                    // Reads the names once, so the first search is as fast as the next ones.
                    await ChannelSearchIndex.shared.prewarm(importIDs: libraryScope.importIDs, container: modelContext.container)
                }
                .channelDestinations()
        }
        .sheet(item: $selectedProgramme) { selection in
            ProgrammeDetailView(programme: selection.programme, channel: selection.channel, ref: selection.ref)
        }
    }

    private struct SmartSearchKey: Hashable {
        let request: ChannelSearch.Request
        let usesModel: Bool
    }

    @ViewBuilder
    private func content(request: ChannelSearch.Request, libraryScope: LibraryScope) -> some View {
        if playlists.isEmpty {
            ContentUnavailableView("No Playlists", systemImage: "magnifyingglass", description: Text("Add a playlist on the Home screen to search its channels."))
        } else if request.term.isEmpty {
            ContentUnavailableView {
                Label("Search Your Playlists", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text(scopeDescription(libraryScope))
            }
        } else if let results {
            // While the next query runs, the previous results stay on screen instead of a spinner.
            let smart = smartResults?.query == request.term ? smartResults : nil
            let hasRegular = !results.channels.isEmpty || !results.groups.isEmpty || !results.series.isEmpty
            if !hasRegular && (smart?.isEmpty ?? true) && !isSmartSearching && !isSmartPending {
                ContentUnavailableView.search(text: results.request.term)
            } else {
                // Without regular results, the smart loading row shows from the first keystroke of a sentence.
                let isSmartLoading = isSmartSearching || (!hasRegular && isSmartPending)
                SearchResultsList(results: results, smart: smart, isSmartSearching: isSmartLoading, libraryScope: libraryScope) { programme in
                    selectedProgramme = programme
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func playlistPicker(libraryScope: LibraryScope) -> some View {
        Menu {
            Picker("Search In", selection: Binding(get: { libraryScope.selection }, set: { selectionRawValue = $0.rawValue })) {
                Text("All Playlists")
                    .tag(PlaylistSelection.all)
                ForEach(playlists) { playlist in
                    Text(playlist.name)
                        .tag(PlaylistSelection.playlist(playlist.uuid))
                }
            }
        } label: {
            Label("Search In", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    /// "Searching “Freeview”.", "Searching your playlist.", "Searching all 3 playlists."
    private func scopeDescription(_ libraryScope: LibraryScope) -> String {
        if case .playlist = libraryScope.selection, let name = libraryScope.playlistNames.values.first {
            return String(localized: "Searching “\(name)”.", comment: "Search screen: the search covers one playlist; the placeholder is its name.")
        }
        if playlists.count == 1 {
            return String(localized: "Searching your playlist.", comment: "Search screen: the search covers the only playlist.")
        }
        return String(localized: "Searching all \(playlists.count) playlists.", comment: "Search screen: the search covers every playlist; the number is how many.")
    }

    private func run(_ request: ChannelSearch.Request) async {
        guard !request.term.isEmpty, !request.importIDs.isEmpty else {
            results = nil
            return
        }
        // Debounce: a new keystroke cancels this task before the query starts.
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
        let container = modelContext.container
        let found = await ChannelSearch.run(request, container: container)
        guard !Task.isCancelled else {
            return
        }
        results = found
    }

    /// Plans the query (with the on-device model when Apple Intelligence is available, else with rules) and runs
    /// the plan. Waits longer than the regular search: planning costs more than a keystroke.
    private func runSmartSearch(_ request: ChannelSearch.Request) async {
        // A run cancelled while waiting or planning (the viewer kept typing) leaves its flag set: every run starts
        // clean and sets each flag only right before its step, so no early return below can leave the loading row
        // on screen.
        isSmartSearching = false
        isSmartPending = false
        guard SmartSearch.isNaturalLanguage(request.term), !request.importIDs.isEmpty else {
            smartResults = nil
            return
        }
        isSmartPending = true
        do {
            try await Task.sleep(for: .milliseconds(600))
        } catch {
            return
        }
        isSmartPending = false
        // The regular results are usually in by now (they run after 250 ms).
        let regular = results?.request == request ? (results?.channels.count ?? 0) + (results?.groups.count ?? 0) + (results?.series.count ?? 0) : nil
        guard SmartSearch.shouldRun(for: request.term, regularResultCount: regular) else {
            smartResults = nil
            return
        }
        isSmartSearching = true
        defer {
            if !Task.isCancelled {
                isSmartSearching = false
            }
        }
        var plan = await SmartSearch.plan(for: request.term, useModel: intelligence?.isAvailable ?? false)
        if plan.kind == .any, let kind = request.kind {
            // The search scope picked in the bar wins.
            plan.kind = SmartSearchPlan.Kind(kind)
        }
        guard !Task.isCancelled, !plan.isEmpty else {
            return
        }
        let found = await SmartSearch.run(plan, query: request.term, importIDs: request.importIDs, container: modelContext.container, epg: epg)
        guard !Task.isCancelled else {
            return
        }
        smartResults = found
    }
}

/// The background search itself.
enum ChannelSearch {

    static let channelLimit = 150
    static let groupLimit = 20
    static let seriesLimit = 40

    struct Request: Hashable, Sendable {
        let term: String
        let importIDs: [UUID]
        let kind: ChannelContentKind?
    }

    struct Results: Sendable {
        let request: Request
        let channels: [ChannelItem]
        let groups: [GroupItem]
        /// Series, each once with its counts (their episodes are not listed as channels).
        var series: [SeriesItem] = []

        var isTruncated: Bool {
            channels.count >= ChannelSearch.channelLimit
        }
    }

    /// Token search over the in-memory index (see `ChannelSearchIndex` and `SearchMatcher`): every word of
    /// the query must match a word of the name, in any order, with typos allowed for longer words; the best
    /// matches come first.
    static func run(_ request: Request, container: ModelContainer) async -> Results {
        let hits = await ChannelSearchIndex.shared.searchCollapsingSeries(
            request.term,
            importIDs: request.importIDs,
            kind: request.kind,
            channelLimit: channelLimit,
            groupLimit: groupLimit,
            seriesLimit: seriesLimit,
            container: container
        )
        return await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let channels = ChannelSearchIndex.channels(for: hits.channels, in: context).map(ChannelItem.init)
            let groups = ChannelSearchIndex.groups(for: hits.groups, in: context).map(GroupItem.init)
            let series = SeriesQueries.series(for: hits.series, in: context).map(SeriesItem.init)
            return Results(request: request, channels: channels, groups: groups, series: series)
        }.value
    }
}

private struct SearchResultsList: View {

    let results: ChannelSearch.Results
    let smart: SmartSearchResults?
    let isSmartSearching: Bool
    let libraryScope: LibraryScope
    let onSelectProgramme: (GuideSearchResult) -> Void

    #if os(iOS)
    /// On iPhone the floating scope bar under the search field (shown whenever there are results, i.e. a search
    /// term) covers the top of the list without adding to its safe area, so the first section header (Smart
    /// Results, Categories) was hidden behind it. iPad puts the field in the toolbar and needs nothing.
    static let scopeBarClearance: CGFloat = 44
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private func subtitle(for item: ChannelItem) -> String {
        let playlistName = libraryScope.showsPlaylistNames ? libraryScope.playlistNames[item.playlistID] : nil
        return TextParts.line([item.kind.title, item.groupName, playlistName])
    }

    private func seriesSubtitle(for series: SeriesItem) -> String? {
        let playlistName = libraryScope.showsPlaylistNames ? libraryScope.playlistNames[series.playlistID] : nil
        return TextParts.line([series.groupName, playlistName]).nilIfEmpty
    }

    var body: some View {
        list
            #if os(iOS)
            .contentMargins(.top, horizontalSizeClass == .compact ? Self.scopeBarClearance : 0, for: .scrollContent)
            #endif
    }

    private var list: some View {
        List {
            SmartSearchSections(results: smart, isLoading: isSmartSearching, libraryScope: libraryScope, onSelectProgramme: onSelectProgramme)

            if !results.groups.isEmpty {
                Section("Categories") {
                    CardRow {
                        ForEach(results.groups) { group in
                            CategoryCard(group: group, playlistName: libraryScope.showsPlaylistNames ? libraryScope.playlistNames[group.playlistID] : nil)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            if !results.series.isEmpty {
                Section("Series") {
                    ForEach(results.series) { series in
                        SeriesListRow(series: series, subtitle: seriesSubtitle(for: series))
                    }
                }
            }

            if !results.channels.isEmpty {
                Section {
                    ForEach(results.channels) { item in
                        ChannelListRow(item: item, subtitle: subtitle(for: item), showsNumber: false)
                    }
                } header: {
                    Text("Channels")
                } footer: {
                    if results.isTruncated {
                        Text("Showing the first \(ChannelSearch.channelLimit) matches. Type more to narrow the search.")
                    }
                }
            }
        }
    }
}

#Preview {
    SearchView()
        .fluxoPreviewEnvironment()
}
