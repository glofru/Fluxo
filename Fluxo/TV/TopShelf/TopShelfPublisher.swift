//
//  TopShelfPublisher.swift
//  Fluxo
//
//  Keeps the Top Shelf of the Home Screen up to date: what Home's first shelves show, for the playlists Home
//  shows (`PlaylistSelection`): Continue Watching (a series once, with the episode to watch now), Favorites
//  (channels, movies, episodes and series) and On Now (what the user's channels show, from the TV guide). It
//  writes them as a `TopShelfSnapshot` with finished images into the App Group container, and tells tvOS to ask
//  the extension again.
//
//  It runs while the app does, as a hidden view at the root of the TV app (`topShelfPublishing(player:)`): its
//  queries are the ones of Home, so a change to the history, the favorites, the watch progress, the guide or the
//  playlists publishes again (debounced, and not while the player is open: the position is saved every 10 s
//  there, and published once the player closes or the app goes to the background, also with the player open, in
//  background time). On Now is published again
//  when a programme ends; the snapshot also carries the next hours of each On Now channel, so the extension keeps
//  showing what is on air after the app was closed.
//
//  The Top Shelf is on the Home Screen, in front of everyone in the room: while Settings › Recommendations › "Hide
//  adult content from recommendations" is on, none of its sections shows adult content (`MatureContentFilter`),
//  unless the playlists have nothing else.
//
//  Debug builds with an isolated store (the simulator harness) publish their sample library too, which is how the
//  Top Shelf is checked in the simulator (`topshelf` route, Tools/Simulator/README.md); the next launch on the
//  real library writes it again.
//

#if os(tvOS)
import OSLog
import SwiftData
import SwiftUI
import TVServices

extension View {
    /// Publishes the Top Shelf (see `TopShelfPublisher`).
    func topShelfPublishing(player: AVPlayerViewModel) -> some View {
        background {
            TopShelfScopeReader(isPlayerOpen: player.isPresented)
        }
    }
}

/// Reads the playlists Home shows.
private struct TopShelfScopeReader: View {
    let isPlayerOpen: Bool

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @AppStorage(PlaylistSelection.storageKey) private var selectionRawValue = ""

    var body: some View {
        let scope = LibraryScope(playlists: playlists, selection: PlaylistSelection(rawValue: selectionRawValue))
        TopShelfSources(scope: scope, hasPlaylists: !playlists.isEmpty, isPlayerOpen: isPlayerOpen)
            .id(scope.bookmarkFilter)
    }
}

/// The queries of Home's first shelves; publishes when what they return changes.
private struct TopShelfSources: View {
    let scope: LibraryScope
    let hasPlaylists: Bool
    let isPlayerOpen: Bool

