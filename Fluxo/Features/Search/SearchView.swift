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
            kind?.title ?? "All"
        }
    }

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""
    @Environment(\.modelContext) private var modelContext
    /// The search text and the navigation path.
    @Environment(AppNavigation.self) private var navigation

    @State private var scope = Scope.all
    @State private var results: ChannelSearch.Results?

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
                .task(id: libraryScope.importIDs) {
                    // Reads the names once, so the first search is as fast as the next ones.
                    await ChannelSearchIndex.shared.prewarm(importIDs: libraryScope.importIDs, container: modelContext.container)
                }
                .channelDestinations()
        }
    }

    @ViewBuilder
    private func content(request: ChannelSearch.Request, libraryScope: LibraryScope) -> some View {
        if playlists.isEmpty {
            ContentUnavailableView("No Playlists", systemImage: "magnifyingglass", description: Text("Add a playlist on the Home screen to search its channels."))
        } else if request.term.isEmpty {
            ContentUnavailableView {
                Label("Search Your Playlists", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Searching \(scopeDescription(libraryScope)).")
            }
        } else if let results {
            // While the next query runs, the previous results stay on screen instead of a spinner.
            if results.channels.isEmpty && results.groups.isEmpty {
                ContentUnavailableView.search(text: results.request.term)
            } else {
                SearchResultsList(results: results, libraryScope: libraryScope)
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

    private func scopeDescription(_ libraryScope: LibraryScope) -> String {
        if case .playlist = libraryScope.selection, let name = libraryScope.playlistNames.values.first {
            return "\"\(name)\""
        }
        return playlists.count == 1 ? "your playlist" : "all \(playlists.count) playlists"
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
}

/// The background search itself.
enum ChannelSearch {

    static let channelLimit = 150
    static let groupLimit = 20

    struct Request: Hashable, Sendable {
        let term: String
        let importIDs: [UUID]
        let kind: ChannelContentKind?
    }

    struct Results: Sendable {
        let request: Request
        let channels: [ChannelItem]
        let groups: [GroupItem]

        var isTruncated: Bool {
            channels.count >= ChannelSearch.channelLimit
        }
    }

    /// Token search over the in-memory index (see `ChannelSearchIndex` and `SearchMatcher`): every word of
    /// the query must match a word of the name, in any order, with typos allowed for longer words; the best
    /// matches come first.
    static func run(_ request: Request, container: ModelContainer) async -> Results {
        let hits = await ChannelSearchIndex.shared.search(
            request.term,
            importIDs: request.importIDs,
            kind: request.kind,
            channelLimit: channelLimit,
            groupLimit: groupLimit,
            container: container
        )
        return await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let channels = ChannelSearchIndex.channels(for: hits.channels, in: context).map(ChannelItem.init)
            let groups = ChannelSearchIndex.groups(for: hits.groups, in: context).map(GroupItem.init)
            return Results(request: request, channels: channels, groups: groups)
        }.value
    }
}

private struct SearchResultsList: View {

    let results: ChannelSearch.Results
    let libraryScope: LibraryScope

    private func subtitle(for item: ChannelItem) -> String {
        let playlistName = libraryScope.showsPlaylistNames ? libraryScope.playlistNames[item.playlistID] : nil
        return [item.kind.title, item.groupName.isEmpty ? nil : item.groupName, playlistName].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        List {
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
