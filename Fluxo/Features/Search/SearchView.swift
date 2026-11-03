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

    @State private var text = ""
    @State private var scope = Scope.all
    @State private var results: ChannelSearch.Results?

    private var libraryScope: LibraryScope {
        LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
    }

    var body: some View {
        let libraryScope = libraryScope
        let request = ChannelSearch.Request(term: text.trimmingCharacters(in: .whitespacesAndNewlines), importIDs: libraryScope.importIDs, kind: scope.kind)
        NavigationStack {
            content(request: request, libraryScope: libraryScope)
                .navigationTitle("Search")
                .searchable(text: $text, prompt: "Channels, movies and series")
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

    static func run(_ request: Request, container: ModelContainer) async -> Results {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let groups = (try? context.fetch(HomeQueries.searchGroups(term: request.term, importIDs: request.importIDs, kind: request.kind, limit: groupLimit))) ?? []
            let channels = (try? context.fetch(HomeQueries.searchChannels(term: request.term, importIDs: request.importIDs, kind: request.kind, limit: channelLimit))) ?? []
            return Results(request: request, channels: channels.map(ChannelItem.init), groups: groups.map(GroupItem.init))
        }.value
    }
}

private struct SearchResultsList: View {

    let results: ChannelSearch.Results
    let libraryScope: LibraryScope

    var body: some View {
        List {
            if !results.groups.isEmpty {
                Section("Categories") {
                    ScrollView(.horizontal) {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                ForEach(results.groups) { group in
                                    NavigationLink(value: group.route) {
                                        Label("\(group.displayName) · \(group.channelCount.formatted())", systemImage: group.kind.systemImage)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                    }
                                    .buttonStyle(.plain)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                                    .routeTransitionSource(group.route, cornerRadius: 20)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            if !results.channels.isEmpty {
                Section {
                    ForEach(results.channels) { item in
                        SearchResultRow(item: item, playlistName: libraryScope.showsPlaylistNames ? libraryScope.playlistNames[item.playlistID] : nil)
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

private struct SearchResultRow: View {

    static let logoSize = CGSize(width: 64, height: 40)

    let item: ChannelItem
    let playlistName: String?

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @State private var sourceID = UUID().uuidString

    var body: some View {
        let isFavorite = library.isFavorite(item)
        Button {
            playChannel(item, from: sourceID)
        } label: {
            HStack(spacing: 12) {
                LogoImage(source: item.logo, size: Self.logoSize, accessibilityLabel: item.displayName) { _ in
                    Image(systemName: item.kind.systemImage)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .background(Color.artworkPlaceholder.opacity(0.25), in: .rect(cornerRadius: 8))
                .clipShape(.rect(cornerRadius: 8))
                .playerTransitionSource(id: sourceID, cornerRadius: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text([item.kind.title, item.groupName.isEmpty ? nil : item.groupName, playlistName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Favorite")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ChannelContextMenu(item: item, isFavorite: isFavorite)
        }
        .swipeActions(edge: .trailing) {
            if item.url != nil {
                Button(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "star.slash" : "star") {
                    library.toggleFavorite(item)
                }
                .tint(.yellow)
            }
        }
    }
}

#Preview {
    SearchView()
        .fluxoPreviewEnvironment()
}
