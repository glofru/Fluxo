//
//  TVHomeScreen.swift
//  Fluxo
//
//  The Apple TV Home: the full-bleed hero (`TVHero`), then shelves: Continue Watching (a series once, with the
//  episode to watch now), Favorites (channels, movies, episodes and series), On Now (what the user's channels show,
//  from the TV guide), then the first categories of live TV, movies and series, each ending with a See All card.
//  Everything follows the playlist selection of Home (`PlaylistSelection`; Settings changes it).
//
//  The shelves are the shared queries of the iPhone Home (`HomeQueries`, `SeriesQueries`, `OnNowLoader`), each
//  bounded by a fetch limit; the category shelves are fetched as they scroll in.
//

#if os(tvOS)
import SwiftData
import SwiftUI

struct TVHomeScreen: View {

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""
    @Environment(AppNavigation.self) private var navigation
    @Environment(PlaylistActions.self) private var actions
    @Environment(PlaylistImportCenter.self) private var importCenter

    private var scope: LibraryScope {
        LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
    }

    var body: some View {
        @Bindable var navigation = navigation
        let scope = scope
        NavigationStack(path: $navigation.homePath) {
            Group {
                if playlists.isEmpty {
                    TVWelcome(onAddPlaylist: actions.add, onTryDemo: actions.addDemo)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: TVLayout.shelfSpacing) {
                                TVHero(importIDs: scope.importIDs)
                                TVImportStatus(playlists: playlists.filter { scope.playlistIDs.contains($0.uuid) })
                                TVContinueWatchingShelf(playlistIDs: scope.bookmarkFilter)
                                    .id(TVHomeSection.continueWatching)
                                TVFavoritesShelf(playlistIDs: scope.bookmarkFilter)
                                    .id(TVHomeSection.favorites)
                                TVOnNowShelf(scope: scope)
                                    .id(TVHomeSection.onNow)
                                TVGroupShelves(scope: scope, kind: .live, limit: 6)
                                    .id(TVHomeSection.live)
                                TVGroupShelves(scope: scope, kind: .movie, limit: 3)
                                    .id(TVHomeSection.movies)
                                TVGroupShelves(scope: scope, kind: .series, limit: 3)
                                    .id(TVHomeSection.series)
                            }
                            .padding(.bottom, TVLayout.verticalMargin)
                        }
                        .scrollClipDisabled()
                        .ignoresSafeArea()
                        #if DEBUG
                        // Debug harness (`home-section:<continueWatching|favorites|onNow|live|movies|series>`): brings a
                        // section into view (and so into the lazy stack) for `focus:` and screenshots.
                        .onChange(of: navigation.debugHomeSection) { _, section in
                            if let section = section.flatMap(TVHomeSection.init(rawValue:)) {
                                proxy.scrollTo(section, anchor: .top)
                            }
                        }
                        #endif
                    }
                }
            }
            .tvDestinations()
        }
    }
}

/// The shelves of Home that the debug harness scrolls to.
enum TVHomeSection: String {
    case continueWatching
    case favorites
    case onNow
    case live
    case movies
    case series
}

// MARK: - Welcome and status

/// First launch: no playlist yet. The Add Playlist button has the focus, or Add from iCloud when iCloud sync found
/// playlists of the user's other devices (the way to watch without typing an address with the remote).
struct TVWelcome: View {
    let onAddPlaylist: () -> Void
    /// Add Playlist with the demo playlist filled in.
    let onTryDemo: () -> Void

    @Environment(CloudSync.self) private var sync: CloudSync?
    @FocusState private var focused: Action?

    private enum Action: Hashable {
        case add
        case iCloud
        case demo
    }

