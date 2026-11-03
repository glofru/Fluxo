//
//  GuideView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// The TV guide: a time grid of the channels that have a guide (day picker, jump to now, category filter),
/// programme search, reminders and the guide sources. A tab on iOS, a sidebar entry on macOS.
///
/// It follows the playlist selection of Home and Search (`PlaylistSelection`).
struct GuideView: View {

    static let dayCount = 7

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @Query(EPGQueries.sources()) private var sources: [EPGSource]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""

    @Environment(EPGStore.self) private var epg

    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var channels: [GuideChannel]?
    @State private var groupFilter: String?
    @State private var searchText = ""
    @State private var selection: GuideSelection?
    @State private var showsReminders = false
    @State private var showsSources = false
    @State private var showsAddSource = false
    @State private var scrollToNowRequest = 0

    private var scope: LibraryScope {
        LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
    }

    var body: some View {
        let scope = scope
        NavigationStack {
            content(scope: scope)
                .navigationTitle("TV Guide")
                .inlineNavigationBar()
                .searchable(text: $searchText, prompt: "Shows, films and sport")
                .toolbar {
                    toolbarContent(scope: scope)
                }
                .task(id: ChannelsKey(importIDs: scope.importIDs, revision: epg.revision)) {
                    let loaded = await epg.guideChannels(importIDs: scope.importIDs)
                    guard !Task.isCancelled else {
                        return
                    }
                    channels = loaded
                    if let groupFilter, !loaded.contains(where: { $0.item.groupName == groupFilter }) {
                        self.groupFilter = nil
                    }
                    #if DEBUG
                    await openDebugScreens(channels: loaded)
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
                    // Past midnight: the grid moves on to the new day.
                    let today = Calendar.current.startOfDay(for: .now)
                    if day < today {
                        day = today
                    }
                }
        }
        .sheet(item: $selection) { selection in
            ProgrammeDetailView(programme: selection.programme, channel: selection.channel.item, ref: selection.channel.ref)
        }
        .sheet(isPresented: $showsReminders) {
            NavigationStack {
                RemindersView()
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsAddSource) {
            AddGuideSourceView()
        }
        .sheet(isPresented: $showsSources) {
            NavigationStack {
                GuideSourcesView()
            }
            .presentationDetents([.medium, .large])
        }
    }

    #if DEBUG
    /// `-FluxoDebugGuideSearch <term>` searches, `-FluxoDebugGuideDetail YES` opens the programme on air of the
    /// first channel (see `DebugGuideDemo`).
    private func openDebugScreens(channels: [GuideChannel]) async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "FluxoDebugGuideSources") {
            showsSources = true
        }
        if let term = defaults.string(forKey: "FluxoDebugGuideSearch"), searchText.isEmpty {
            searchText = term
        }
        if defaults.bool(forKey: "FluxoDebugGuideDetail"), selection == nil, let channel = channels.first,
           let programme = await epg.nowNext(for: channel.item)?.current {
            selection = GuideSelection(programme: programme, channel: channel)
        }
    }
    #endif

    private struct ChannelsKey: Equatable {
        let importIDs: [UUID]
        let revision: Int
    }

    // MARK: - Content

    @ViewBuilder
    private func content(scope: LibraryScope) -> some View {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if playlists.isEmpty {
            ContentUnavailableView("No Playlists", systemImage: "calendar.day.timeline.left", description: Text("Add a playlist on the Home screen. Its TV guide shows up here."))
        } else if sources.isEmpty {
            GuideNoSourcesView {
                showsAddSource = true
            }
        } else if !sources.contains(where: \.isEnabled) {
            ContentUnavailableView {
                Label("TV Guide Is Off", systemImage: "calendar.badge.minus")
            } description: {
                Text("All guide sources are turned off. Turn one on to see what's on.")
            } actions: {
                Button("Guide Sources") {
                    showsSources = true
                }
                .buttonStyle(.glassProminent)
            }
        } else if !term.isEmpty {
            GuideSearchResultsView(term: term, importIDs: scope.importIDs, showsPlaylistNames: scope.showsPlaylistNames, playlistNames: scope.playlistNames) { selection in
                self.selection = selection
            }
        } else if !epg.isReady {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let channels {
            let visible = groupFilter.map { group in channels.filter { $0.item.groupName == group } } ?? channels
            if visible.isEmpty {
                noChannels
            } else {
                VStack(spacing: 0) {
                    if groupFilter == nil && Calendar.current.isDateInToday(day) {
                        GuideForYouStrip(importIDs: scope.importIDs) { selection in
                            self.selection = selection
                        }
                    }
                    GuideDayBar(day: $day, dayCount: Self.dayCount) {
                        scrollToNowRequest += 1
                    }
                    GuideGrid(channels: visible, day: day, scrollToNowRequest: scrollToNowRequest) { selection in
                        self.selection = selection
                    }
                    .id(groupFilter)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var noChannels: some View {
        if epg.isRefreshing {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading the TV guide…")
                    .font(.headline)
                if let message = epg.progress.values.first?.message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Guide for These Channels", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text(noChannelsDescription)
            } actions: {
                Button("Refresh Guide", systemImage: "arrow.clockwise") {
                    epg.refreshAll()
                }
                .buttonStyle(.glassProminent)
                Button("Guide Sources") {
                    showsSources = true
                }
            }
        }
    }

    private var noChannelsDescription: String {
        let enabled = sources.filter(\.isEnabled)
        if let error = enabled.compactMap(\.lastError).first {
            return error
        }
        if enabled.allSatisfy({ $0.currentImportID == nil }) {
            return String(localized: "The guide has not been downloaded yet.")
        }
        return String(localized: "None of the live channels match a channel of the guide. Touch and hold a channel and choose Guide Channel to pick one by hand.")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(scope: LibraryScope) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            filterMenu(scope: scope)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showsReminders = true
            } label: {
                Label("Reminders", systemImage: epg.reminders.keys.isEmpty ? "bell" : "bell.badge")
            }
            .help("Reminders")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Refresh Guide", systemImage: "arrow.clockwise") {
                    epg.refreshAll()
                }
                .disabled(epg.isRefreshing)
                Button("Guide Sources…", systemImage: "list.bullet.rectangle") {
                    showsSources = true
                }
            } label: {
                if epg.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Guide", systemImage: "ellipsis")
                }
            }
            .help(epg.progress.values.first?.message ?? "Guide options")
        }
    }

    private func filterMenu(scope: LibraryScope) -> some View {
        let groups = orderedGroups
        return Menu {
            if playlists.count > 1 {
                Picker("Playlist", selection: Binding(get: { scope.selection }, set: { selectionRawValue = $0.rawValue })) {
                    Text("All Playlists")
                        .tag(PlaylistSelection.all)
                    ForEach(playlists) { playlist in
                        Text(playlist.name)
                            .tag(PlaylistSelection.playlist(playlist.uuid))
                    }
                }
            }
            if groups.count > 1 {
                Picker("Category", selection: $groupFilter) {
                    Text("All Categories")
                        .tag(String?.none)
                    ForEach(groups, id: \.self) { group in
                        Text(group.isEmpty ? "Other" : group)
                            .tag(String?.some(group))
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: groupFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .disabled(playlists.count < 2 && groups.count < 2)
        .help("Playlist and category")
    }

    /// Categories of the channels with a guide, in playlist order.
    private var orderedGroups: [String] {
        var seen: Set<String> = []
        return (channels ?? []).compactMap { channel in
            seen.insert(channel.item.groupName).inserted ? channel.item.groupName : nil
        }
    }
}

/// Day chips (today and the next days) and "Now".
private struct GuideDayBar: View {
    @Binding var day: Date
    let dayCount: Int
    let onNow: () -> Void

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let days = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        day = today
                        onNow()
                    } label: {
                        Label("Now", systemImage: "clock")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                    .accessibilityHint("Scrolls the guide to the current time")

                    ForEach(days, id: \.self) { date in
                        let isSelected = calendar.isDate(date, inSameDayAs: day)
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth) {
                                day = date
                            }
                        } label: {
                            Text(label(for: date))
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(isSelected ? .regular.tint(Theme.accent.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
                        .glassEffectID(isSelected ? "selected" : date.description, in: glassNamespace)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, HomeLayout.horizontalMargin)
                .padding(.vertical, 8)
            }
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: day)
    }

    private func label(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(localized: "Today")
        }
        if calendar.isDateInTomorrow(date) {
            return String(localized: "Tomorrow")
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

/// No guide source at all: explains where guides come from and offers to add one.
private struct GuideNoSourcesView: View {
    let onAdd: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No TV Guide Yet", systemImage: "calendar.day.timeline.left")
        } description: {
            Text("Fluxo loads the guide your playlist provides (url-tvg). Your playlists don't list one. Add the address of an XMLTV guide, such as the one from your provider or a free guide for your country.")
        } actions: {
            Button("Add Guide Source", systemImage: "plus", action: onAdd)
                .buttonStyle(.glassProminent)
        }
    }
}

#Preview("Guide") {
    GuideView()
        .fluxoPreviewEnvironment(GuidePreviewData.container)
}

#Preview("No sources") {
    GuideView()
        .fluxoPreviewEnvironment()
}