    @Query private var history: [ChannelBookmark]
    @Query private var favorites: [ChannelBookmark]
    @Query private var seriesFavorites: [SeriesBookmark]
    @Environment(ChannelLibrary.self) private var library
    @Environment(EPGStore.self) private var epg
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MatureContent.hidesAdultContentKey) private var hidesAdultContent = MatureContent.hidesAdultContentByDefault

    init(scope: LibraryScope, hasPlaylists: Bool, isPlayerOpen: Bool) {
        self.scope = scope
        self.hasPlaylists = hasPlaylists
        self.isPlayerOpen = isPlayerOpen
        _history = Query(HomeQueries.recents(playlistIDs: scope.bookmarkFilter, limit: TopShelfPublisher.itemLimit * 3))
        _favorites = Query(HomeQueries.favorites(playlistIDs: scope.bookmarkFilter, limit: TopShelfPublisher.itemLimit))
        _seriesFavorites = Query(SeriesQueries.favorites(playlistIDs: scope.bookmarkFilter, limit: TopShelfPublisher.itemLimit))
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: key) {
                let isLeaving = scenePhase == .background
                // While the player is open the history and the position change as it plays: publish once it closes,
                // or when the app leaves with it open (Home or the TV button leave the player up), which is when
                // what was just watched belongs in Continue Watching. The position was saved as the app became
                // inactive; a later save changes the key and publishes again.
                guard !isPlayerOpen || isLeaving else {
                    return
                }
                // Changes come in bursts (an import, a refresh of the guide, playing a channel records it in the
                // history and then its position): publish once they settle. At once when the app leaves, with
                // background time to draw the images and write the file before tvOS suspends the app.
                let activity = isLeaving ? BackgroundActivity(name: "Top Shelf") : nil
                defer { activity?.end() }
                if !isLeaving {
                    try? await Task.sleep(for: .seconds(2))
                }
                while !Task.isCancelled {
                    let input = TopShelfPublisher.Input(
                        scope: scope,
                        hasPlaylists: hasPlaylists,
                        history: history.map { ($0.lastWatchedAt, ChannelItem($0)) },
                        favorites: TVFavoriteEntry.merge(favorites, seriesFavorites, limit: TopShelfPublisher.itemLimit).map(TopShelfPublisher.Favorite.init)
                    )
                    let nextChange = await TopShelfPublisher.shared.publish(input, library: library, epg: epg, container: modelContext.container)
                    guard let nextChange, scenePhase == .active else {
                        return
                    }
                    // On Now changes when a programme ends.
                    try? await Task.sleep(for: .seconds(max(60, nextChange.timeIntervalSinceNow + 1)))
                }
            }
    }

    private var key: Key {
        Key(
            importIDs: scope.importIDs,
            history: history.map { HistoryKey(key: $0.key, watchedAt: $0.lastWatchedAt, position: $0.resumePosition) },
            favorites: favorites.map(\.key) + seriesFavorites.map(\.key),
            favoriteOrder: favorites.map(\.favoriteOrder) + seriesFavorites.map(\.favoriteOrder),
            guideRevision: epg.revision,
            hidesAdultContent: hidesAdultContent,
            isPlayerOpen: isPlayerOpen,
            isBackground: scenePhase == .background,
            isActive: scenePhase == .active
        )
    }

    private struct Key: Hashable {
        let importIDs: [UUID]
        let history: [HistoryKey]
        let favorites: [String]
        let favoriteOrder: [Double]
        let guideRevision: Int
        let hidesAdultContent: Bool
        let isPlayerOpen: Bool
        let isBackground: Bool
        let isActive: Bool
    }

    private struct HistoryKey: Hashable {
        let key: String
        let watchedAt: Date?
        let position: Double
    }
}

@MainActor
final class TopShelfPublisher {

    static let shared = TopShelfPublisher()