    var body: some View {
        let cloud = CloudSyncWelcomeNote.Status(sync)
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.lilac.opacity(0.15), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 30) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 100, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 200, height: 200)
                    .glassEffect(.regular.tint(Theme.accent.opacity(0.6)), in: .circle)
                    .accessibilityHidden(true)
                Text("Welcome to Fluxo")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                // Never truncated: the lines wrap at the width and the stack makes room for them.
                Text("Add an M3U playlist to watch live TV, movies and series. You can add as many playlists as you like and switch between them here.")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1_000)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "TV.welcome.continuity", defaultValue: "Type the address with the remote, by voice, or with the keyboard of your iPhone when it offers to help.", comment: "Apple TV Home, first launch: how to type a playlist address (the Siri Remote, dictation, or the Continuity Keyboard on a nearby iPhone)."))
                    .font(.callout)
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1_000)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 40) {
                    if case .playlists(let count) = cloud {
                        Button {
                            sync?.presentImportSheet()
                        } label: {
                            Label {
                                Text(CloudSyncWelcomeNote.addTitle(count: count))
                            } icon: {
                                Image(systemName: "icloud.and.arrow.down")
                            }
                            .font(.headline)
                            .padding(.horizontal, 16)
                        }
                        // Two actions of the same weight: the focus alone highlights one (it starts on this one).
                        .tvActionButton()
                        .focused($focused, equals: .iCloud)
                        .accessibilityHint(Text("Shows the playlists of your other devices, to add them to this Apple TV.", comment: "VoiceOver hint of the Add from iCloud button of the Apple TV welcome screen."))
                    }
                    Button {
                        onAddPlaylist()
                    } label: {
                        Label("Add Playlist", systemImage: "plus")
                            .font(.headline)
                            .padding(.horizontal, 16)
                    }
                    .tvActionButton(prominent: !cloud.hasPlaylists)
                    .focused($focused, equals: .add)
                    Button {
                        onTryDemo()
                    } label: {
                        Label {
                            Text("Try the Demo Playlist", comment: "First-run screen: opens Add Playlist with the demo playlist filled in (free test streams and Creative Commons films).")
                        } icon: {
                            Image(systemName: "sparkles.tv")
                        }
                        .font(.headline)
                        .padding(.horizontal, 16)
                    }
                    .tvActionButton()
                    .focused($focused, equals: .demo)
                    .accessibilityHint(Text("Free test streams and open movies, to see how Fluxo works.", comment: "VoiceOver hint of the Try the Demo Playlist button."))
                }
                .padding(.top, 12)
                .focusSection()
                if cloud == .looking {
                    CloudSyncWelcomeNote()
                }
                Text(ContentNotice.text)
                    .font(.callout)
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1_000)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(TVLayout.margin)
        }
        .defaultFocus($focused, cloud.hasPlaylists ? .iCloud : .add)
        #if DEBUG
        // Debug harness (`cloud-focus:welcome-add|welcome-icloud|welcome-demo`): the focused state of each button, for screenshots.
        .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugCloudFocus)) { notification in
            switch notification.object as? String {
            case "welcome-add": focused = .add
            case "welcome-icloud": focused = .iCloud
            case "welcome-demo": focused = .demo
            default: break
            }
        }
        #endif
    }
}

/// Playlists that update, or that have no channels yet (Refresh).
private struct TVImportStatus: View {
    let playlists: [Playlist]

    @Environment(PlaylistImportCenter.self) private var importCenter

    var body: some View {
        let updating = playlists.filter { importCenter.progress[$0.uuid] != nil }
        let empty = playlists.filter { $0.currentImportID == nil && importCenter.progress[$0.uuid] == nil }
        if !updating.isEmpty || !empty.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(updating) { playlist in
                    if let progress = importCenter.progress[playlist.uuid] {
                        HStack(spacing: 24) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Updating \(playlist.name)")
                                    .font(.headline)
                                PlaylistImportProgressView(progress: progress)
                                    .font(.caption)
                            }
                            Spacer()
                            Button("Cancel", systemImage: "xmark") {
                                importCenter.cancelImport(for: playlist.uuid)
                            }
                            .tvActionButton()
                        }
                    }
                }
                ForEach(empty) { playlist in
                    HStack(spacing: 24) {
                        Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.title3)
                            .foregroundStyle(Theme.warning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.name)
                                .font(.headline)
                            Text("No channels yet. Refresh to download them.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            importCenter.refresh(playlist)
                        }
                        .tvActionButton()
                    }
                }
            }
            .padding(30)
            .background(.regularMaterial, in: .rect(cornerRadius: 30, style: .continuous))
            .padding(.horizontal, TVLayout.margin)
            .focusSection()
        }
    }
}

