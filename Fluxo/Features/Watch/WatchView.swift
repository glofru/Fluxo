//
//  WatchView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-03.
//

import SwiftData
import SwiftUI

struct WatchView: View {

    @Environment(PlaylistImportCenter.self) private var importCenter

    let viewModel: AVPlayerViewModel

    @State private var displayedSheet: HomeViewSheet?

    @State private var playlistToDelete: Playlist?

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Playlist")) {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistView(playlist: playlist)
                        } label: {
                            PlaylistRow(playlist: playlist, progress: importCenter.progress[playlist.uuid])
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                playlistToDelete = playlist
                            }

                            Button("Rename", systemImage: "pencil") {
                                displayedSheet = .updatePlaylist(playlist)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            refreshButton(for: playlist)
                        }
                        .contextMenu {
                            refreshButton(for: playlist)

                            Button("Rename", systemImage: "pencil") {
                                displayedSheet = .updatePlaylist(playlist)
                            }

                            Button("Delete", systemImage: "trash", role: .destructive) {
                                playlistToDelete = playlist
                            }
                        }
                    }
                }

                ForEach(playlists) { playlist in
                    if let importID = playlist.currentImportID {
                        ChannelGroupSections(importID: importID) { channel in
                            viewModel.play(PlayableChannel(channel))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .headerProminence(.increased)
            .navigationTitle("Watch")
            .toolbar {
                Button(action: {
                    displayedSheet = .recordings
                }, label: {
                    Image(systemName: "film.stack")
                        .accessibilityLabel("Recordings")
                })

                Button(action: {
                    displayedSheet = .addPlaylist
                }, label: {
                    Image(systemName: "plus")
                        .accessibilityLabel("Add a playlist")
                })
            }
            .sheet(item: $displayedSheet) { sheet in
                switch sheet {
                case .addPlaylist:
                    AddPlaylistView()
                        .presentationDetents([.medium])
                case .updatePlaylist(let playlist):
                    AddPlaylistView(playlist: playlist)
                        .presentationDetents([.medium])
                case .recordings:
                    RecordingsView(store: viewModel.recordings, isRecordingActive: viewModel.isRecording) { recording in
                        displayedSheet = nil
                        viewModel.playRecording(recording)
                    }
                }
            }
            .alert("Delete playlist", isPresented: .init(get: { playlistToDelete != nil }, set: { _ in playlistToDelete = nil }), presenting: playlistToDelete) { playlist in
                Button("Cancel", role: .cancel) {}

                Button("Delete", role: .destructive) {
                    importCenter.delete(playlist)
                }
            } message: { playlist in
                Text("Are you sure to delete playlist \"\(playlist.name)\"?")
            }
            .alert("Playlist error", isPresented: .init(get: { importCenter.failure != nil }, set: { _ in importCenter.failure = nil }), presenting: importCenter.failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text("\(failure.playlistName): \(failure.message)")
            }
        }
    }

    @ViewBuilder
    private func refreshButton(for playlist: Playlist) -> some View {
        if importCenter.progress[playlist.uuid] != nil {
            Button("Cancel update", systemImage: "xmark.circle") {
                importCenter.cancelImport(for: playlist.uuid)
            }
            .tint(.orange)
        } else {
            Button("Refresh", systemImage: "arrow.clockwise") {
                importCenter.refresh(playlist)
            }
            .tint(.blue)
        }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let progress: PlaylistImportProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(playlist.name)

            if let progress {
                PlaylistImportProgressView(progress: progress)
                    .font(.caption)
            } else if playlist.currentImportID != nil {
                Text("\(playlist.channelCount.formatted()) channels in \(playlist.groupCount.formatted()) groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No channels yet. Refresh to download them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The groups of one playlist import, one list section each.
///
/// Groups are fetched a page at a time: the next page is requested when the last loaded section
/// appears, so a playlist with thousands of groups only materializes the ones scrolled to.
private struct ChannelGroupSections: View {

    static let pageSize = 25

    let importID: UUID
    let onSelect: (PlaylistChannel) -> Void

    @State private var limit = ChannelGroupSections.pageSize

    var body: some View {
        ChannelGroupSectionsPage(importID: importID, limit: limit, onSelect: onSelect) {
            limit += Self.pageSize
        }
        .onChange(of: importID) {
            // A refresh switched to new rows: start from the first page again.
            limit = Self.pageSize
        }
    }
}

private struct ChannelGroupSectionsPage: View {

    @Query private var groups: [PlaylistChannelGroup]

    private let importID: UUID
    private let limit: Int
    private let onSelect: (PlaylistChannel) -> Void
    private let onReachEnd: () -> Void

    init(importID: UUID, limit: Int, onSelect: @escaping (PlaylistChannel) -> Void, onReachEnd: @escaping () -> Void) {
        self.importID = importID
        self.limit = limit
        self.onSelect = onSelect
        self.onReachEnd = onReachEnd
        var descriptor = FetchDescriptor<PlaylistChannelGroup>(
            predicate: #Predicate { $0.importID == importID },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchLimit = limit
        _groups = Query(descriptor)
    }

    var body: some View {
        ForEach(groups) { group in
            Section(header: Text(group.displayName).padding().glassEffect()) {
                ChannelGroupRow(importID: importID, groupName: group.name, onSelect: onSelect)
                    .onAppear {
                        if groups.count >= limit, group.persistentModelID == groups.last?.persistentModelID {
                            onReachEnd()
                        }
                    }

                if group.channelCount > ChannelGroupRow.fetchLimit {
                    NavigationLink("Show all \(group.channelCount.formatted()) channels") {
                        ChannelGroupView(importID: importID, groupName: group.name, title: group.displayName, onSelect: onSelect)
                    }
                }
            }
        }
    }
}

/// Horizontal strip with the first channels of a group. Only `fetchLimit` rows are fetched,
/// so huge groups do not load thousands of models for one row.
private struct ChannelGroupRow: View {

    static let fetchLimit = 50

    @Query private var channels: [PlaylistChannel]

    private let onSelect: (PlaylistChannel) -> Void

    init(importID: UUID, groupName: String, onSelect: @escaping (PlaylistChannel) -> Void) {
        self.onSelect = onSelect
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchLimit = Self.fetchLimit
        _channels = Query(descriptor)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack {
                ForEach(channels) { channel in
                    ChannelPreview(channel: channel) {
                        onSelect(channel)
                    }
                }
            }
        }
    }
}

/// Every channel of a group in a lazy grid, fetched a page at a time as the grid scrolls.
private struct ChannelGroupView: View {

    static let pageSize = 60

    let importID: UUID
    let groupName: String
    let title: String
    let onSelect: (PlaylistChannel) -> Void

    @State private var limit = ChannelGroupView.pageSize

    var body: some View {
        ScrollView {
            ChannelGridPage(importID: importID, groupName: groupName, limit: limit, onSelect: onSelect) {
                limit += Self.pageSize
            }
        }
        .navigationTitle(title)
    }
}

private struct ChannelGridPage: View {

    @Query private var channels: [PlaylistChannel]

    private let limit: Int
    private let onSelect: (PlaylistChannel) -> Void
    private let onReachEnd: () -> Void

    init(importID: UUID, groupName: String, limit: Int, onSelect: @escaping (PlaylistChannel) -> Void, onReachEnd: @escaping () -> Void) {
        self.limit = limit
        self.onSelect = onSelect
        self.onReachEnd = onReachEnd
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.groupName == groupName },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchLimit = limit
        _channels = Query(descriptor)
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)]) {
            ForEach(channels) { channel in
                ChannelPreview(channel: channel) {
                    onSelect(channel)
                }
                .onAppear {
                    if channels.count >= limit, channel.persistentModelID == channels.last?.persistentModelID {
                        onReachEnd()
                    }
                }
            }
        }
    }
}

private enum HomeViewSheet: Identifiable {
    case addPlaylist
    case updatePlaylist(Playlist)
    case recordings

    var id: String {
        switch self {
        case .addPlaylist: "AddPlaylist"
        case .recordings: "Recordings"
        case .updatePlaylist(let playlist): "UpdatePlaylist\(playlist.uuid)"
        }
    }
}

#Preview {
    WatchView(viewModel: AVPlayerViewModel())
        .environment(PlaylistImportCenter(container: ModelContainerFactory.preview()))
        .modelContainer(ModelContainerFactory.preview())
}