    /// Items per section: about two screens of the Top Shelf.
    static let itemLimit = 12
    /// How far ahead the programmes of an On Now channel go, so the shelf stays right without the app.
    static let airingsHorizon: TimeInterval = 12 * 3_600

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "TopShelf")

    struct Input {
        let scope: LibraryScope
        let hasPlaylists: Bool
        /// The history, most recent first.
        let history: [(Date?, ChannelItem)]
        let favorites: [Favorite]
    }

    enum Favorite {
        case channel(ChannelItem)
        case series(SeriesItem)

        init(_ entry: TVFavoriteEntry) {
            switch entry {
            case .channel(let bookmark):
                self = .channel(ChannelItem(bookmark))
            case .series(let bookmark):
                self = .series(SeriesItem(bookmark))
            }
        }

        func isAllowed(by filter: MatureContentFilter) -> Bool {
            switch self {
            case .channel(let item):
                return filter.allows(item)
            case .series(let series):
                return filter.allows(series)
            }
        }
    }

    /// The last snapshot written, without its date, so an unchanged one is not written again.
    private var lastWritten: TopShelfSnapshot?
    /// When this process last wrote the snapshot (the debug harness waits for it).
    private(set) var lastPublishedAt: Date?
    /// Whether a publish runs, and the publishes waiting for it, in order.
    private var isPublishing = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Writes the snapshot of `input`. Returns when it should be published again for On Now (the first programme
    /// to end), or nil when nothing in it is on a clock.
    @discardableResult
    func publish(_ input: Input, library: ChannelLibrary, epg: EPGStore, container: ModelContainer, now: Date = .now) async -> Date? {
        guard let directory = TopShelfStorage.directory, let imagesDirectory = TopShelfStorage.imagesDirectory else {
            Self.logger.notice("No App Group container: the Top Shelf shows the static image.")
            return nil
        }
        // One at a time: a change while a publish runs waits for it, then publishes what is current (a cancelled
        // one, replaced by a newer change, gives its turn on at once).
        if isPublishing {
            await withCheckedContinuation { waiting.append($0) }
        }
        isPublishing = true
        defer { finishPublishing() }
        guard !Task.isCancelled else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Cannot create the Top Shelf folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        var sections: [TopShelfSnapshot.Section] = []
        var nextChange: Date?
        if input.hasPlaylists {
            let filter = MatureContentFilter.forScope(importIDs: input.scope.importIDs, container: container)
            let input = Input(
                scope: input.scope,
                hasPlaylists: input.hasPlaylists,
                history: input.history.filter { filter.allows($0.1) },
                favorites: input.favorites.filter { $0.isAllowed(by: filter) }
            )
            let continueWatching = await continueWatching(input.history, library: library, container: container, images: imagesDirectory)
            if !continueWatching.isEmpty {
                sections.append(TopShelfSnapshot.Section(
                    kind: .continueWatching,
                    title: String(localized: "Continue Watching", comment: "Home page section: videos and channels watched recently."),
                    items: continueWatching
                ))
            }
            let favorites = await favorites(input.favorites, library: library, images: imagesDirectory)
            if !favorites.isEmpty {
                sections.append(TopShelfSnapshot.Section(
                    kind: .favorites,
                    title: String(localized: "Favorites", comment: "Home page section: the favorite channels."),
                    items: favorites
                ))
            }
            let (onNow, ends) = await onNow(input, epg: epg, container: container, now: now, images: imagesDirectory)
            if !onNow.isEmpty {
                sections.append(TopShelfSnapshot.Section(kind: .onNow, title: String(localized: "On Now"), items: onNow))
                nextChange = ends
            }
        }
        guard !Task.isCancelled else {
            return nil
        }

        let snapshot = TopShelfSnapshot(generatedAt: now, sections: sections)
        var comparable = snapshot
        comparable.generatedAt = .distantPast
        if comparable != lastWritten {
            do {
                let data = try TopShelfStorage.encode(snapshot)
                try data.write(to: directory.appending(path: "snapshot.json"), options: .atomic)
                lastWritten = comparable
                lastPublishedAt = .now
                removeImages(notIn: snapshot, from: imagesDirectory)
                TVTopShelfContentProvider.topShelfContentDidChange()
                Self.logger.info("Top Shelf: \(sections.map { "\($0.kind.rawValue) \($0.items.count)" }.joined(separator: ", "), privacy: .public)")
            } catch {
                Self.logger.error("Cannot write the Top Shelf: \(error.localizedDescription, privacy: .public)")
            }
        }
        return nextChange
    }

    /// Hands the turn to the next waiting publish (`isPublishing` stays set for it), or ends it.
    private func finishPublishing() {
        if waiting.isEmpty {
            isPublishing = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: - Sections

    /// The most recently watched channels, movies and episodes; a series once, with the episode to watch now (the
    /// next one when the last was finished), as Home's Continue Watching.
    private func continueWatching(_ history: [(Date?, ChannelItem)], library: ChannelLibrary, container: ModelContainer, images: URL) async -> [TopShelfSnapshot.Item] {
        var seenSeries: Set<String> = []
        var items: [TopShelfSnapshot.Item] = []
        for (_, watched) in history where items.count < Self.itemLimit {
            if let series = watched.series, !seenSeries.insert(SeriesBookmark.key(playlistID: watched.playlistID, seriesKey: series.seriesKey)).inserted {
                continue
            }
            var item = watched
            if watched.series != nil, library.watchProgress(for: watched) == nil, library.series.isWatched(watched) {
                let episode = watched
                let next = await Task.detached(priority: .utility) {
                    SeriesLookup.nextEpisode(after: episode, in: container)
                }.value
                item = next ?? watched
            }
            let progress = library.watchProgress(for: item)?.fraction
            let title = item.series.map { Self.title([$0.seriesTitle, EpisodeFormat.code($0)]) } ?? item.displayName
            if let entry = await channelItem(item, section: .continueWatching, title: title, progress: progress, isLive: false, images: images) {
                items.append(entry)
            }
        }
        return items
    }

    private func favorites(_ favorites: [Favorite], library: ChannelLibrary, images: URL) async -> [TopShelfSnapshot.Item] {
        var items: [TopShelfSnapshot.Item] = []
        for favorite in favorites {
            switch favorite {
            case .channel(let item):
                let title = item.series.map { Self.title([$0.seriesTitle, EpisodeFormat.code($0)]) } ?? item.displayName
                if let entry = await channelItem(item, section: .favorites, title: title, progress: library.watchProgress(for: item)?.fraction, isLive: false, images: images) {
                    items.append(entry)
                }
            case .series(let series):
                let art = TopShelfArt(logo: series.artwork, name: series.title, kind: .series, isLive: false)
                let files = await TopShelfArtworkRenderer.write(art, to: images)
                items.append(TopShelfSnapshot.Item(
                    id: "\(TopShelfSnapshot.Section.Kind.favorites.rawValue)|series|\(series.bookmarkKey)",
                    title: series.title,
                    image: files?.0,
                    image2x: files?.1,
                    playURL: TopShelfLink.playSeries(playlistID: series.playlistID, key: series.key, title: series.title).url,
                    displayURL: TopShelfLink.openSeries(playlistID: series.playlistID, key: series.key, title: series.title).url
                ))
            }
        }
        return items
    }

    /// What the user's live channels (favorites, then the history, then any channel with a guide) show now, with
    /// their next hours of programmes. Also returns when the first of the programmes on air ends.
    private func onNow(_ input: Input, epg: EPGStore, container: ModelContainer, now: Date, images: URL) async -> ([TopShelfSnapshot.Item], Date?) {
        guard epg.hasGuide else {
            return ([], nil)
        }
        let candidates = (input.favorites.compactMap { favorite -> ChannelItem? in
            if case .channel(let item) = favorite {
                return item
            }
            return nil
        } + input.history.map(\.1)).filter { $0.kind == .live }
        let entries = await OnNowLoader.loadShelf(own: candidates, importIDs: input.scope.importIDs, epg: epg, container: container, limit: Self.itemLimit, topUpBelow: 8, now: now)
        var items: [TopShelfSnapshot.Item] = []
        for entry in entries {
            var programmes = [entry.programme]
            if let ref = await epg.guideRef(for: entry.item) {
                let upcoming = await epg.upcoming(for: ref, from: entry.programme.stop, limit: 16)
                programmes += upcoming.filter { $0.start >= entry.programme.stop && $0.start < now.addingTimeInterval(Self.airingsHorizon) }
            }
            let channelName = entry.item.displayName
            let airings = programmes.map { programme in
                TopShelfSnapshot.Airing(title: Self.title([programme.title, channelName]), start: programme.start, stop: programme.stop)
            }
            if var item = await channelItem(entry.item, section: .onNow, title: airings[0].title, progress: nil, isLive: true, images: images) {
                item.airings = airings
                items.append(item)
            }
        }
        return (items, entries.isEmpty ? nil : OnNowLoader.nextChange(of: entries, now: now))
    }

    /// An item that plays a channel, movie or episode. Nil for one that cannot be played (no stream URL).
    private func channelItem(_ item: ChannelItem, section: TopShelfSnapshot.Section.Kind, title: String, progress: Double?, isLive: Bool, images: URL) async -> TopShelfSnapshot.Item? {
        guard let key = item.bookmarkKey, let entityID = ChannelEntityID.make(forKey: key) else {
            return nil
        }
        let art = TopShelfArt(logo: item.logo, name: item.series?.seriesTitle ?? item.displayName, kind: item.kind, isLive: isLive)
        let files = await TopShelfArtworkRenderer.write(art, to: images)
        let link = TopShelfLink.playChannel(id: entityID).url
        return TopShelfSnapshot.Item(
            id: "\(section.rawValue)|\(entityID)",
            title: title,
            image: files?.0,
            image2x: files?.1,
            progress: progress,
            playURL: link,
            displayURL: link
        )
    }

    /// A title made of parts ("Orbit · S1 E2", "Quiz Night · Rai 1 HD"). tvOS shows it and VoiceOver reads it,
    /// so the direction isolates of `TextParts.line` stay only where a right-to-left script (or the Arabic
    /// separator's letter mark) needs them to keep the parts in order.
    static func title(_ parts: [String?]) -> String {
        let line = TextParts.line(parts)
        let isolates: ClosedRange<UInt32> = 0x2066...0x2069
        let rightToLeft: [ClosedRange<UInt32>] = [0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF]
        guard !line.unicodeScalars.contains(where: { scalar in rightToLeft.contains { $0.contains(scalar.value) } }) else {
            return line
        }
        return String(String.UnicodeScalarView(line.unicodeScalars.filter { !isolates.contains($0.value) }))
    }

    /// Deletes the images the snapshot no longer points at.
    private func removeImages(notIn snapshot: TopShelfSnapshot, from directory: URL) {
        let kept = Set(snapshot.sections.flatMap(\.items).flatMap { [$0.image, $0.image2x].compactMap(\.self) })
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [] where !kept.contains(name) {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }
}
#endif