// MARK: - Continue Watching

/// The most recently watched channels, movies and episodes. A series shows once, with the episode to watch now: the
/// last one if it stopped part-way, else the next one. `kinds` narrows it (the Movies and Series pages).
struct TVContinueWatchingShelf: View {

    static let fetchLimit = 20

    let playlistIDs: [UUID]?
    var kinds: Set<ChannelContentKind> = Set(ChannelContentKind.allCases)

    @Query private var history: [ChannelBookmark]
    @Environment(ChannelLibrary.self) private var library

    init(playlistIDs: [UUID]?, kinds: Set<ChannelContentKind> = Set(ChannelContentKind.allCases)) {
        self.playlistIDs = playlistIDs
        self.kinds = kinds
        _history = Query(HomeQueries.recents(playlistIDs: playlistIDs, limit: Self.fetchLimit * 2))
    }

    private var bookmarks: [ChannelBookmark] {
        var seenSeries: Set<String> = []
        let entries = history.filter { bookmark in
            guard kinds.contains(bookmark.kind) else {
                return false
            }
            guard let seriesKey = bookmark.seriesKey else {
                return true
            }
            return seenSeries.insert(SeriesBookmark.key(playlistID: bookmark.playlistID, seriesKey: seriesKey)).inserted
        }
        return Array(entries.prefix(Self.fetchLimit))
    }

    var body: some View {
        let bookmarks = bookmarks
        if !bookmarks.isEmpty {
            TVShelf(title: String(localized: "Continue Watching", comment: "Home page section: videos and channels watched recently."), systemImage: "clock.arrow.circlepath") {
                ForEach(bookmarks) { bookmark in
                    TVContinueCard(lastWatched: ChannelItem(bookmark), watchedAt: bookmark.lastWatchedAt)
                }
                TVSeeAllCard(route: .history(playlistIDs: playlistIDs), focusName: "see-all-history")
            }
        }
    }
}

/// A Continue Watching card: the artwork with how far it was watched, the name, and the episode, the time left or
/// what a live channel shows now. A finished episode gives way to the next one ("Up Next").
struct TVContinueCard: View {
    let lastWatched: ChannelItem
    var watchedAt: Date?

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @Environment(\.modelContext) private var modelContext
    @State private var upNext: ChannelItem?

    var body: some View {
        let isFinished = lastWatched.series != nil && library.watchProgress(for: lastWatched) == nil && library.series.isWatched(lastWatched)
        let item = isFinished ? (upNext ?? lastWatched) : lastWatched
        let isUpNext = isFinished && upNext != nil
        let progress = library.watchProgress(for: item)
        NowNextReader(item: item) { nowNext in
            let current = nowNext?.current
            TVCard(
                size: TVLayout.landscapeCard,
                action: .perform { playChannel(item) },
                focusName: item.displayName,
                accessibilityLabel: Text(TextParts.spoken([
                    item.series?.seriesTitle ?? item.displayName,
                    isUpNext ? String(localized: "Up Next", comment: "Label of the episode of a series to watch next (Continue Watching, the series page, the player).") : nil,
                    item.series.map(EpisodeFormat.spokenCode),
                    progress.map(WatchProgressFormat.remaining),
                    current?.title,
                ])),
                accessibilityHint: Text(item.kind == .live ? TVText.playsHint(for: item) : (isUpNext ? LocalizedStringResource("Plays the next episode") : LocalizedStringResource("Resumes the video")))
            ) {
                TVLandscapeArtwork(item: item)
                    .overlay(alignment: .bottom) {
                        if let progress {
                            ProgrammeProgressBar(progress: progress.fraction, tint: Theme.accent, height: 6)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 14)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if isUpNext {
                            Text("Up Next", comment: "Label of the episode of a series to watch next (Continue Watching, the series page, the player).")
                                .font(.caption2.weight(.heavy))
                                .textCase(.uppercase)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassEffect(.regular.tint(Theme.accentFill), in: .capsule)
                                .padding(14)
                        }
                    }
            } caption: { isFocused in
                TVCardCaption(
                    title: item.series?.seriesTitle ?? item.displayName,
                    subtitle: subtitle(item: item, progress: progress, current: current),
                    progress: item.kind == .live ? current.map { $0.progress(at: .now) } : nil,
                    isFocused: isFocused,
                    showsLiveBadge: item.kind == .live && current != nil,
                    progressTint: Theme.live
                )
            } menu: {
                TVChannelMenu(item: item)
                Button(role: .destructive) {
                    library.removeFromContinueWatching(lastWatched)
                } label: {
                    Label(String(localized: "Remove from History", comment: "Context menu action of a Continue Watching item."), systemImage: "minus.circle")
                }
            }
        }
        .task(id: TaskKey(episode: lastWatched, isFinished: isFinished)) {
            guard isFinished else {
                upNext = nil
                return
            }
            let container = modelContext.container
            let episode = lastWatched
            upNext = await Task.detached(priority: .userInitiated) {
                SeriesLookup.nextEpisode(after: episode, in: container)
            }.value
        }
    }

