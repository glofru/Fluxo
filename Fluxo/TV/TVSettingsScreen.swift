//
//  TVSettingsScreen.swift
//  Fluxo
//
//  The Settings tab of Apple TV, laid out like the system's Settings app: the app's mark and the library at a
//  glance on the leading side, the settings as a list on the other: playlists (add, refresh, edit, delete, which
//  ones Home shows), TV guide sources (add, turn on or off, refresh, delete; reminders), playback, audio and
//  subtitles, the watch history, recordings and the version.
//
//  Addresses are typed in the shared Add Playlist and Add Guide Source sheets: their text fields bring up the tvOS
//  keyboard, dictation, and the Continuity Keyboard on a nearby iPhone or iPad (a notification offers it), which is
//  the comfortable way to type a long playlist or guide address.
//

#if os(tvOS)
import SwiftData
import SwiftUI

struct TVSettingsScreen: View {

    let player: AVPlayerViewModel

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @Query(EPGQueries.sources()) private var sources: [EPGSource]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""
    @AppStorage(PlayerPreferences.timeShiftMinutesKey) private var timeShiftMinutes = PlayerPreferences.defaultTimeShiftMinutes
    @AppStorage(ReminderCenter.leadMinutesKey) private var leadMinutes = ReminderCenter.defaultLeadMinutes
    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(EPGStore.self) private var epg
    @Environment(ChannelLibrary.self) private var library
    @State private var showsAddSource = false
    @State private var confirmation: Confirmation?

    private enum Confirmation: Identifiable {
        case clearHistory
        case deleteRecordings

