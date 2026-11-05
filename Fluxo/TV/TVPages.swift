//
//  TVPages.swift
//  Fluxo
//
//  The pages of the Apple TV tab bar, first versions: each is wired to the shared feature it stands for (the
//  library's favorites and history, the playlists' groups, the token search, the TV guide's now and next, the
//  recordings, the playlist sheets), with the 10-foot layout of the system (shelves of focusable cards, plain lists).
//  The TV app's own Home, Guide, Search, Library and Settings replace them.
//

#if os(tvOS)
import SwiftData
import SwiftUI

// MARK: - Home

/// Continue Watching, Favorites, then the first live TV groups of every playlist.
struct TVHomeScreen: View {

    @Query(HomeQueries.recents(playlistIDs: nil, limit: 20)) private var recents: [ChannelBookmark]
    @Query(HomeQueries.favorites(playlistIDs: nil, limit: 40)) private var favorites: [ChannelBookmark]
    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: TVLayout.shelfSpacing) {
                    if playlists.isEmpty {
                        TVEmptyState(
                            title: String(localized: "No Playlists"),
                            message: String(localized: "TV.home.empty", defaultValue: "Add an M3U playlist in Settings to watch its channels here.", comment: "Apple TV Home, when there is no playlist yet."),
                            systemImage: "play.tv"
                        )
                    }
                    TVShelf(title: String(localized: "Continue Watching"), items: recents.map(ChannelItem.init))
                    TVShelf(title: String(localized: "Favorites"), items: favorites.map(ChannelItem.init))
                    ForEach(playlists) { playlist in
                        if let importID = playlist.currentImportID {
                            TVGroupShelves(importID: importID)
                        }
                    }
                }
            }
        }
    }
}

/// The first live TV groups of one import, a shelf each.
private struct TVGroupShelves: View {
    @Query private var groups: [PlaylistChannelGroup]

    init(importID: UUID) {
        _groups = Query(HomeQueries.groups(importIDs: [importID], kind: .live, limit: 8))
    }

    var body: some View {
        ForEach(groups) { group in
            TVGroupShelf(group: GroupItem(group))
        }
    }
}

private struct TVGroupShelf: View {
    let group: GroupItem
    @Query private var channels: [PlaylistChannel]

    init(group: GroupItem) {
        self.group = group
        _channels = Query(HomeQueries.channels(importID: group.importID, groupName: group.name, limit: 24))
    }

    var body: some View {
        TVShelf(title: ChannelCandidate.displayGroup(group.name), items: channels.map(ChannelItem.init))
    }
}

// MARK: - Guide

/// What is on now on the favorite and recently watched live channels, from the TV guide.
struct TVGuideScreen: View {

    @Query(HomeQueries.favorites(playlistIDs: nil, limit: 60)) private var favorites: [ChannelBookmark]
    @Query(HomeQueries.recents(playlistIDs: nil, limit: 40)) private var recents: [ChannelBookmark]
    @Query private var sources: [EPGSource]
    @Environment(EPGStore.self) private var epg

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if channels.isEmpty {
                        Text("Favorite or watch a live channel to see what it shows now.", comment: "Apple TV Guide, when no favorite or recently watched live channel exists yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(channels) { item in
                        TVOnNowRow(item: item)
                    }
                } header: {
                    Text("On Now")
                } footer: {
                    if sources.isEmpty {
                        Text("No TV guide source is set up yet.", comment: "Apple TV Guide footer when no TV guide source is set up.")
                    }
                }

                Section {
                    Button {
                        epg.refreshAll()
                    } label: {
                        Label(epg.isRefreshing ? String(localized: "Refreshing…") : String(localized: "Refresh"), systemImage: "arrow.clockwise")
                    }
                    .disabled(epg.isRefreshing || sources.isEmpty)
                }
            }
            .navigationTitle(Text("Guide"))
        }
    }

    /// Favorites first, then the history, live channels only, once each.
    private var channels: [ChannelItem] {
        var seen: Set<String> = []
        return (favorites + recents).map(ChannelItem.init).filter { item in
            item.kind == .live && seen.insert(item.bookmarkKey ?? item.id.uuidString).inserted
        }
    }
}

/// A live channel and its programme on now. Selecting it plays the channel.
private struct TVOnNowRow: View {
    let item: ChannelItem

    @Environment(\.playChannel) private var playChannel