    private func subtitle(item: ChannelItem, progress: WatchProgress?, current: GuideProgramme?) -> String? {
        if let episode = item.series {
            return TextParts.line([EpisodeFormat.code(episode), progress.map(WatchProgressFormat.remaining) ?? episode.episodeTitle])
        }
        if let progress {
            return WatchProgressFormat.remaining(progress)
        }
        if let current {
            return current.title
        }
        return watchedAt.map { $0.formatted(.relative(presentation: .named)) }
    }

    private struct TaskKey: Hashable {
        let episode: ChannelItem
        let isFinished: Bool
    }
}

// MARK: - Favorites

/// Favorite channels, movies, episodes and series in the user's order.
struct TVFavoritesShelf: View {

    static let fetchLimit = 30

    let playlistIDs: [UUID]?

    @Query private var bookmarks: [ChannelBookmark]
    @Query private var seriesBookmarks: [SeriesBookmark]

    init(playlistIDs: [UUID]?) {
        self.playlistIDs = playlistIDs
        _bookmarks = Query(HomeQueries.favorites(playlistIDs: playlistIDs, limit: Self.fetchLimit))
        _seriesBookmarks = Query(SeriesQueries.favorites(playlistIDs: playlistIDs, limit: Self.fetchLimit))
    }

    var body: some View {
        let entries = TVFavoriteEntry.merge(bookmarks, seriesBookmarks, limit: Self.fetchLimit)
        if !entries.isEmpty {
            TVShelf(title: String(localized: "Favorites", comment: "Home page section: the favorite channels."), systemImage: "star.fill") {
                ForEach(entries) { entry in
                    switch entry {
                    case .channel(let bookmark):
                        TVChannelCard(item: ChannelItem(bookmark))
                    case .series(let bookmark):
                        TVSeriesLandscapeCard(series: SeriesItem(bookmark))
                    }
                }
                TVSeeAllCard(route: .favorites(playlistIDs: playlistIDs), focusName: "see-all-favorites")
            }
        }
    }
}

/// A favorite channel or series, in the order the user gave them (they share the `favoriteOrder` scale).
enum TVFavoriteEntry: Identifiable {
    case channel(ChannelBookmark)
    case series(SeriesBookmark)

    var id: String {
        switch self {
        case .channel(let bookmark):
            return "c|\(bookmark.key)"
        case .series(let bookmark):
            return "s|\(bookmark.key)"
        }
    }

    private var order: (Double, Date) {
        switch self {
        case .channel(let bookmark):
            return (bookmark.favoriteOrder, bookmark.favoritedOn ?? .distantPast)
        case .series(let bookmark):
            return (bookmark.favoriteOrder, bookmark.favoritedOn ?? .distantPast)
        }
    }

    static func merge(_ channels: [ChannelBookmark], _ series: [SeriesBookmark], limit: Int) -> [TVFavoriteEntry] {
        let merged = channels.map(TVFavoriteEntry.channel) + series.map(TVFavoriteEntry.series)
        return Array(merged.sorted { lhs, rhs in
            lhs.order.0 != rhs.order.0 ? lhs.order.0 < rhs.order.0 : lhs.order.1 > rhs.order.1
        }.prefix(limit))
    }
}

