//
//  DebugRoutes.swift
//  Fluxo
//
//  Debug harness: the screens `-FluxoDebugRoute` can open. A route is `name` or `name:argument`; several run in
//  order when separated by ";", e.g. `-FluxoDebugRoute "playlist:Sky Italia;group:Sport"`.
//  `-FluxoDebugRoute help` logs the list.
//
//  To add a route for a new screen, add one line to `DebugRoutes.all`, e.g.
//
//      DebugRoute("guide", "The TV Guide.") { context, _ in context.navigation.show(.guide) },
//

#if DEBUG
import AVFoundation
import os
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct DebugRoute {
    typealias Handler = @MainActor (DebugRouteContext, String) async throws -> Void

    let name: String
    let summary: String
    let run: Handler

    init(_ name: String, _ summary: String, run: @escaping Handler) {
        self.name = name
        self.summary = summary
        self.run = run
    }
}

/// Everything a route can drive.
@MainActor
struct DebugRouteContext {
    let navigation: AppNavigation
    let player: AVPlayerViewModel
    let library: ChannelLibrary
    let importCenter: PlaylistImportCenter
    let playlistActions: PlaylistActions
    let modelContext: ModelContext
    /// The TV guide (`seed-guide`, `schedule:`).
    let epg: EPGStore
    /// Opens the Settings window (macOS); nil on iOS, where Settings is a tab.
    let openSettings: (() -> Void)?
    /// Opens a channel in a player window (iPad).
    var openChannelWindow = OpenChannelWindowAction()

    /// A playlist by name (case-insensitive; exact match first, then the first that contains it).
    func playlist(named name: String) throws -> Playlist {
        let playlists = (try? modelContext.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.createdOn)]))) ?? []
        if let playlist = playlists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            ?? playlists.first(where: { $0.name.localizedStandardContains(name) }) {
            return playlist
        }
        throw DebugRouteError.notFound("playlist", name)
    }

    /// A group of the visible playlists by name; the selected playlist's groups win.
    func group(named name: String) throws -> GroupItem {
        let importIDs = visibleImportIDs
        var descriptor = FetchDescriptor<PlaylistChannelGroup>(
            predicate: #Predicate { importIDs.contains($0.importID) && $0.name.localizedStandardContains(name) },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchLimit = 200
        let groups = (try? modelContext.fetch(descriptor)) ?? []
        let selected = PlaylistSelection(rawValue: UserDefaults.fluxo.string(forKey: PlaylistSelection.storageKey) ?? "")
        let ranked = groups.sorted { lhs, rhs in
            func score(_ group: PlaylistChannelGroup) -> Int {
                var score = group.name.caseInsensitiveCompare(name) == .orderedSame ? 2 : 0
                if case .playlist(let uuid) = selected, group.playlistID == uuid {
                    score += 1
                }
                return score
            }
            return score(lhs) > score(rhs)
        }
        guard let group = ranked.first else {
            throw DebugRouteError.notFound("group", name)
        }
        return GroupItem(group)
    }

    /// A channel of the visible playlists by name (exact match first).
    func channel(named name: String) throws -> ChannelItem {
        guard let item = DebugSeeder.channel(named: name, in: modelContext) else {
            throw DebugRouteError.notFound("channel", name)
        }
        return item
    }

    /// A series of the visible playlists by title (exact match first).
    func series(named name: String) throws -> SeriesItem {
        let importIDs = visibleImportIDs
        var descriptor = FetchDescriptor<PlaylistSeries>(
            predicate: #Predicate { importIDs.contains($0.importID) && $0.title.localizedStandardContains(name) },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchLimit = 50
        let found = (try? modelContext.fetch(descriptor)) ?? []
        guard let series = found.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) ?? found.first else {
            throw DebugRouteError.notFound("series", name)
        }
        return SeriesItem(series)
    }

    private var visibleImportIDs: [UUID] {
        ((try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []).compactMap(\.currentImportID)
    }

    /// Waits until `condition` holds, for at most `timeout` seconds.
    func wait(timeout: Double = 30, until condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Plays a library channel; it is added to the watch history like a tap would.
    func play(_ item: ChannelItem, present: Bool) async {
        await prepareForPlayback()
        library.recordWatch(item)
        player.play(item, present: present)
    }

    /// Plays a stream that is not in the library.
    func play(_ channel: PlayableChannel, present: Bool) async {
        await prepareForPlayback()
        player.play(channel, present: present)
    }

    func prepareForPlayback() async {
        player.presentationSourceID = nil
    }
}

enum DebugRouteError: LocalizedError {
    case notFound(String, String)
    case invalidArgument(String, String)
    /// A playback check failed (`skip:`, `seek:`, `probe-playback`).
    case check(String)
    /// The route drives a screen this platform does not have (the touch player on Apple TV).
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case let .notFound(kind, name):
            return "No \(kind) named \"\(name)\""
        case let .invalidArgument(route, argument):
            return "Invalid argument \"\(argument)\" for \(route)"
        case let .check(problem):
            return "Check failed: \(problem)"
        case let .unsupported(route):
            return "\(route) is not available on this platform"
        }
    }
}

@MainActor
enum DebugRoutes {
    /// A position of what plays: seconds, or a percentage of the duration ("40%").
    @MainActor
    static func position(_ text: String, in player: AVPlayerViewModel) -> TimeInterval? {
        if text.hasSuffix("%"), let percent = Double(text.dropLast()), player.timeline.duration > 0 {
            return player.timeline.duration * percent / 100
        }
        return Double(text)
    }


