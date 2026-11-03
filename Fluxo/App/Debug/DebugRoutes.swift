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
    /// Opens the Settings window (macOS); nil on iOS, where Settings is a tab.
    let openSettings: (() -> Void)?

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
        DebugRoute("tab:<home|guide|favorites|settings|search>", "Selects a tab (iOS).") { context, argument in
            let tabs: [String: AppNavigation.Tab] = [
                "home": .home, "guide": .guide, "favorites": .favorites, "settings": .settings, "search": .search,
            ]
            guard let tab = tabs[argument.lowercased()] else {
                throw DebugRouteError.invalidArgument("tab", argument)
            }
            context.navigation.tab = tab
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
        DebugRoute("stop", "Stops playback.") { context, _ in
            context.player.stop()
        },
        DebugRoute("pip", "Starts Picture in Picture once the playing item allows it.") { context, _ in
            await context.wait { context.player.isPictureInPicturePossible }
            if !context.player.isPictureInPictureActive {
                context.player.togglePictureInPicture()
            }
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