/// A series in a landscape card (the Favorites and Library shelves, among channels). Opens the series page.
struct TVSeriesLandscapeCard: View {
    let series: SeriesItem

    @Environment(ChannelLibrary.self) private var library

    var body: some View {
        let known = library.series.summary(of: series)
        TVCard(
            size: TVLayout.landscapeCard,
            action: .open(series.route),
            focusName: series.title,
            accessibilityLabel: Text(TextParts.spoken([series.title, ChannelContentKind.series.title] + known.countParts)),
            accessibilityHint: Text(TVText.opensSeriesHint)
        ) {
            TVLandscapeArtworkView(logo: known.artwork ?? series.artwork, name: series.title, kind: .series)
        } caption: { isFocused in
            TVCardCaption(title: series.title, subtitle: known.countsLine ?? ChannelContentKind.series.title, isFocused: isFocused)
        } menu: {
            Button {
                library.series.toggleFavorite(series)
            } label: {
                Label(String(localized: "Remove from Favorites"), systemImage: "star.slash")
            }
        }
        .task(id: series.bookmarkKey) {
            library.series.loadSummary(of: series)
        }
    }
}

// MARK: - On Now

/// What the user's channels (favorites, then the history, then any channel with a guide) show now. Hidden without a
/// guide.
struct TVOnNowShelf: View {

    static let limit = 16

    let scope: LibraryScope

    @Environment(EPGStore.self) private var epg
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.modelContext) private var modelContext
    @State private var entries: [OnNowEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !entries.isEmpty {
                TVShelf(title: String(localized: "On Now"), subtitle: String(localized: "From the TV guide"), systemImage: "dot.radiowaves.left.and.right") {
                    ForEach(entries) { entry in
                        TVOnNowCard(entry: entry)
                    }
                    TVCard(
                        size: TVLayout.landscapeCard,
                        action: .perform { navigation.show(.guide) },
                        focusName: "open-guide",
                        accessibilityLabel: Text("TV Guide"),
                        accessibilityHint: Text(String(localized: "TV.hint.guide", defaultValue: "Shows the TV guide", comment: "VoiceOver hint of the card at the end of the On Now row on Apple TV."))
                    ) {
                        ZStack {
                            Rectangle().fill(.primary.opacity(0.12))
                            VStack(spacing: 10) {
                                Image(systemName: "calendar.day.timeline.left")
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                Text("TV Guide")
                                    .font(.headline)
                            }
                        }
                    } caption: { _ in
                        EmptyView()
                    }
                }
            }
        }
        .task(id: LoadKey(importIDs: scope.importIDs, revision: epg.revision)) {
            while !Task.isCancelled {
                guard epg.hasGuide else {
                    entries = []
                    return
                }
                let loaded = await OnNowLoader.load(candidates: candidates(), epg: epg, limit: Self.limit)
                var found = loaded
                if found.count < 8 {
                    let more = await epg.guideChannels(importIDs: scope.importIDs).prefix(60).map(\.item)
                    found = await OnNowLoader.load(candidates: loaded.map(\.item) + more, epg: epg, limit: Self.limit)
                }
                guard !Task.isCancelled else {
                    return
                }
                if found != entries {
                    entries = found
                }
                let wake = OnNowLoader.nextChange(of: found)
                try? await Task.sleep(for: .seconds(max(30, wake.timeIntervalSinceNow + 1)))
            }
        }
    }

    private struct LoadKey: Hashable {
        let importIDs: [UUID]
        let revision: Int
    }

    private func candidates() -> [ChannelItem] {
        let filter = scope.bookmarkFilter
        let favorites = (try? modelContext.fetch(HomeQueries.favorites(playlistIDs: filter, limit: 40))) ?? []
        let recents = (try? modelContext.fetch(HomeQueries.recents(playlistIDs: filter, limit: 40))) ?? []
        return (favorites + recents).map(ChannelItem.init).filter { $0.kind == .live }
    }
}

/// A programme on air: the programme's image (or the channel's logo), its title, the channel and the progress.
private struct TVOnNowCard: View {
    let entry: OnNowEntry

    @Environment(\.playChannel) private var playChannel

