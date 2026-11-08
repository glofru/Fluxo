//
//  TVGuideScreen.swift
//  Fluxo
//
//  The Live TV tab of Apple TV: the TV guide as a grid of channels × time made for the focus engine, and the live
//  channels by category (Channels).
//
//  The grid shows a two-hour window. The channel column on the leading edge and the time ruler on top stay put; the
//  rows scroll up and down. Each programme is a button as wide as its time in the window, so swiping moves across
//  the programmes of a channel and up or down to the programme on air at the same time on the channel above or
//  below. A narrow Earlier / Later cell at each end of a row moves the window an hour back or on (the focus lands
//  on the programme that was just out of view), and Earlier, Now, Later and the day menu above the grid jump
//  further. A line marks the current time. Selecting a programme opens it (Watch, Remind Me, what follows), Play /
//  Pause plays its channel, and selecting a channel's name plays it.
//
//  Programmes are read a row at a time as rows scroll in, for a day around the window (`TVGuideModel`), so paging
//  the window within it reads nothing new.
//

#if os(tvOS)
import SwiftData
import SwiftUI

struct TVGuideScreen: View {
    enum Mode: String, CaseIterable {
        case guide
        case channels
    }

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @Query(EPGQueries.sources()) private var sources: [EPGSource]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""
    @AppStorage("tv.live.mode") private var modeRawValue = Mode.guide.rawValue
    @Environment(EPGStore.self) private var epg
    @Environment(AppNavigation.self) private var navigation

    @State private var channels: [GuideChannel]?
    @State private var groupFilter: String?
    @State private var selection: GuideSelection?
    @State private var showsAddSource = false
    @State private var path = NavigationPath()
    /// The window of the grid, kept while the tab is away (coming back shows the same hours).
    @State private var model = TVGuideModel()

    private var scope: LibraryScope {
        LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
    }

    private var hasEnabledSource: Bool {
        epg.visibleSources(sources).contains(where: \.isEnabled)
    }

    /// The channels by category when there is no guide to show.
    private var mode: Mode {
        hasEnabledSource ? (Mode(rawValue: modeRawValue) ?? .guide) : .channels
    }

