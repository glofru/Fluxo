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
import SwiftData
import SwiftUI

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

    private func prepareForPlayback() async {
        // A sheet would hide both the full-screen player and the mini player, and a full-screen cover presented
        // while the sheet is still animating away is dropped: close it and let the dismissal finish first.
        if navigation.isShowingRecordings {
            navigation.isShowingRecordings = false
            try? await Task.sleep(for: .milliseconds(800))
        }
        player.presentationSourceID = nil
    }
}

enum DebugRouteError: LocalizedError {
    case notFound(String, String)
    case invalidArgument(String, String)

    var errorDescription: String? {
        switch self {
        case let .notFound(kind, name):
            return "No \(kind) named \"\(name)\""
        case let .invalidArgument(route, argument):
            return "Invalid argument \"\(argument)\" for \(route)"
        }
    }
}

@MainActor
enum DebugRoutes {

    static let all: [DebugRoute] = [
        DebugRoute("home", "Home, from its root.") { context, _ in
            context.navigation.show(.home)
        },
        DebugRoute("tab:<home|guide|favorites|settings|search|history|recordings|playlist name>", "Selects a tab (iOS; history, recordings and playlists are iPad sidebar entries).") { context, argument in
            let tabs: [String: AppNavigation.Tab] = [
                "home": .home, "guide": .guide, "favorites": .favorites, "settings": .settings, "search": .search,
                "history": .history, "recordings": .recordings,
            ]
            if let tab = tabs[argument.lowercased()] {
                context.navigation.tab = tab
            } else {
                context.navigation.tab = .playlist(try context.playlist(named: argument).uuid)
            }
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
        DebugRoute("favorites", "Favorites.") { context, _ in
            context.navigation.show(.favorites)
        },
        DebugRoute("history", "Recently Watched.") { context, _ in
            context.navigation.show(.history)
        },
        DebugRoute("recordings", "Recordings (the sheet on iOS, the sidebar item on macOS).") { context, _ in
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
        DebugRoute("schedule:<channel>", "The schedule sheet of a live channel (needs a guide, e.g. seed-guide).") { context, argument in
            context.navigation.scheduleChannel = try context.channel(named: argument)
        },
        DebugRoute(
            "programme:<channel>[,<artwork>][,long]",
            "Opens the TV Guide and the programme on now on a channel (needs a guide, e.g. seed-guide), with a sample image (\(DebugArtwork.ProgrammeArtwork.allCases.map(\.rawValue).joined(separator: ", ")), or none) and, with long, a long title and description."
        ) { context, argument in
            let parts = argument.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else {
                throw DebugRouteError.invalidArgument("programme", argument)
            }
            let options = Set(parts.dropFirst().map { $0.lowercased() })
            let artworks = DebugArtwork.ProgrammeArtwork.allCases.filter { options.contains($0.rawValue) }
            guard options.subtracting(artworks.map(\.rawValue)).subtracting(["none", "long"]).isEmpty, artworks.count <= 1 else {
                throw DebugRouteError.invalidArgument("programme", argument)
            }
            let item = try context.channel(named: name)
            let importIDs = ((try? context.modelContext.fetch(FetchDescriptor<Playlist>())) ?? []).compactMap(\.currentImportID)
            guard let channel = await context.epg.guideChannels(importIDs: importIDs).first(where: { $0.item.id == item.id }),
                  let programme = await context.epg.nowNext(for: item)?.current else {
                throw DebugRouteError.notFound("programme on now on", name)
            }
            let isLong = options.contains("long")
            let icon = artworks.first.flatMap(DebugArtwork.programmeArtwork) ?? (options.contains("none") ? nil : programme.icon)
            let shown = GuideProgramme(
                sourceID: programme.sourceID,
                channelID: programme.channelID,
                start: programme.start,
                stop: programme.stop,
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
        DebugRoute("play-url:<url>", "Plays a URL full screen.") { context, argument in
            guard let url = URL(string: argument), url.scheme != nil else {
                throw DebugRouteError.invalidArgument("play-url", argument)
            }
            await context.play(PlayableChannel(id: UUID(), name: url.lastPathComponent, logo: nil, url: url), present: true)
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
            NotificationCenter.default.post(name: .fluxoDebugPlayerDrag, object: CGFloat(points))
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
        DebugRoute("pip", "Starts Picture in Picture once the playing item allows it.") { context, _ in
            await context.wait { context.player.isPictureInPicturePossible }
            if !context.player.isPictureInPictureActive {
                context.player.togglePictureInPicture()
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
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                    DebugLaunchOptions.logger.error("Rotation failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            try? await Task.sleep(for: .seconds(1))
            #endif
        },
        DebugRoute("side-panel:<channels|guide|off>", "Shows the player's side panel (wide players) on a tab, or hides it.") { _, argument in
            let defaults = UserDefaults.fluxo
            if let tab = PlayerSidePanelTab(rawValue: argument.lowercased()) {
                defaults.set(tab.rawValue, forKey: PlayerSidePanelLayout.tabStorageKey)
                defaults.set(true, forKey: PlayerSidePanelLayout.storageKey)
            } else if argument.lowercased() == "off" {
                defaults.set(false, forKey: PlayerSidePanelLayout.storageKey)
            } else {
                throw DebugRouteError.invalidArgument("side-panel", argument)
            }
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
        DebugRoute("wait:<seconds>", "Waits before the next route.") { _, argument in
            guard let seconds = Double(argument), seconds >= 0 else {
                throw DebugRouteError.invalidArgument("wait", argument)
            }
            try await Task.sleep(for: .seconds(seconds))
        },
        DebugRoute("help", "Logs this list.") { _, _ in
            DebugLaunchOptions.logger.notice("\(DebugRoutes.helpText, privacy: .public)")
        },
    ]

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