        var id: Self {
            self
        }
    }

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 60) {
                TVSettingsHeader(playlistCount: playlists.count, recordingCount: player.recordings.recordings.count)
                    .frame(width: 560)
                    .padding(.top, 120)
                list
            }
            .padding(.leading, TVLayout.margin)
            .navigationDestination(for: TVSettingsRoute.self) { route in
                switch route {
                case .playlist(let uuid):
                    if let playlist = playlists.first(where: { $0.uuid == uuid }) {
                        TVPlaylistScreen(playlist: playlist)
                    }
                case .guideSource(let uuid):
                    if let source = sources.first(where: { $0.uuid == uuid }) {
                        TVGuideSourceScreen(source: source, playlistName: source.playlistID.flatMap { id in playlists.first { $0.uuid == id }?.name })
                    }
                }
            }
        }
        .sheet(isPresented: $showsAddSource) {
            AddGuideSourceView()
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible, presenting: confirmation) { item in
            switch item {
            case .clearHistory:
                Button(String(localized: "Clear History"), role: .destructive) {
                    library.clearHistory()
                }
            case .deleteRecordings:
                Button(String(localized: "Delete All Recordings"), role: .destructive) {
                    player.recordings.deleteAll()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { item in
            switch item {
            case .clearHistory:
                Text("Continue Watching will be emptied. Favorites are kept.")
            case .deleteRecordings:
                Text("\(player.recordings.recordings.count) recordings (\(Self.bytes(player.recordings.totalBytes))) will be deleted. This cannot be undone.")
            }
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .clearHistory:
            return String(localized: "Clear the watch history?")
        case .deleteRecordings:
            return String(localized: "Delete All Recordings?")
        case nil:
            return ""
        }
    }

    private var list: some View {
        List {
            playlistsSection
            guideSection
            Section {
                Picker(selection: $timeShiftMinutes) {
                    ForEach(PlayerPreferences.timeShiftChoices, id: \.self) { minutes in
                        Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide)))
                            .tag(minutes)
                    }
                } label: {
                    Label(String(localized: "Time-shift buffer"), systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
            } header: {
                Text("Playback")
            } footer: {
                Text(String(localized: "TV.settings.timeShift.footer", defaultValue: "How far back you can pause and rewind a live channel. Applies the next time a channel starts.", comment: "Apple TV Settings, Playback footer: what the time-shift buffer is."))
            }
            TrackSettingsSection()
            Section {
                Button(role: .destructive) {
                    confirmation = .clearHistory
                } label: {
                    Label(String(localized: "Clear Watch History…"), systemImage: "clock.arrow.circlepath")
                }
            } header: {
                Text(LibraryText.title)
            }
            Section {
                LabeledContent {
                    Text(TextParts.line([player.recordings.recordings.count.formatted(), Self.bytes(player.recordings.totalBytes)]))
                        .monospacedDigit()
                } label: {
                    Label(String(localized: "Recordings"), systemImage: "record.circle")
                }
                Button(role: .destructive) {
                    confirmation = .deleteRecordings
                } label: {
                    Label(String(localized: "Delete All Recordings…"), systemImage: "trash")
                }
                .disabled(player.recordings.recordings.isEmpty || player.isRecording)
            } header: {
                Text("Recordings")
            } footer: {
                Text(String(localized: "TV.settings.recordings.footer", defaultValue: "Apple TV keeps recordings in its cache: tvOS may delete them when it runs out of space.", comment: "Apple TV Settings, Recordings footer: tvOS may delete recordings when the Apple TV runs out of space."))
            }
            Section("About") {
                LabeledContent(String(localized: "TV.settings.version", defaultValue: "Version", comment: "Apple TV Settings: the app's version number."), value: SettingsViewModel.appVersion)
            }
        }
        // Every choice opens its own list, as in the system's Settings (the shared audio and subtitle section too).
        .pickerStyle(.navigationLink)
        .padding(.top, 60)
    }

    // MARK: - Playlists

    private var playlistsSection: some View {
        Section {
            ForEach(playlists) { playlist in
                NavigationLink(value: TVSettingsRoute.playlist(playlist.uuid)) {
                    LabeledContent {
                        if importCenter.progress[playlist.uuid] != nil {
                            ProgressView()
                        } else {
                            Text("\(playlist.channelCount) channels", comment: "Apple TV Settings: how many channels a playlist has.")
                        }
                    } label: {
                        Label(playlist.name, systemImage: "list.bullet.rectangle")
                    }
                }
            }
            Button {
                actions.add()
            } label: {
                Label(String(localized: "Add Playlist…"), systemImage: "plus")
            }
            if playlists.count > 1 {
                Picker(selection: $selectionRawValue) {
                    Text("All Playlists")
                        .tag(PlaylistSelection.all.rawValue)
                    ForEach(playlists) { playlist in
                        Text(playlist.name)
                            .tag(PlaylistSelection.playlist(playlist.uuid).rawValue)
                    }
                } label: {
                    Label(String(localized: "TV.settings.show", defaultValue: "Show", comment: "Apple TV Settings: which playlists Home, Live TV, Movies, Series and Search show."), systemImage: "square.stack")
                }
            }
        } header: {
            Text("Playlists")
        } footer: {
            Text(String(localized: "TV.settings.playlists.footer", defaultValue: "M3U playlists over HTTP or HTTPS. When the keyboard shows, your iPhone or iPad offers to type the address for you.", comment: "Apple TV Settings, Playlists footer: how to type an address (the Continuity Keyboard of an iPhone)."))
        }
    }

    // MARK: - Guide

    private var guideSection: some View {
        Section {
            ForEach(epg.visibleSources(sources)) { source in
                NavigationLink(value: TVSettingsRoute.guideSource(source.uuid)) {
                    LabeledContent {
                        if epg.progress[source.uuid] != nil {
                            ProgressView()
                        } else {
                            Text(source.isEnabled ? (source.lastErrorMessage == nil ? String(localized: "\(source.programmeCount) programmes", comment: "Status of a TV guide source: how many programmes it has.") : String(localized: "TV.settings.source.failed", defaultValue: "Failed", comment: "Apple TV Settings: a TV guide source whose last refresh failed.")) : String(localized: "Off"))
                        }
                    } label: {
                        Label(source.name, systemImage: source.isUserAdded ? "link" : "list.bullet.rectangle")
                    }
                }
            }
            Button {
                showsAddSource = true
            } label: {
                Label(String(localized: "Add Guide Source…"), systemImage: "plus")
            }
            Button {
                epg.refreshAll()
            } label: {
                Label(epg.isRefreshing ? String(localized: "Refreshing…") : String(localized: "Refresh Guide Now"), systemImage: "arrow.clockwise")
            }
            .disabled(epg.visibleSources(sources).isEmpty || epg.isRefreshing)
            Picker(selection: $leadMinutes) {
                ForEach(ReminderCenter.leadChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? "When It Starts" : "\(minutes) Minutes Before")
                        .tag(minutes)
                }
            } label: {
                Label(String(localized: "Remind Me"), systemImage: "bell")
            }
            .onChange(of: leadMinutes) {
                Task {
                    await epg.reminders.rescheduleAll()
                }
            }
        } header: {
            Text("TV Guide")
        } footer: {
            Text("Guides listed by your playlists (url-tvg) are added automatically. Fluxo keeps 7 days of programmes for the live channels of your playlists and refreshes them twice a day.")
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

enum TVSettingsRoute: Hashable {
    case playlist(UUID)
    case guideSource(UUID)
}

/// The app's mark, its version and the library at a glance (the leading side of Settings).
private struct TVSettingsHeader: View {
    let playlistCount: Int
    let recordingCount: Int

    @Environment(ChannelLibrary.self) private var library

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 120, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 280, height: 280)
                .background(Theme.brandGradient, in: .rect(cornerRadius: 60, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Fluxo")
                    .font(.title2.bold())
                Text("Version \(SettingsViewModel.appVersion)")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 40) {
                stat(playlistCount, String(localized: "Playlists"))
                stat(library.favoriteKeys.count + library.series.favoriteKeys.count, String(localized: "Favorites"))
                stat(recordingCount, String(localized: "Recordings"))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: Int, _ title: String) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted())
                .font(.title3.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// One playlist: what it has, and refresh, edit and delete.
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
                if let progress = importCenter.progress[playlist.uuid] {
                    PlaylistImportProgressView(progress: progress)
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

/// One guide source: where it comes from and its state; on or off, refresh, delete (the ones added by the user).
private struct TVGuideSourceScreen: View {
    let source: EPGSource
    let playlistName: String?

    @Environment(EPGStore.self) private var epg
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { source.isEnabled }, set: { epg.setEnabled($0, sourceID: source.uuid) })) {
                    Label(String(localized: "Use This Guide"), systemImage: "calendar.day.timeline.left")
                }
                LabeledContent(String(localized: "TV.source.origin", defaultValue: "From", comment: "Apple TV, a TV guide source's page: where the source comes from (a playlist, or added by the user)."), value: playlistName ?? (source.isUserAdded ? String(localized: "Added by you") : String(localized: "From a playlist")))
                LabeledContent(String(localized: "TV.source.address", defaultValue: "Address", comment: "Apple TV, a TV guide source's page: its URL."), value: source.url.host() ?? source.url.absoluteString)
                if let progress = epg.progress[source.uuid] {
                    LabeledContent(String(localized: "TV.source.status", defaultValue: "Status", comment: "Apple TV, a TV guide source's page: what it is doing or how its last refresh went."), value: progress.message)
                } else if let error = source.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                } else if let refreshed = source.lastRefreshedOn {
                    LabeledContent(String(localized: "TV.playlist.updated", defaultValue: "Updated", comment: "Apple TV, a playlist's page: label of when it was last refreshed."), value: refreshed.formatted(.relative(presentation: .named)))
                    LabeledContent(String(localized: "TV.source.programmes", defaultValue: "Programmes", comment: "Apple TV, a TV guide source's page: how many programmes it has."), value: source.programmeCount.formatted())
                    LabeledContent(String(localized: "TV.playlist.channels", defaultValue: "Channels", comment: "Apple TV, a playlist's page: label of its number of channels."), value: String(localized: "\(source.storedChannelCount) of \(source.channelCount) channels", comment: "Status of a TV guide source: channels used by the playlists out of all its channels."))
                }
            }
            Section {
                Button(String(localized: "Refresh"), systemImage: "arrow.clockwise") {
                    epg.refresh(source.uuid)
                }
                .disabled(epg.progress[source.uuid] != nil)
                if source.isUserAdded {
                    Button(String(localized: "Delete Guide Source"), systemImage: "trash", role: .destructive) {
                        confirmsDelete = true
                    }
                }
            }
        }
        .navigationTitle(Text(source.name))
        .confirmationDialog(Text("Delete \(source.name)?"), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete Guide Source"), role: .destructive) {
                let sourceID = source.uuid
                dismiss()
                epg.deleteSource(sourceID)
            }
        } message: {
            Text("Its programmes are removed. Reminders you set stay.")
        }
    }
}
#endif