    var body: some View {
        Button {
            playChannel(item)
        } label: {
            HStack(spacing: 32) {
                TVChannelArtwork(item: item)
                    .frame(width: 160, height: 90)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.displayName)
                        .font(.headline)
                    NowNextReader(item: item) { nowNext in
                        if let current = nowNext?.current {
                            Text(current.title)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .accessibilityHint(Text(TVText.playsHint))
    }
}

// MARK: - Search

/// The token search of the Search tab (typos allowed, best matches first), as a grid of cards.
struct TVSearchScreen: View {

    @Environment(AppNavigation.self) private var navigation
    @Environment(\.modelContext) private var modelContext
    @State private var results: [ChannelItem] = []
    @State private var searchedText = ""

    private let columns = [GridItem(.adaptive(minimum: TVLayout.cardSize.width), spacing: TVLayout.cardSpacing, alignment: .top)]

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack {
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: TVLayout.shelfSpacing) {
                    ForEach(results) { item in
                        TVChannelCard(item: item)
                    }
                }
                .padding(.vertical, 32)
                if results.isEmpty, !searchedText.isEmpty {
                    ContentUnavailableView.search(text: searchedText)
                }
            }
            .scrollClipDisabled()
        }
        .searchable(text: $navigation.searchText, prompt: Text("Channels, Movies and Series", comment: "Apple TV Search field: what can be searched."))
        .task(id: navigation.searchText) {
            let text = navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                results = []
                searchedText = ""
                return
            }
            // After the last keystroke of the on-screen keyboard.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            let container = modelContext.container
            let importIDs = LibraryLookup.visiblePlaylists(in: container).map(\.importID)
            let found = await LibraryLookup.searchChannels(text, importIDs: importIDs, limit: 60, in: container)
            guard !Task.isCancelled else {
                return
            }
            results = found
            searchedText = text
        }
    }
}

// MARK: - Library

/// Favorites, Recently Watched and the recordings.
struct TVLibraryScreen: View {

    let player: AVPlayerViewModel

    @Query(HomeQueries.favorites(playlistIDs: nil, limit: 60)) private var favorites: [ChannelBookmark]
    @Query(HomeQueries.recents(playlistIDs: nil, limit: 60)) private var recents: [ChannelBookmark]

    var body: some View {
        let recordings = player.recordings.recordings
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: TVLayout.shelfSpacing) {
                    if favorites.isEmpty, recents.isEmpty, recordings.isEmpty {
                        TVEmptyState(
                            title: String(localized: LibraryText.title),
                            message: String(localized: "TV.library.empty", defaultValue: "Your favorites, what you watched and your recordings show here.", comment: "Apple TV Library, when it is empty."),
                            systemImage: "rectangle.stack"
                        )
                    }
                    TVShelf(title: String(localized: "Favorites"), items: favorites.map(ChannelItem.init))
                    TVShelf(title: String(localized: "Recently Watched"), items: recents.map(ChannelItem.init))
                    TVShelf(title: String(localized: "Recordings"), items: recordings) { recording in
                        TVRecordingCard(recording: recording) {
                            player.playRecording(recording)
                        }
                    }
                }
            }
        }
        .onAppear {
            player.recordings.reload()
        }
    }
}

/// A recording: its title and date. Selecting it plays it.
private struct TVRecordingCard: View {
    let recording: Recording
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.recording)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .accessibilityHidden(true)
                Text(recording.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(recording.createdOn, format: .dateTime.day().month().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: TVLayout.cardSize.width, alignment: .leading)
        }
        .buttonStyle(.card)
        .disabled(recording.isRecording || recording.isFinalizing)
        .accessibilityHint(Text(TVText.playsHint))
    }
}

// MARK: - Settings

/// The playlists (add, refresh, edit, delete through the shared playlist sheets) and the app's version.
struct TVSettingsScreen: View {

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            TVPlaylistScreen(playlist: playlist)
                        } label: {
                            LabeledContent {
                                if importCenter.progress[playlist.uuid] != nil {
                                    ProgressView()
                                } else {
                                    Text("\(playlist.channelCount) channels", comment: "Apple TV Settings: how many channels a playlist has.")
                                }
                            } label: {
                                Text(playlist.name)
                            }
                        }
                    }
                    Button {
                        actions.add()
                    } label: {
                        Label(String(localized: "Add Playlist"), systemImage: "plus")
                    }
                } header: {
                    Text("Playlists")
                }

                Section {
                    LabeledContent(String(localized: "TV.settings.version", defaultValue: "Version", comment: "Apple TV Settings: the app's version number."), value: Self.version)
                }
            }
            .navigationTitle(Text("Settings"))
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// One playlist: refresh, edit, delete.
private struct TVPlaylistScreen: View {
    let playlist: Playlist

    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "TV.playlist.channels", defaultValue: "Channels", comment: "Apple TV, a playlist's page: label of its number of channels."), value: playlist.channelCount.formatted())
                if let refreshed = playlist.lastRefreshedOn {
                    LabeledContent(String(localized: "TV.playlist.updated", defaultValue: "Updated", comment: "Apple TV, a playlist's page: label of when it was last refreshed."), value: refreshed.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section {
                if importCenter.progress[playlist.uuid] != nil {
                    Button(String(localized: "Cancel Update"), systemImage: "xmark.circle") {
                        importCenter.cancelImport(for: playlist.uuid)
                    }
                } else {
                    Button(String(localized: "Refresh"), systemImage: "arrow.clockwise") {
                        importCenter.refresh(playlist)
                    }
                }
                Button(String(localized: "Edit Playlist…"), systemImage: "pencil") {
                    actions.edit(playlist)
                }
                Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                    actions.requestDelete(playlist)
                }
            }
        }
        .navigationTitle(Text(playlist.name))
    }
}
#endif