    var body: some View {
        let scope = scope
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                if playlists.isEmpty {
                    TVNoPlaylistsState(message: String(localized: "TV.live.noPlaylists", defaultValue: "Add an M3U playlist. Its channels and TV guide show up here.", comment: "Apple TV Live TV page when there is no playlist."), systemImage: "calendar.day.timeline.left")
                } else {
                    content(scope: scope)
                }
            }
            .tvDestinations()
        }
        .environment(model)
        .sheet(item: $selection) { selection in
            TVProgrammeScreen(programme: selection.programme, channel: selection.channel.item, ref: selection.channel.ref)
        }
        // A page of its own, as Add Playlist (`tvFormPage`).
        .fullScreenCover(isPresented: $showsAddSource) {
            AddGuideSourceView()
                .tvFormPage()
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
        }
        #if DEBUG
        .onChange(of: navigation.debugGuideSelection, initial: true) { _, debugSelection in
            // Debug harness (`programme:<channel>`).
            if let debugSelection {
                modeRawValue = Mode.guide.rawValue
                selection = debugSelection
                navigation.debugGuideSelection = nil
            }
        }
        #endif
        // Open Screen (Siri, a fluxo:// link): Live TV from its root.
        .onChange(of: navigation.rootRequest) { _, request in
            if request?.tab == .guide {
                path = NavigationPath()
            }
        }
        .onChange(of: navigation.guideFocus, initial: true) { _, focus in
            // Show in TV Guide: the grid, at the channel.
            if focus != nil {
                modeRawValue = Mode.guide.rawValue
                groupFilter = nil
                path = NavigationPath()
            }
        }
    }

    private struct ChannelsKey: Equatable {
        let importIDs: [UUID]
        let revision: Int
    }

    @ViewBuilder
    private func content(scope: LibraryScope) -> some View {
        let visible = (channels ?? []).filter { groupFilter == nil || $0.item.groupName == groupFilter }
        switch mode {
        case .channels:
            VStack(alignment: .leading, spacing: 0) {
                controls(scope: scope, visible: [])
                if !hasEnabledSource {
                    TVNoGuideBanner {
                        showsAddSource = true
                    }
                }
                TVKindScreen(kind: .live, embedsNavigation: false)
            }
            .padding(.top, TVLayout.tabBarClearance)
            .ignoresSafeArea(edges: [.top, .horizontal])
        case .guide:
            VStack(alignment: .leading, spacing: 0) {
                controls(scope: scope, visible: visible)
                if !epg.isReady || channels == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visible.isEmpty {
                    noChannels
                } else {
                    TVGuideGrid(channels: visible) { selection in
                        self.selection = selection
                    }
                }
            }
            .padding(.top, TVLayout.tabBarClearance)
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
    }

    // MARK: - Controls

    /// Guide / Channels, and in the guide the day, the time and the category.
    private func controls(scope: LibraryScope, visible: [GuideChannel]) -> some View {
        HStack(spacing: 24) {
            if hasEnabledSource {
                Picker(String(localized: "TV.live.mode", defaultValue: "Show", comment: "Apple TV Live TV: the picker between the TV guide grid and the channels by category."), selection: $modeRawValue) {
                    Text(String(localized: "TV.live.guide", defaultValue: "Guide", comment: "Apple TV Live TV: the TV guide grid."))
                        .tag(Mode.guide.rawValue)
                    Text(String(localized: "TV.live.channels", defaultValue: "Channels", comment: "Apple TV Live TV: the live channels by category."))
                        .tag(Mode.channels.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 520)
            } else {
                Text("Live TV")
                    .font(.title3.bold())
            }
            Spacer()
            if mode == .guide {
                TVGuideWindowControls()
                let groups = orderedGroups
                if groups.count > 1 {
                    Picker(selection: $groupFilter) {
                        Text("All Categories")
                            .tag(String?.none)
                        ForEach(groups, id: \.self) { group in
                            Text(ChannelCandidate.displayGroup(group))
                                .tag(String?.some(group))
                        }
                    } label: {
                        Label(groupFilter.map(ChannelCandidate.displayGroup) ?? String(localized: "All Categories"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .pickerStyle(.menu)
                    // The menu's title is its choice: VoiceOver says what it chooses, then the choice.
                    .accessibilityLabel(Text(String(localized: "TV.guide.categoryMenu", defaultValue: "Category", comment: "VoiceOver: the menu of the Apple TV TV guide that shows one category of channels (its value is the category shown, or All Categories).")))
                    .accessibilityValue(Text(groupFilter.map(ChannelCandidate.displayGroup) ?? String(localized: "All Categories")))
                }
            }
        }
        .padding(.horizontal, TVLayout.margin)
        .padding(.bottom, 24)
        .focusSection()
    }

    /// Categories of the channels with a guide, in playlist order.
    private var orderedGroups: [String] {
        var seen: Set<String> = []
        return (channels ?? []).compactMap { channel in
            seen.insert(channel.item.groupName).inserted ? channel.item.groupName : nil
        }
    }

    @ViewBuilder
    private var noChannels: some View {
        if epg.isRefreshing {
            VStack(spacing: 20) {
                ProgressView()
                Text("Loading the TV guide…")
                    .font(.headline)
                if let message = epg.progress.values.first?.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TVEmptyState(title: String(localized: "No Guide for These Channels"), message: noChannelsDescription, systemImage: "calendar.badge.exclamationmark") {
                Button(String(localized: "Refresh Guide"), systemImage: "arrow.clockwise") {
                    epg.refreshAll()
                }
                .tvActionButton(prominent: true)
                Button(String(localized: "TV.live.showChannels", defaultValue: "Show Channels", comment: "Apple TV Live TV: shows the live channels by category instead of the TV guide."), systemImage: "square.grid.2x2") {
                    modeRawValue = Mode.channels.rawValue
                }
                .tvActionButton()
            }
        }
    }

    private var noChannelsDescription: String {
        let enabled = epg.visibleSources(sources).filter(\.isEnabled)
        if let error = enabled.compactMap(\.lastErrorMessage).first {
            return error
        }
        if enabled.allSatisfy({ $0.currentImportID == nil }) {
            return String(localized: "The guide has not been downloaded yet.")
        }
        return String(localized: "TV.live.noMatch", defaultValue: "None of the live channels match a channel of the guide.", comment: "Apple TV Live TV, when no channel of the playlists has a TV guide.")
    }
}

/// No guide source yet: what a guide adds, and the button to add one.
private struct TVNoGuideBanner: View {
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 30) {
            Image(systemName: "calendar.badge.plus")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "TV.live.noGuide.title", defaultValue: "Add a TV Guide", comment: "Apple TV Live TV, when no TV guide source is set up: the title of the prompt."))
                    .font(.headline)
                Text(String(localized: "TV.live.noGuide.message", defaultValue: "With an XMLTV guide, Live TV shows what is on every channel, now and for the week ahead.", comment: "Apple TV Live TV, when no TV guide source is set up: what a guide adds."))
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button(String(localized: "Add Guide Source…"), systemImage: "plus", action: onAdd)
                .tvActionButton(prominent: true)
        }
        .padding(30)
        .background(.regularMaterial, in: .rect(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, TVLayout.margin)
        .padding(.bottom, 20)
        .focusSection()
    }
}

/// Earlier, Now, Later and the day, above the grid.
private struct TVGuideWindowControls: View {
    @Environment(TVGuideModel.self) private var model

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let days = (0..<TVGuideModel.dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let shownDay = calendar.startOfDay(for: model.windowStart)
        HStack(spacing: 20) {
            Button {
                model.move(by: -TVGuideModel.step * 2)
            } label: {
                Label(String(localized: "TV.guide.earlier", defaultValue: "Earlier", comment: "Apple TV TV guide: moves the grid two hours back."), systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
            }
            .disabled(!model.canGoEarlier)
            Button(String(localized: "TV.guide.now", defaultValue: "Now", comment: "Apple TV TV guide: moves the grid to the current time.")) {
                model.showNow()
            }
            .lineLimit(1)
            .fixedSize()
            Button {
                model.move(by: TVGuideModel.step * 2)
            } label: {
                Label(String(localized: "TV.guide.later", defaultValue: "Later", comment: "Apple TV TV guide: moves the grid two hours on."), systemImage: "chevron.forward")
                    .labelStyle(.iconOnly)
            }
            .disabled(!model.canGoLater)
            Picker(selection: Binding(get: { shownDay }, set: { day in
                // Another day at the same time of day (now, for today).
                let offset = model.windowStart.timeIntervalSince(shownDay)
                if calendar.isDateInToday(day) {
                    model.showNow()
                } else {
                    model.show(day.addingTimeInterval(offset))
                }
            })) {
                ForEach(days, id: \.self) { day in
                    Text(GuideFormat.day(day))
                        .tag(day)
                }
            } label: {
                Label(GuideFormat.day(shownDay), systemImage: "calendar")
                    .lineLimit(1)
                    .fixedSize()
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(Text(String(localized: "TV.guide.dayMenu", defaultValue: "Day", comment: "VoiceOver: the menu of the Apple TV TV guide that chooses the day shown (its value is the day, as Today or Tomorrow).")))
            .accessibilityValue(Text(GuideFormat.day(shownDay)))
        }
    }
}
#endif