    static let all: [DebugRoute] = [
        DebugRoute("home", "Home, from its root.") { context, _ in
            context.navigation.show(.home)
        },
        DebugRoute("tab:<home|guide|library|settings|search|movies|series|playlist name>", "Selects a tab (iOS, tvOS; movies and series are Apple TV tabs; playlists are iPad sidebar entries).") { context, argument in
            var tabs: [String: AppNavigation.Tab] = [
                "home": .home, "guide": .guide, "library": .library, "settings": .settings, "search": .search,
            ]
            #if os(tvOS)
            tabs["movies"] = .movies
            tabs["series"] = .series
            tabs["live"] = .guide
            #endif
            if let tab = tabs[argument.lowercased()] {
                context.navigation.tab = tab
            } else {
                context.navigation.tab = .playlist(try context.playlist(named: argument).uuid)
            }
        },
        DebugRoute("focus:<name>", "Apple TV: moves the focus to the card of a channel, movie or series, a programme of the guide, or a named button (`hero`, `play`, `season:<n>`, `episode:<code>`, `guide-now`, …) on the page shown (exactly; the Siri Remote cannot be scripted), for screenshots of a focused state.") { context, argument in
            #if os(tvOS)
            context.navigation.debugFocusName = nil
            await Task.yield()
            context.navigation.debugFocusName = argument
            #else
            throw DebugRouteError.unsupported("focus")
            #endif
        },
        DebugRoute("guide", "The TV Guide (the Guide tab on iOS, the sidebar item on macOS).") { context, _ in
            context.navigation.show(.guide)
        },
        DebugRoute("search[:<query>]", "Search, optionally with a query.") { context, argument in
            context.navigation.show(.search)
            context.navigation.searchText = argument
        },
        DebugRoute("settings", "Settings (the Settings tab on iOS, the Settings window on macOS).") { context, _ in
            if let openSettings = context.openSettings {
                openSettings()
            } else {
                context.navigation.tab = .settings
            }
        },
        DebugRoute("library", "The Library tab (iOS; the Recordings item of the sidebar's Library section on macOS).") { context, _ in
            context.navigation.show(.library)
        },
        DebugRoute("favorites", "Favorites (pushed on the Library tab on iOS).") { context, _ in
            context.navigation.show(.favorites)
        },
        DebugRoute("history", "Recently Watched (pushed on the Library tab on iOS).") { context, _ in
            context.navigation.show(.history)
        },
        DebugRoute("recordings", "Recordings (the Library tab on iOS, the sidebar item on macOS).") { context, _ in
            context.navigation.show(.recordings)
        },
        DebugRoute("playlist:<name|all>", "Selects a playlist (or All Playlists) on Home.") { context, argument in
            let selection: PlaylistSelection
            if argument.lowercased() == "all" {
                selection = .all
            } else {
                selection = .playlist(try context.playlist(named: argument).uuid)
            }
            UserDefaults.fluxo.set(selection.rawValue, forKey: PlaylistSelection.storageKey)
            #if os(macOS)
            if case .playlist(let uuid) = selection {
                context.navigation.sidebarSelection = .playlist(uuid)
            } else {
                context.navigation.sidebarSelection = .home
            }
            #else
            context.navigation.show(.home)
            #endif
        },
        DebugRoute("kind:<live|movies|series>", "Selects the Live TV / Movies / Series section of Home.") { context, argument in
            let kinds: [String: ChannelContentKind] = ["live": .live, "movie": .movie, "movies": .movie, "series": .series]
            guard let kind = kinds[argument.lowercased()] else {
                throw DebugRouteError.invalidArgument("kind", argument)
            }
            // The key of HomeView's @AppStorage.
            UserDefaults.fluxo.set(kind.rawValue, forKey: "home.contentKind")
            context.navigation.show(.home)
        },
        DebugRoute("group:<name>", "Pushes a group's grid on Home.") { context, argument in
            let group = try context.group(named: argument)
            context.navigation.show(.home)
            context.navigation.pushOnHome(group.route)
        },
        DebugRoute("categories:<live|movies|series>", "Pushes the category browser of a kind on Home.") { context, argument in
            let kinds: [String: ChannelContentKind] = ["live": .live, "movie": .movie, "movies": .movie, "series": .series]
            guard let kind = kinds[argument.lowercased()] else {
                throw DebugRouteError.invalidArgument("categories", argument)
            }
            let selection = PlaylistSelection(rawValue: UserDefaults.fluxo.string(forKey: PlaylistSelection.storageKey) ?? "")
            let playlists = (try? context.modelContext.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.createdOn)]))) ?? []
            let scope = LibraryScope(playlists: playlists, selection: selection)
            context.navigation.show(.home)
            context.navigation.pushOnHome(.categories(importIDs: scope.importIDs, kind: kind))
        },
        DebugRoute("browse:<order>[,<layout>]", "Order (playlist, name, recentlyAdded, mostWatched) and layout (list, grid) of every category.") { _, argument in
            let parts = argument.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, let order = ChannelSortOrder(rawValue: first) else {
                throw DebugRouteError.invalidArgument("browse", argument)
            }
            let layout = parts.count > 1 ? CategoryLayout(rawValue: parts[1]) : nil
            var preferences = BrowsePreferences(rawValue: UserDefaults.fluxo.string(forKey: BrowsePreferences.storageKey) ?? "") ?? BrowsePreferences()
            for kind in ChannelContentKind.allCases {
                preferences.setOrder(order, for: kind)
                if let layout {
                    preferences.setLayout(layout, for: kind)
                }
            }
            UserDefaults.fluxo.set(preferences.rawValue, forKey: BrowsePreferences.storageKey)
        },
        DebugRoute("home-section:<forYou|onNow|browse>", "Scrolls Home to a section.") { context, argument in
            context.navigation.show(.home)
            context.navigation.debugHomeSection = nil
            try? await Task.sleep(for: .milliseconds(300))
            context.navigation.debugHomeSection = argument
        },
        DebugRoute("seed-guide", "Adds a sample TV guide for the live channels of every playlist.") { context, _ in
            try DebugGuideSeed.seed(context: context.modelContext, epg: context.epg)
            await context.wait(timeout: 10) { context.epg.hasGuide }
        },
        DebugRoute("add-guide-source[:<days>]", "Adds a guide added by the user (\"Debug Guide\", half-hour programmes for every live channel, 7 days by default).") { context, argument in
            let days = argument.isEmpty ? 7 : Int(argument) ?? -1
            guard (1...14).contains(days) else {
                throw DebugRouteError.invalidArgument("add-guide-source", argument)
            }
            let clock = ContinuousClock()
            let started = clock.now
            let added = try await DebugGuideSeed.addUserSource(container: context.modelContext.container, days: days, epg: context.epg)
            await context.wait(timeout: 10) { context.epg.hasGuide }
            DebugLaunchOptions.logger.notice("Added \(DebugGuideSeed.userSourceName, privacy: .public): \(added.programmes, privacy: .public) programmes in \(clock.now - started, privacy: .public)")
        },
        DebugRoute("delete-guide-source[:<name>]", "Deletes a guide source (the Debug Guide by default) like its Delete button, then checks that nothing of it is left; fails otherwise.") { context, argument in
            try await DebugGuideDeletionCheck.run(context: context, sourceName: argument.isEmpty ? DebugGuideSeed.userSourceName : argument)
        },
        DebugRoute("progress:<channel>", "Marks a movie or episode as watched up to 40 % of 90 minutes (Continue Watching).") { context, argument in
            let item = try context.channel(named: argument)
            context.library.recordWatch(item)
            context.library.saveWatchProgress(for: item, position: 2_160, duration: 5_400)
        },
        DebugRoute("series:<title>", "Pushes the page of a series on Home (by its title).") { context, argument in
            let series = try context.series(named: argument)
            context.navigation.show(.home)
            context.navigation.pushOnHome(series.route)
        },
        DebugRoute("watched:<episode>", "Plays an episode to the end, as far as the library knows (it counts as watched; Continue moves on).") { context, argument in
            let item = try context.channel(named: argument)
            context.library.recordWatch(item)
            context.library.saveWatchProgress(for: item, position: 2_700, duration: 2_700)
        },
        DebugRoute("remove-from-history:<channel>", "Removes a Continue Watching card, like its context menu: for an episode, its whole series.") { context, argument in
            context.library.removeFromContinueWatching(try context.channel(named: argument))
        },
        DebugRoute("featured-series:<playlist>", "Selects a playlist on Home whose billboard then starts with a series.") { context, argument in
            let playlist = try context.playlist(named: argument)
            guard playlist.currentImportID != nil else {
                throw DebugRouteError.notFound("import of playlist", argument)
            }
            UserDefaults.fluxo.set("series", forKey: FeaturedLoader.debugLeadKindKey)
            UserDefaults.fluxo.set(playlist.uuid.uuidString, forKey: PlaylistSelection.storageKey)
            context.navigation.show(.home)
        },
        DebugRoute("featured-seed:<n|next>", "The featured pages (billboard, Apple TV hero) of a given seed, or of the next rotation (as pull to refresh).") { _, argument in
            if argument == "next" {
                FeaturedRotation.shared.debugForcedSeed = nil
                FeaturedRotation.shared.advance()
            } else if let seed = Int64(argument) {
                FeaturedRotation.shared.debugForcedSeed = UInt64(bitPattern: seed)
            } else {
                throw DebugRouteError.invalidArgument("featured-seed", argument)
            }
        },
        DebugRoute("featured-page:<n>", "Shows a page of the featured billboard (the Mac's featured cards, the Apple TV hero), from 0; on iPhone, iPad and Mac it pages as a swipe does.") { _, argument in
            guard let index = Int(argument), index >= 0 else {
                throw DebugRouteError.invalidArgument("featured-page", argument)
            }
            NotificationCenter.default.post(name: .fluxoDebugFeaturedPage, object: index)
        },
        DebugRoute("hide-adult-content:<on|off>", "Settings › Recommendations › Hide adult content from recommendations.") { _, argument in
            guard argument == "on" || argument == "off" else {
                throw DebugRouteError.invalidArgument("hide-adult-content", argument)
            }
            UserDefaults.fluxo.set(argument == "on", forKey: MatureContent.hidesAdultContentKey)
        },
        DebugRoute("legacy-networking:<on|off>", "Settings › Playback › Legacy Networking: the engine reads http(s) inputs with FFmpeg's http protocol.") { _, argument in
            guard argument == "on" || argument == "off" else {
                throw DebugRouteError.invalidArgument("legacy-networking", argument)
            }
            UserDefaults.fluxo.set(argument == "on", forKey: PlayerPreferences.legacyNetworkingKey)
        },
        DebugRoute("favorite-series:<title>", "Adds a series to the favorites.") { context, argument in
            context.library.series.setFavorite(true, for: try context.series(named: argument))
        },
        DebugRoute("schedule:<channel>", "The schedule sheet of a live channel (needs a guide, e.g. seed-guide).") { context, argument in
            context.navigation.scheduleChannel = try context.channel(named: argument)
        },
        DebugRoute(
            "programme:<channel>[,<artwork>][,long][,ended]",
            "Opens the TV Guide and the programme on now on a channel (needs a guide, e.g. seed-guide), with a sample image (\(DebugArtwork.ProgrammeArtwork.allCases.map(\.rawValue).joined(separator: ", ")), or none), with long, a long title and description, and with ended, as the programme that ended just before it."
        ) { context, argument in
            let parts = argument.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else {
                throw DebugRouteError.invalidArgument("programme", argument)
            }
            let options = Set(parts.dropFirst().map { $0.lowercased() })
            let artworks = DebugArtwork.ProgrammeArtwork.allCases.filter { options.contains($0.rawValue) }
            guard options.subtracting(artworks.map(\.rawValue)).subtracting(["none", "long", "ended"]).isEmpty, artworks.count <= 1 else {
                throw DebugRouteError.invalidArgument("programme", argument)
            }
            let item = try context.channel(named: name)
            let importIDs = ((try? context.modelContext.fetch(FetchDescriptor<Playlist>())) ?? []).compactMap(\.currentImportID)
            guard let channel = await context.epg.guideChannels(importIDs: importIDs).first(where: { $0.item.id == item.id }),
                  let programme = await context.epg.nowNext(for: item)?.current else {
                throw DebugRouteError.notFound("programme on now on", name)
            }
            let isLong = options.contains("long")
            let isEnded = options.contains("ended")
            let icon = artworks.first.flatMap(DebugArtwork.programmeArtwork) ?? (options.contains("none") ? nil : programme.icon)
            let shown = GuideProgramme(
                sourceID: programme.sourceID,
                channelID: programme.channelID,
                start: isEnded ? programme.start.addingTimeInterval(-3_600) : programme.start,
                stop: isEnded ? programme.start : programme.stop,
                title: isLong ? "\(programme.title): The Extraordinarily Long Special Edition With an Unusually Verbose Title" : programme.title,
                subtitle: programme.subtitle,
                summary: isLong
                    ? programme.summary + " " + String(repeating: "A long description of the programme, with many details about it. ", count: 12)
                        + "https://guide.seed.fluxo.invalid/programmes/an-unbroken-identifier-without-any-spaces-0123456789abcdefghijklmnopqrstuvwxyz"
                    : programme.summary,
                categories: isLong ? programme.categories + ["Documentary", "Special", "Live Event", "Highlights", "Interviews"] : programme.categories,
                icon: icon,
                episode: programme.episode
            )
            context.navigation.show(.guide)
            context.navigation.debugGuideSelection = GuideSelection(programme: shown, channel: channel)
        },
        DebugRoute("player:<channel>", "Plays a channel full screen.") { context, argument in
            await context.play(try context.channel(named: argument), present: true)
            await context.wait(timeout: 5) { context.player.isPresented }
        },
        DebugRoute("mini-player:<channel>", "Plays a channel with the player closed (the mini player shows).") { context, argument in
            await context.play(try context.channel(named: argument), present: false)
        },
        DebugRoute("copy-link:<channel>", "Copy Link of a channel, as its menu does: the link on the pasteboard and the confirmation toast.") { context, argument in
            let item = try context.channel(named: argument)
            NotificationCenter.default.post(name: .fluxoDebugCopyLink, object: item)
        },
        DebugRoute("play-url:<url>", "Plays a URL full screen.") { context, argument in
            guard let url = URL(string: argument), url.scheme != nil else {
                throw DebugRouteError.invalidArgument("play-url", argument)
            }
            await context.play(PlayableChannel(id: UUID(), name: url.lastPathComponent, logo: nil, url: url), present: true)
            await context.wait(timeout: 5) { context.player.isPresented }
        },
        DebugRoute("play-movie:<url>", "Plays a URL full screen as a playlist's movie (on demand: `.ts` and extensionless links too), like a movie entry.") { context, argument in
            guard let url = URL(string: argument), url.scheme != nil else {
                throw DebugRouteError.invalidArgument("play-movie", argument)
            }
            let item = ChannelItem(id: UUID(), playlistID: UUID(), name: url.lastPathComponent, logo: nil, url: url, groupName: "Movies", kind: .movie)
            await context.prepareForPlayback()
            context.player.play(item, present: true)
            await context.wait(timeout: 5) { context.player.isPresented }
        },
        DebugRoute("close-player", "Closes the player screen; playback continues in the mini player.") { context, _ in
            context.player.isPresented = false
        },
        DebugRoute("dismiss-player", "Closes the player like its chevron or a swipe down (iOS: into Picture in Picture when it can).") { context, _ in
            await context.wait(timeout: 10) { context.player.isPictureInPicturePossible }
            context.player.closePlayer()
            await context.wait(timeout: 4) { !context.player.isPresented }
        },
        DebugRoute("player-drag:<points>", "Holds the player screen dragged down by <points>, as a finger would (0 releases it).") { _, argument in
            guard let points = Double(argument) else {
                throw DebugRouteError.invalidArgument("player-drag", argument)
            }
            #if os(tvOS)
            _ = points
            throw DebugRouteError.unsupported("player-drag")
            #else
            NotificationCenter.default.post(name: .fluxoDebugPlayerDrag, object: CGFloat(points))
            #endif
        },
        DebugRoute("player-controls:<show|hide>", "Shows the player's controls and keeps them on screen (show), or hides them like a tap on the video (hide).") { _, argument in
            let values = ["show": true, "hide": false]
            guard let show = values[argument.lowercased()] else {
                throw DebugRouteError.invalidArgument("player-controls", argument)
            }
            #if os(tvOS)
            _ = show
            throw DebugRouteError.unsupported("player-controls")
            #else
            NotificationCenter.default.post(name: .fluxoDebugPlayerControls, object: show)
            #endif
        },
        DebugRoute("player-guide[:full]", "The player's guide control, like a tap on what is on now: the playing channel's schedule (side panel, foldable pane or sheet); with full, Full Guide (the TV guide at that channel).") { context, argument in
            let option = argument.lowercased()
            guard option.isEmpty || option == "full" else {
                throw DebugRouteError.invalidArgument("player-guide", argument)
            }
            guard context.player.currentItem != nil else {
                throw DebugRouteError.invalidArgument("player-guide", "nothing plays")
            }
            #if os(tvOS)
            throw DebugRouteError.unsupported("player-guide")
            #else
            NotificationCenter.default.post(name: .fluxoDebugPlayerGuide, object: option.isEmpty ? nil : option)
            if option == "full" {
                await context.wait(timeout: 4) { !context.player.isPresented }
            }
            #endif
        },
        DebugRoute("open-player", "Opens the player screen for what plays (from Picture in Picture too), like a tap on the mini player.") { context, _ in
            context.player.presentPlayer()
            await context.wait(timeout: 4) { context.player.isPresented }
        },
        DebugRoute("overscroll:<points>", "Home pulled down by <points> (the billboard stretches over the gap).") { context, argument in
            guard let points = Double(argument) else {
                throw DebugRouteError.invalidArgument("overscroll", argument)
            }
            context.navigation.show(.home)
            context.navigation.debugHomeOverscroll = CGFloat(points)
        },
        DebugRoute("stop", "Stops playback.") { context, _ in
            context.player.stop()
        },
        DebugRoute("skip:<seconds>", "Skips forward (or back, when negative) like the player's skip buttons, then checks that playback continues with video frames.") { context, argument in
            guard let seconds = Double(argument) else {
                throw DebugRouteError.invalidArgument("skip", argument)
            }
            let target = context.player.timeline.currentTime + seconds
            context.player.skip(by: seconds)
            try await DebugPlaybackProbe.check(context.player, near: target, route: "skip:\(argument)")
        },
        DebugRoute("seek:<seconds|percent%>", "Seeks like the scrubber (to a time, or a percentage of the duration), then checks that playback continues with video frames.") { context, argument in
            let duration = context.player.timeline.duration
            let target: TimeInterval
            if argument.hasSuffix("%"), let percent = Double(argument.dropLast()), duration > 0 {
                target = duration * percent / 100
            } else if let seconds = Double(argument) {
                target = seconds
            } else {
                throw DebugRouteError.invalidArgument("seek", argument)
            }
            context.player.seek(toSeconds: target)
            try await DebugPlaybackProbe.check(context.player, near: target, route: "seek:\(argument)")
        },
        DebugRoute("drag:<from>-<to>", "Drags the scrubber from one point to another (seconds or percentages, e.g. drag:10%-40%) in 20 moves over 0.8 s, releases it, then checks that playback continues there with video frames.") { context, argument in
            let parts = argument.split(separator: "-").map(String.init)
            guard parts.count == 2, let from = DebugRoutes.position(parts[0], in: context.player), let to = DebugRoutes.position(parts[1], in: context.player) else {
                throw DebugRouteError.invalidArgument("drag", argument)
            }
            for step in 1...20 {
                context.player.debugScrubHold = from + (to - from) * Double(step) / 20
                try? await Task.sleep(for: .milliseconds(40))
            }
            context.player.debugScrubHold = nil
            try await DebugPlaybackProbe.check(context.player, near: to, route: "drag:\(argument)")
        },
        DebugRoute("scrub-hold:<seconds|percent%>", "Holds the scrubber at a point as a finger would (the time and the frame preview over it), until scrub-release.") { context, argument in
            guard let time = DebugRoutes.position(argument, in: context.player) else {
                throw DebugRouteError.invalidArgument("scrub-hold", argument)
            }
            context.player.debugScrubHold = time
            // The frame preview comes from the network for a movie AVPlayer plays itself.
            await context.wait(timeout: 6) { context.player.scrubPreview.image != nil || !context.player.scrubPreview.isActive }
        },
        DebugRoute("scrub-release", "Releases the scrubber held by scrub-hold (it seeks there); add probe-playback to check playback.") { context, _ in
            context.player.debugScrubHold = nil
        },
        DebugRoute("skip-burst:<seconds>x<count>", "Taps a skip button <count> times 150 ms apart (e.g. skip-burst:30x4): the taps add up into one seek. Then checks that playback continues there with video frames.") { context, argument in
            let parts = argument.split(separator: "x").map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]), let count = Int(parts[1]), count > 0 else {
                throw DebugRouteError.invalidArgument("skip-burst", argument)
            }
            let target = context.player.timeline.currentTime + seconds * Double(count)
            for _ in 0..<count {
                context.player.skip(by: seconds)
                try? await Task.sleep(for: .milliseconds(150))
            }
            try await DebugPlaybackProbe.check(context.player, near: context.player.seeker.target ?? target, route: "skip-burst:\(argument)")
        },
        DebugRoute("seek-pause:<seconds|percent%>", "Seeks, pauses at once, plays 2 s later, then checks that playback continues there with video frames.") { context, argument in
            guard let time = DebugRoutes.position(argument, in: context.player) else {
                throw DebugRouteError.invalidArgument("seek-pause", argument)
            }
            context.player.seek(toSeconds: time)
            context.player.pause()
            try? await Task.sleep(for: .seconds(2))
            context.player.play()
            try await DebugPlaybackProbe.check(context.player, near: time, route: "seek-pause:\(argument)")
        },
        DebugRoute("seek-past-buffer[:direct]", "Seeks like the scrubber to just past what the player buffered (the segment the engine may have written ahead from inside a GOP, which the player asks for as the next one), then checks that playback continues there, at the target, with video frames. `direct` seeks AVPlayer itself, as Picture in Picture's skip buttons do (not through the seeker).") { context, argument in
            let player = context.player
            guard let item = player.player.currentItem else {
                throw DebugRouteError.check("seek-past-buffer: nothing plays")
            }
            let now = item.currentTime().seconds
            let ranges = item.loadedTimeRanges.map(\.timeRangeValue).filter { $0.start.isNumeric && $0.duration.isNumeric }
            guard let range = ranges.first(where: { $0.start.seconds <= now + 0.5 && $0.start.seconds + $0.duration.seconds >= now }) else {
                throw DebugRouteError.check("seek-past-buffer: nothing buffered at \(Int(now)) s")
            }
            let target = range.start.seconds + range.duration.seconds + 1
            guard target < player.timeline.duration - 20 else {
                throw DebugRouteError.check("seek-past-buffer: buffered to the end")
            }
            DebugLaunchOptions.logger.notice("seek-past-buffer: buffered to \(target - 1, format: .fixed(precision: 1)) s, seeking to \(target, format: .fixed(precision: 1)) s\(argument == "direct" ? " (AVPlayer directly)" : "", privacy: .public)")
            // As in Picture in Picture (`AVPlayerViewModel.itemTimeJumped`), until the check is over.
            player.debugTreatsJumpsAsPictureInPicture = argument == "direct"
            defer {
                player.debugTreatsJumpsAsPictureInPicture = false
            }
            if argument == "direct" {
                let tolerance = CMTime(value: 1, timescale: 4)
                player.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in }
            } else {
                player.seek(toSeconds: target)
            }
            try await DebugPlaybackProbe.check(player, near: target, route: "seek-past-buffer:\(argument)", tolerance: 3)
        },
        DebugRoute("seek-fail:<seconds|percent%>", "Shows a seek there that could not play, as after every recovery: Try Again over the timeline, the announcement (screenshots, accessibility checks).") { context, argument in
            guard let time = DebugRoutes.position(argument, in: context.player) else {
                throw DebugRouteError.invalidArgument("seek-fail", argument)
            }
            context.player.player.pause()
            context.player.seeker.debugFail(at: time)
        },
        DebugRoute("seek-drop:<count|all>x<seconds|percent%>", "Seeks there while AVPlayer drops that many seeks in a row (as it does while it starts an item), or every seek; then checks that the seek plays at the target (a count), or ends with Try Again (`all`), and never stays loading.") { context, argument in
            let parts = argument.split(separator: "x", maxSplits: 1).map(String.init)
            guard parts.count == 2, let time = DebugRoutes.position(parts[1], in: context.player) else {
                throw DebugRouteError.invalidArgument("seek-drop", argument)
            }
            let dropsAll = parts[0] == "all"
            guard dropsAll || Int(parts[0]) != nil else {
                throw DebugRouteError.invalidArgument("seek-drop", argument)
            }
            var remaining = dropsAll ? Int.max : Int(parts[0]) ?? 0
            let seeker = context.player.seeker
            seeker.seekInterceptor = { completion in
                guard remaining > 0 else {
                    return false
                }
                remaining -= 1
                // As AVPlayer does: completed a moment later, not finished.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    completion(false)
                }
                return true
            }
            // The view model's handler, and whether the seek failed (it may then play at the target after all: the
            // last recovery's new item starts there by itself, `PlayerSeeker.positionChanged()`).
            let onFailed = seeker.onFailed
            var didFail = false
            seeker.onFailed = { target in
                didFail = true
                onFailed?(target)
            }
            defer {
                seeker.seekInterceptor = nil
                seeker.onFailed = onFailed
            }
            let begin = ContinuousClock.now
            context.player.seek(toSeconds: time)
            if dropsAll {
                // The recovery may move the movie to another route (or item) at the target first: its resume seek is
                // dropped too, and only then the seek fails.
                await context.wait(timeout: 40) { didFail }
            } else {
                await context.wait(timeout: 30) { !seeker.isBusy }
            }
            let elapsed = ContinuousClock.now - begin
            DebugLaunchOptions.logger.notice("seek-drop:\(argument, privacy: .public): \(String(describing: seeker.phase), privacy: .public)\(didFail ? " (failed)" : "", privacy: .public) after \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)), privacy: .public)")
            if dropsAll {
                guard didFail else {
                    throw DebugRouteError.check("seek-drop:\(argument): \(seeker.phase), never failed")
                }
            } else {
                guard seeker.phase == .idle else {
                    throw DebugRouteError.check("seek-drop:\(argument): \(seeker.phase) after \(elapsed)")
                }
                try await DebugPlaybackProbe.check(context.player, near: time, route: "seek-drop:\(argument)")
            }
        },
        DebugRoute("seek-loading:<seconds|percent%>", "Seeks like the scrubber and returns at once, while the seek loads (screenshots of the loading state).") { context, argument in
            guard let time = DebugRoutes.position(argument, in: context.player) else {
                throw DebugRouteError.invalidArgument("seek-loading", argument)
            }
            context.player.seek(toSeconds: time)
            try? await Task.sleep(for: .milliseconds(300))
        },
        DebugRoute("probe-playback[:<seconds>]", "Checks that playback continues with video frames (near <seconds>, when given).") { context, argument in
            try await DebugPlaybackProbe.check(context.player, near: Double(argument), route: "probe-playback")
        },
        DebugRoute("probe-tracks[:<a|v|av>]", "Checks that what plays has enabled audio and / or video tracks (default both) and logs their formats.") { context, argument in
            try await DebugPlaybackProbe.checkTracks(context.player, expecting: argument.isEmpty ? "av" : argument, route: "probe-tracks")
        },
        DebugRoute("tv-seek:<seconds|percent%>", "Apple TV: seeks like the system player's transport bar (a scrub committed with a click: it asks its delegate, then seeks AVPlayer itself, exactly), then checks that playback continues there with video frames and logs the latency.") { context, argument in
            guard let target = DebugRoutes.position(argument, in: context.player) else {
                throw DebugRouteError.invalidArgument("tv-seek", argument)
            }
            #if os(tvOS)
            TVSystemPlayer.shared.debugNavigate(to: target)
            try await DebugPlaybackProbe.check(context.player, near: target, route: "tv-seek:\(argument)")
            #else
            throw DebugRouteError.unsupported("tv-seek")
            #endif
        },
        DebugRoute("tv-skip:<seconds>", "Apple TV: a skip of the transport bar (a click on the left or right of the clickpad: 10 s), from where playback is, then the same check.") { context, argument in
            guard let seconds = Double(argument) else {
                throw DebugRouteError.invalidArgument("tv-skip", argument)
            }
            #if os(tvOS)
            let target = max(0, context.player.player.currentTime().seconds + seconds)
            TVSystemPlayer.shared.debugNavigate(to: target)
            try await DebugPlaybackProbe.check(context.player, near: target, route: "tv-skip:\(argument)")
            #else
            throw DebugRouteError.unsupported("tv-skip")
            #endif
        },
        DebugRoute("tv-zap:<next|previous>[,hold]", "Apple TV: channel up / down as the system player asks for it (a TV remote's channel buttons): the interstice of the channel it goes to until that channel plays, as AVKit shows it, then the switch (its banner); with hold the interstice stays until tv-zap-close (screenshots of it).") { context, argument in
            let offsets = ["next": 1, "up": 1, "previous": -1, "down": -1]
            let parts = argument.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, let offset = offsets[first], parts.count == 1 || parts.last == "hold" else {
                throw DebugRouteError.invalidArgument("tv-zap", argument)
            }
            #if os(tvOS)
            let holds = parts.count == 2
            let player = TVSystemPlayer.shared
            var isDone = false
            guard let interstitial = player.debugZap(by: offset, completion: { _ in isDone = true }) else {
                throw DebugRouteError.check("tv-zap: no channel to switch to (not a live channel of a playlist, or recording)")
            }
            interstitial.modalPresentationStyle = .fullScreen
            player.container.present(interstitial, animated: true)
            if holds {
                try? await Task.sleep(for: .milliseconds(600))
            } else {
                await context.wait(timeout: 10) { isDone }
                interstitial.dismiss(animated: true)
                try? await Task.sleep(for: .milliseconds(800))
            }
            #else
            _ = offset
            throw DebugRouteError.unsupported("tv-zap")
            #endif
        },
        DebugRoute("tv-panel:<guide|channels|episodes>", "Apple TV: a tab of the player's info panel, drawn as the system lays it out over the video (the Siri Remote's swipe down cannot be scripted), until tv-panel-close.") { _, argument in
            #if os(tvOS)
            guard let tab = TVPlayerChrome.Tab(rawValue: argument.lowercased()) else {
                throw DebugRouteError.invalidArgument("tv-panel", argument)
            }
            guard let panel = TVSystemPlayer.shared.debugPanel(tab) else {
                throw DebugRouteError.check("tv-panel: the player is not on screen")
            }
            TVSystemPlayer.shared.container.present(panel, animated: true)
            try? await Task.sleep(for: .seconds(2))
            #else
            throw DebugRouteError.unsupported("tv-panel")
            #endif
        },
        DebugRoute("tv-panel-close", "Apple TV: closes the panel of tv-panel.") { _, _ in
            #if os(tvOS)
            TVSystemPlayer.shared.container.presentedViewController?.dismiss(animated: true)
            try? await Task.sleep(for: .milliseconds(600))
            #else
            throw DebugRouteError.unsupported("tv-panel-close")
            #endif
        },
        DebugRoute("tv-zap-close", "Apple TV: closes the channel interstice of tv-zap.") { _, _ in
            #if os(tvOS)
            TVSystemPlayer.shared.container.presentedViewController?.dismiss(animated: true)
            try? await Task.sleep(for: .milliseconds(600))
            #else
            throw DebugRouteError.unsupported("tv-zap-close")
            #endif
        },
        DebugRoute("pause", "Pauses playback (Apple TV: the transport bar then shows).") { context, _ in
            context.player.pause()
            try? await Task.sleep(for: .milliseconds(800))
            #if os(tvOS)
            DebugLaunchOptions.logger.notice("TV player: \(TVSystemPlayer.shared.debugSummary, privacy: .public)")
            #endif
        },
        DebugRoute("resume", "Resumes playback.") { context, _ in
            context.player.play()
        },
        DebugRoute("record:<start|stop>", "Starts or stops recording the live channel that plays (through the engine).") { context, argument in
            switch argument.lowercased() {
            case "start":
                await context.wait(timeout: 15) { context.player.canRecord }
                context.player.startRecording()
                await context.wait(timeout: 5) { context.player.isRecording }
            case "stop":
                context.player.stopRecording()
                await context.wait(timeout: 10) { !context.player.isRecording }
            default:
                throw DebugRouteError.invalidArgument("record", argument)
            }
        },
        DebugRoute("play-recording", "Plays the newest recording full screen, as its row in the library does (once its conversion to MP4 is done, 30 s at most).") { context, _ in
            let recordings = context.player.recordings
            await context.wait(timeout: 30) { recordings.recordings.contains { !$0.isFinalizing && !$0.isRecording } }
            guard let recording = recordings.recordings.filter({ !$0.isFinalizing && !$0.isRecording }).max(by: { $0.createdOn < $1.createdOn }) else {
                throw DebugRouteError.check("play-recording: no recording")
            }
            await context.prepareForPlayback()
            context.player.playRecording(recording)
            await context.wait(timeout: 5) { context.player.isPresented }
        },
        DebugRoute("pip", "Starts Picture in Picture once the playing item allows it.") { context, _ in
            await context.wait { context.player.isPictureInPicturePossible }
            if !context.player.isPictureInPictureActive {
                context.player.togglePictureInPicture()
            }
        },
        DebugRoute("fill:<on|off>", "Fills the screen with the video (on), cropping its edges, or fits it (off), like the player's Fill button.") { context, argument in
            let values = ["on": true, "off": false]
            guard let fills = values[argument.lowercased()] else {
                throw DebugRouteError.invalidArgument("fill", argument)
            }
            if context.player.fillsScreen != fills {
                context.player.toggleFillsScreen()
            }
        },
        DebugRoute("cast-picker", "The Cast device picker (with the simulated receiver of `cast:`, or the real SDK).") { context, _ in
            context.player.cast.presentPicker()
        },
        DebugRoute("cast:<device>", "Connects to a simulated Chromecast (Living Room TV, Bedroom, Kitchen Speaker) and casts what plays.") { context, argument in
            let cast = context.player.cast
            cast.debugUseSimulatedReceiver()
            await context.wait(timeout: 5) { !cast.devices.isEmpty }
            guard let device = cast.devices.first(where: { $0.name.localizedCaseInsensitiveContains(argument) }) ?? (argument.isEmpty ? cast.devices.first : nil) else {
                throw DebugRouteError.notFound("Cast device", argument)
            }
            cast.connect(to: device)
            await context.wait(timeout: 8) { cast.isConnected && (context.player.currentChannel == nil || !context.player.playbackState.isBusy) }
        },
        DebugRoute("stop-casting", "Ends the Cast session; the channel plays on this device again.") { context, _ in
            context.player.stopCasting()
            await context.wait(timeout: 5) { !context.player.cast.isConnected }
        },
        DebugRoute("add-playlist", "The Add Playlist sheet.") { context, _ in
            context.playlistActions.add()
        },
        DebugRoute("edit-playlist:<name>", "The Edit Playlist sheet.") { context, argument in
            context.playlistActions.edit(try context.playlist(named: argument))
        },
        DebugRoute("delete-playlist:<name>", "The delete confirmation (nothing is deleted).") { context, argument in
            context.playlistActions.requestDelete(try context.playlist(named: argument))
        },
        DebugRoute("posture:<closed|book|flat|tabletop|real>", "Simulates the hinge of the iPhone Duo (see DebugPosture.swift); real stops simulating.") { _, argument in
            #if os(iOS)
            let value = argument.lowercased()
            guard value == "real" || DebugPostureSimulation.Mode(rawValue: value) != nil else {
                throw DebugRouteError.invalidArgument("posture", argument)
            }
            DebugPostureSimulation.shared.mode = DebugPostureSimulation.Mode(rawValue: value)
            #endif
        },
        DebugRoute("orientation:<portrait|landscape>", "Rotates the interface (iOS; the simulator has no rotation command).") { _, argument in
            #if os(iOS)
            let masks: [String: UIInterfaceOrientationMask] = ["portrait": .portrait, "landscape": .landscapeRight]
            guard let mask = masks[argument.lowercased()] else {
                throw DebugRouteError.invalidArgument("orientation", argument)
            }
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                // `@Sendable`: UIKit does not say on which queue it reports the error.
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { @Sendable error in
                    DebugLaunchOptions.logger.error("Rotation failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            try? await Task.sleep(for: .seconds(1))
            #endif
        },
        DebugRoute("window-size:<width>x<height>", "Resizes the app's main window to that content size in points and centers it (macOS; for screenshots). Its frame is no longer saved, so the user's own window size stays as it was.") { _, argument in
            #if os(macOS)
            let parts = argument.lowercased().split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, parts.allSatisfy({ $0 >= 200 }) else {
                throw DebugRouteError.invalidArgument("window-size", argument)
            }
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                throw DebugRouteError.notFound("window", "main")
            }
            // A debug run shares the container, and so the saved window frames, with the user's copy of the app.
            window.setFrameAutosaveName("")
            window.setContentSize(NSSize(width: parts[0], height: parts[1]))
            window.center()
            try? await Task.sleep(for: .seconds(1))
            #else
            throw DebugRouteError.unsupported("window-size")
            #endif
        },
        DebugRoute("side-panel:<channels|guide|off>", "Shows the player's side panel (wide players) on a tab, or hides it.") { _, argument in
            #if os(tvOS)
            throw DebugRouteError.unsupported("side-panel")
            #else
            let defaults = UserDefaults.fluxo
            if let tab = PlayerSidePanelTab(rawValue: argument.lowercased()) {
                defaults.set(tab.rawValue, forKey: PlayerSidePanelLayout.tabStorageKey)
                defaults.set(true, forKey: PlayerSidePanelLayout.storageKey)
            } else if argument.lowercased() == "off" {
                defaults.set(false, forKey: PlayerSidePanelLayout.storageKey)
            } else {
                throw DebugRouteError.invalidArgument("side-panel", argument)
            }
            #endif
        },
        DebugRoute("new-window:<channel>", "Opens a channel in a player window of its own (iPad).") { context, argument in
            let item = try context.channel(named: argument)
            guard context.openChannelWindow.isAvailable else {
                throw DebugRouteError.invalidArgument("new-window", "this device has a single window")
            }
            context.openChannelWindow(item)
            await context.wait(timeout: 6) { context.player.isPresented }
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.count
            DebugLaunchOptions.logger.notice("Connected scenes: \(scenes, privacy: .public)")
            #endif
        },
        DebugRoute("seek-end:<seconds>", "Seeks the playing on-demand item to that many seconds before its end (once it can seek).") { context, argument in
            guard let seconds = Double(argument) else {
                throw DebugRouteError.invalidArgument("seek-end", argument)
            }
            await context.wait(timeout: 20) { context.player.canSeek && context.player.timeline.duration > 0 }
            context.player.seek(toSeconds: max(0, context.player.timeline.duration - seconds))
        },
        DebugRoute("audio-track:<name|number>", "Chooses an audio track of what plays, by name (\"Italian\") or number (1-based), as the Audio and Subtitles menu does.") { context, argument in
            let tracks = context.player.mediaSelection
            await context.wait(timeout: 15) { tracks.audioTracks.count > 1 }
            guard let track = DebugRoutes.track(argument, in: tracks.audioTracks) else {
                throw DebugRouteError.notFound("audio track", argument)
            }
            tracks.selectAudioTrack(track.id)
            DebugRoutes.logTracks(tracks)
        },
        DebugRoute("subtitles:<automatic|off|file|name|number>", "Chooses the subtitles of what plays, as the Audio and Subtitles menu does.") { context, argument in
            let tracks = context.player.mediaSelection
            await context.wait(timeout: 15) { !tracks.subtitleTracks.isEmpty || tracks.externalSubtitles != nil }
            switch argument.lowercased() {
            case "automatic", "auto":
                tracks.selectSubtitles(.automatic)
            case "off":
                tracks.selectSubtitles(.off)
            case "file":
                tracks.selectSubtitles(.external)
            default:
                guard let track = DebugRoutes.track(argument, in: tracks.subtitleTracks) else {
                    throw DebugRouteError.notFound("subtitle track", argument)
                }
                tracks.selectSubtitles(.track(track.id))
            }
            DebugRoutes.logTracks(tracks)
        },
        DebugRoute("subtitle-file:<url>", "Loads a subtitle file (.srt / .vtt; a file or http URL, e.g. the test server's /subtitles/clip.srt) for what plays, as Load Subtitle File… does.") { context, argument in
            guard let url = URL(string: argument), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
                throw DebugRouteError.invalidArgument("subtitle-file", argument)
            }
            let tracks = context.player.mediaSelection
            await context.wait(timeout: 15) { tracks.allowsExternalSubtitles }
            var file = url
            if !url.isFileURL {
                // The importer hands over a local file: download it first.
                let (data, _) = try await URLSession.shared.data(from: url)
                file = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent.isEmpty ? "subtitles.srt" : url.lastPathComponent)
                try data.write(to: file, options: .atomic)
            }
            tracks.loadExternalSubtitles(from: file)
            await context.wait(timeout: 5) { tracks.externalSubtitles != nil || tracks.externalSubtitleError != nil }
            if let error = tracks.externalSubtitleError {
                throw DebugRouteError.invalidArgument("subtitle-file", error)
            }
            DebugRoutes.logTracks(tracks)
        },
        DebugRoute("subtitle-offset:<seconds>", "Shifts a loaded subtitle file (positive: later), as Subtitle Timing does.") { context, argument in
            guard let seconds = Double(argument) else {
                throw DebugRouteError.invalidArgument("subtitle-offset", argument)
            }
            let tracks = context.player.mediaSelection
            tracks.adjustExternalSubtitleOffset(by: seconds - tracks.externalSubtitleOffset)
        },
        DebugRoute("tracks-log", "Logs the audio tracks and subtitles of what plays and the choices (in app.log).") { context, _ in
            let tracks = context.player.mediaSelection
            await context.wait(timeout: 15) { tracks.hasChoices }
            DebugRoutes.logTracks(tracks)
        },
        DebugRoute("wait:<seconds>", "Waits before the next route.") { _, argument in
            guard let seconds = Double(argument), seconds >= 0 else {
                throw DebugRouteError.invalidArgument("wait", argument)
            }
            try await Task.sleep(for: .seconds(seconds))
        },
        DebugRoute("topshelf[:<sections>]", "Apple TV: waits (up to 30 s) until the Top Shelf snapshot written for the library shown has the given sections (`continueWatching,favorites,onNow`, default any), and logs it; fails without the App Group.") { _, argument in
            #if os(tvOS)
            let wanted = Set(argument.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            guard TopShelfStorage.directory != nil else {
                throw DebugRouteError.check("no App Group container (build with Tools/Simulator/build.sh --platform tvos, which signs the app)")
            }
            let deadline = ContinuousClock.now + .seconds(30)
            while true {
                // Written by this launch (the publisher always writes its first snapshot).
                if TopShelfPublisher.shared.lastPublishedAt != nil, let snapshot = TopShelfStorage.read() {
                    let kinds = Set(snapshot.sections.map(\.kind.rawValue))
                    if wanted.isSubset(of: kinds) {
                        let summary = snapshot.sections.map { section in
                            "\(section.kind.rawValue) [\(section.items.map(\.title).joined(separator: " | "))]"
                        }.joined(separator: "; ")
                        DebugLaunchOptions.logger.notice("Top Shelf: \(summary, privacy: .public)")
                        return
                    }
                }
                guard ContinuousClock.now < deadline else {
                    throw DebugRouteError.check("the Top Shelf snapshot has \(TopShelfStorage.read()?.sections.map(\.kind.rawValue) ?? []), not \(wanted.sorted())")
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            #else
            throw DebugRouteError.unsupported("topshelf")
            #endif
        },
        DebugRoute("topshelf-artwork-check", "Apple TV: a Top Shelf image whose logo cannot be loaded (cancelled while it loads, then a refused 127.0.0.1 URL) is never cached as that logo's image.") { _, _ in
            #if os(tvOS)
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory.appending(path: "topshelf-artwork-check-\(UUID().uuidString)")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: directory) }
            func files() -> [String] {
                ((try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
            }
            // Port 9 (discard) on the loopback: nothing listens, the connection is refused at once.
            let art = TopShelfArt(logo: "http://127.0.0.1:9/fluxo-missing-logo.png", name: "Missing Logo", kind: .live, isLive: false)
            let cancelled = Task { await TopShelfArtworkRenderer.write(art, to: directory) }
            cancelled.cancel()
            let cancelledNames = await cancelled.value
            guard cancelledNames == nil, files().isEmpty else {
                throw DebugRouteError.check("a cancelled write returned \(String(describing: cancelledNames)) and left \(files())")
            }
            let names = await TopShelfArtworkRenderer.write(art, to: directory)
            let placeholder = art.placeholder.fileStem
            guard let names, names == ("\(placeholder).jpg", "\(placeholder)@2x.jpg"),
                  files() == ["\(placeholder)@2x.jpg", "\(placeholder).jpg"].sorted(),
                  !files().contains(where: { $0.hasPrefix(art.fileStem) }) else {
                throw DebugRouteError.check("a logo that failed wrote \(files()) (names \(String(describing: names))), art \(art.fileStem), placeholder \(placeholder)")
            }
            DebugLaunchOptions.logger.notice("Top Shelf artwork check: cancelled wrote nothing; failed logo drawn as \(placeholder, privacy: .public), not cached as \(art.fileStem, privacy: .public)")
            #else
            throw DebugRouteError.unsupported("topshelf-artwork-check")
            #endif
        },
        DebugRoute("help", "Logs this list.") { _, _ in
            DebugLaunchOptions.logger.notice("\(DebugRoutes.helpText, privacy: .public)")
        },
    ] + DebugIntentRoutes.all + DebugDownloadRoutes.all + DebugLibraryRoutes.all + DebugPowerRoutes.all + DebugCloud.routes + DebugModalRoutes.all

    /// A track by number (1-based) or by name (exact, then contained), for the track routes.
    static func track(_ argument: String, in tracks: [MediaSelectionController.Track]) -> MediaSelectionController.Track? {
        if let number = Int(argument), tracks.indices.contains(number - 1) {
            return tracks[number - 1]
        }
        return tracks.first { $0.title.caseInsensitiveCompare(argument) == .orderedSame }
            ?? tracks.first { $0.menuTitle.localizedCaseInsensitiveContains(argument) }
    }

    static func logTracks(_ tracks: MediaSelectionController) {
        let audio = tracks.audioTracks.map { "\($0.id == tracks.selectedAudioTrack ? "*" : "")\($0.menuTitle)" }.joined(separator: ", ")
        let subtitles = tracks.subtitleTracks.map(\.menuTitle).joined(separator: ", ")
        let file = tracks.externalSubtitles.map { "\($0.fileName) (\($0.file.cues.count) cues)" } ?? "-"
        DebugLaunchOptions.logger.notice("Tracks: audio [\(audio, privacy: .public)] subtitles [\(subtitles, privacy: .public)] choice \(String(describing: tracks.subtitleChoice), privacy: .public) file \(file, privacy: .public) cast \(tracks.isShowingCastTracks, privacy: .public)")
    }

    /// The route registered under the name of `step` ("name" or "name:argument").
    static func resolve(_ step: String) -> (DebugRoute, String)? {
        let parts = step.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        guard let route = all.first(where: { registeredName(of: $0) == name }) else {
            return nil
        }
        return (route, argument)
    }

    static var helpText: String {
        "Debug routes (-FluxoDebugRoute \"a;b:arg\"):\n" + all.map { "  \($0.name)  \($0.summary)" }.joined(separator: "\n")
    }

    /// "tab:<…>" and "search[:<…>]" are registered as "tab" and "search".
    private static func registeredName(of route: DebugRoute) -> String {
        String(route.name.prefix { $0 != ":" && $0 != "[" })
    }
}
#endif