    var body: some View {
        TimelineView(.everyMinute) { context in
            TVCard(
                size: TVLayout.landscapeCard,
                action: .perform { playChannel(entry.item) },
                focusName: entry.item.displayName,
                accessibilityLabel: Text(TextParts.spoken([entry.programme.title, entry.item.displayName, GuideFormat.remaining(entry.programme, at: context.date)])),
                accessibilityHint: Text(TVText.playsHint(for: entry.item))
            ) {
                ZStack {
                    if let icon = entry.programme.icon {
                        TVLandscapeArtwork(item: entry.item)
                        LogoImage(source: icon, size: TVLayout.landscapeCard, contentMode: .fill) { _ in
                            Color.clear
                        }
                    } else {
                        TVLandscapeArtwork(item: entry.item)
                    }
                }
                .overlay(alignment: .topLeading) {
                    LiveBadge()
                        .padding(14)
                }
                .overlay(alignment: .bottom) {
                    ProgrammeProgressBar(progress: entry.programme.progress(at: context.date), tint: Theme.live, height: 6)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
            } caption: { isFocused in
                TVCardCaption(
                    title: entry.programme.title,
                    subtitle: TextParts.line([entry.item.displayName, GuideFormat.remaining(entry.programme, at: context.date)]),
                    isFocused: isFocused
                )
            } menu: {
                TVChannelMenu(item: entry.item)
            }
        }
    }
}

// MARK: - Categories

/// The first `limit` categories of a kind, a shelf each (or every category, a page at a time: `limit == nil`).
struct TVGroupShelves: View {

    static let pageSize = 8

    let scope: LibraryScope
    let kind: ChannelContentKind
    /// nil: every category, loaded as the shelves scroll in.
    var limit: Int?

    @State private var shown = TVGroupShelves.pageSize

    var body: some View {
        TVGroupShelvesPage(scope: scope, kind: kind, limit: limit ?? shown) {
            if limit == nil {
                shown += Self.pageSize
            }
        }
        .id(GroupsKey(importIDs: scope.importIDs, kind: kind))
    }

    private struct GroupsKey: Hashable {
        let importIDs: [UUID]
        let kind: ChannelContentKind
    }
}

private struct TVGroupShelvesPage: View {
    @Query private var groups: [PlaylistChannelGroup]

    private let scope: LibraryScope
    private let limit: Int
    private let onReachEnd: () -> Void

    init(scope: LibraryScope, kind: ChannelContentKind, limit: Int, onReachEnd: @escaping () -> Void) {
        self.scope = scope
        self.limit = limit
        self.onReachEnd = onReachEnd
        _groups = Query(HomeQueries.groups(importIDs: scope.importIDs, kind: kind, limit: limit))
    }

    var body: some View {
        ForEach(groups) { group in
            TVGroupShelf(group: GroupItem(group), playlistName: scope.showsPlaylistNames ? scope.playlistNames[group.playlistID] : nil)
                .onAppear {
                    if groups.count >= limit, group.persistentModelID == groups.last?.persistentModelID {
                        onReachEnd()
                    }
                }
        }
    }
}

/// The first entries of one category, with a See All card when it has more.
struct TVGroupShelf: View {

    static let fetchLimit = 20

    let group: GroupItem
    var playlistName: String?

    @Query private var channels: [PlaylistChannel]

    init(group: GroupItem, playlistName: String?) {
        self.group = group
        self.playlistName = playlistName
        _channels = Query(HomeQueries.channels(importID: group.importID, groupName: group.name, limit: Self.fetchLimit))
    }

    var body: some View {
        if !channels.isEmpty {
            TVShelf(title: group.displayName, subtitle: playlistName) {
                ForEach(channels) { channel in
                    let item = ChannelItem(channel)
                    if group.kind == .live {
                        TVChannelCard(item: item)
                    } else {
                        TVPosterCard(item: item)
                    }
                }
                if group.itemCount > channels.count {
                    TVSeeAllCard(route: group.route, group: group, size: group.kind == .live ? TVLayout.landscapeCard : TVLayout.posterCard, focusName: "see-all-\(group.name)")
                }
            }
        }
    }
}
#endif
