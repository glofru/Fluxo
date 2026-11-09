//
//  FluxoShortcuts.swift
//  Fluxo
//
//  The App Shortcuts: Siri phrases that work as soon as the app is installed, and the tiles of Fluxo in the
//  Shortcuts app and Spotlight. Every intent is also available as an action in the Shortcuts app; Pause and
//  Resume need no phrase, since Siri's own "Pause" / "Resume" reach Fluxo's Now Playing session.
//
//  Channel phrases ("Play Sky Sport F1 in Fluxo") use the suggested entities (favorites, the watch history and the
//  first live channels of each playlist), with the names people say as synonyms (`ChannelSpokenNames`);
//  `ChannelSpotlightIndexer` refreshes them with `updateAppShortcutParameters()`. A phrase without the channel
//  ("Watch TV in Fluxo") makes Siri ask which one, and the answer is searched in every playlist.
//
//  An app has at most ten App Shortcuts: Show Channel Schedule, Find Channels, Get Favorites, Remove from
//  Favorites, Toggle Favorite, Pause / Resume / Stop Playback and Play by Name are actions of the Shortcuts app
//  (and of Siri AI) without phrases of their own.
//

import AppIntents

struct FluxoShortcuts: AppShortcutsProvider {
    // Only Play Channel has phrases with a channel ("Play Rai 1 in Fluxo"). The system makes a tile of every App
    // Shortcut phrase parameter, titled with the channel's name alone, in Spotlight and the Shortcuts app: with a
    // channel in What's On, Add to Favorites or Recording phrases too, Spotlight listed "Rai 1 HD" several times and
    // its top hit for a channel ran What's On or Add to Favorites instead of playing it (seen in the iOS 27.2
    // Simulator, `Tools/Simulator/siri-tests.sh`). Those intents act on the channel that plays ("Record this in
    // Fluxo") or ask, and Siri AI and the Shortcuts app still fill in their channel.

    static var shortcutTileColor: ShortcutTileColor {
        .purple
    }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayChannelIntent(),
            phrases: [
                "Play \(\.$target) in \(.applicationName)",
                "Watch \(\.$target) in \(.applicationName)",
                "Play \(\.$target) on \(.applicationName)",
                "Watch \(\.$target) on \(.applicationName)",
                "Put on \(\.$target) in \(.applicationName)",
                "Switch to \(\.$target) in \(.applicationName)",
                "Turn on \(\.$target) in \(.applicationName)",
                // Without a channel, Siri asks "Which channel?" and searches every playlist for the answer, so any
                // channel works, not only the ones it knows by name.
                "Play a channel in \(.applicationName)",
                "Watch TV in \(.applicationName)",
                "Watch something in \(.applicationName)",
            ],
            shortTitle: "Play Channel",
            systemImageName: "play.tv"
        )
        AppShortcut(
            intent: ContinueWatchingIntent(),
            phrases: [
                "Continue watching in \(.applicationName)",
                "Continue watching on \(.applicationName)",
                "Resume watching in \(.applicationName)",
                "Keep watching in \(.applicationName)",
                "Resume my show in \(.applicationName)",
            ],
            shortTitle: "Continue Watching",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: WhatsOnIntent(),
            phrases: [
                "What's on in \(.applicationName)",
                "What's on TV in \(.applicationName)",
            ],
            shortTitle: "What's On",
            systemImageName: "tv.badge.wifi"
        )
        AppShortcut(
            intent: GetRecommendationsIntent(),
            phrases: [
                "What should I watch on \(.applicationName)",
                "What should I watch in \(.applicationName)",
                "Recommend something on \(.applicationName)",
                "Suggest something to watch in \(.applicationName)",
            ],
            shortTitle: "Suggestions",
            systemImageName: "sparkles.tv"
        )
        AppShortcut(
            intent: SearchProgrammesIntent(),
            phrases: [
                "Search the \(.applicationName) guide",
                "Find a show in \(.applicationName)",
                "Search the TV guide in \(.applicationName)",
            ],
            shortTitle: "Search TV Guide",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: SearchInFluxoIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search in \(.applicationName)",
                "Find channels in \(.applicationName)",
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenFluxoIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Show \(\.$target) in \(.applicationName)",
                "Open the \(\.$target) in \(.applicationName)",
                "Show my \(.applicationName) \(\.$target)",
            ],
            shortTitle: "Open Screen",
            systemImageName: "calendar.day.timeline.left"
        )
        // Adding, not toggling: a phrase said twice must not remove the channel. Toggle Favorite stays an action
        // of the Shortcuts app.
        AppShortcut(
            intent: AddFavoriteIntent(),
            phrases: [
                "Favorite this channel in \(.applicationName)",
                "Add this channel to my \(.applicationName) favorites",
            ],
            shortTitle: "Add to Favorites",
            systemImageName: "star"
        )
        AppShortcut(
            intent: RecordingIntent(),
            phrases: [
                "\(\.$action) in \(.applicationName)",
                "\(\.$action) on \(.applicationName)",
                "Record this in \(.applicationName)",
            ],
            shortTitle: "Record",
            systemImageName: "record.circle"
        )
        // Without a programme, Siri asks "Which programme?" and searches the guide for the answer, so any title works;
        // with one, the programme must be among the next ones of the favorite channels.
        AppShortcut(
            intent: SetReminderIntent(),
            phrases: [
                "Remind me about \(\.$program) in \(.applicationName)",
                "Set a reminder in \(.applicationName)",
                "Set a \(.applicationName) reminder",
                "Remind me about a show in \(.applicationName)",
            ],
            shortTitle: "Set Reminder",
            systemImageName: "bell.badge"
        )
    }
}

