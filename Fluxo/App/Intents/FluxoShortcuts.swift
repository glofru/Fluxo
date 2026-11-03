//
//  FluxoShortcuts.swift
//  Fluxo
//
//  The App Shortcuts: Siri phrases that work as soon as the app is installed, and the tiles of Fluxo in the
//  Shortcuts app and Spotlight. Every intent is also available as an action in the Shortcuts app; Pause and
//  Resume need no phrase, since Siri's own "Pause" / "Resume" reach Fluxo's Now Playing session.
//
//  Channel and programme phrases ("Play Sky Sport F1 in Fluxo") use the suggested entities (favorites and the
//  watch history); `ChannelSpotlightIndexer` refreshes them with `updateAppShortcutParameters()`.
//

import AppIntents

struct FluxoShortcuts: AppShortcutsProvider {

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
            ],
            shortTitle: "Play Channel",
            systemImageName: "play.tv"
        )
        AppShortcut(
            intent: WhatsOnIntent(),
            phrases: [
                "What's on in \(.applicationName)",
                "What's on TV in \(.applicationName)",
                "What's on \(\.$channel) in \(.applicationName)",
                "What's on \(\.$channel) on \(.applicationName)",
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
            systemImageName: "calendar.badge.magnifyingglass"
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
            ],
            shortTitle: "Open Screen",
            systemImageName: "calendar.day.timeline.left"
        )
        AppShortcut(
            intent: SetReminderIntent(),
            phrases: [
                "Remind me about \(\.$program) in \(.applicationName)",
                "Set a reminder in \(.applicationName)",
                "Set a \(.applicationName) reminder",
            ],
            shortTitle: "Set Reminder",
            systemImageName: "bell.badge"
        )
        // Adding, not toggling: a phrase said twice must not remove the channel. Toggle Favorite stays an action
        // of the Shortcuts app.
        AppShortcut(
            intent: AddFavoriteIntent(),
            phrases: [
                "Favorite this channel in \(.applicationName)",
                "Add \(\.$channel) to my \(.applicationName) favorites",
                "Add this channel to my \(.applicationName) favorites",
            ],
            shortTitle: "Add to Favorites",
            systemImageName: "star"
        )
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record this in \(.applicationName)",
                "Record \(\.$channel) in \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording in \(.applicationName)",
                "Stop the \(.applicationName) recording",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
    }
}
