//
//  DebugModalRoutes.swift
//  Fluxo
//
//  Debug harness: the app-wide sheets and alerts (a due reminder, the playlist and guide sheets and alerts), for
//  checking where they show. On Apple TV they show over the player while it is up, and playback goes on under them
//  (`AppModalsGate`):
//
//      -FluxoDebugRoute "seed-guide;player:Test Pattern (HLS);wait:6;reminder-due:Rai 1 HD;wait:2;expect-player;
//                        probe-playback;reminder-not-now;delete-playlist:Mega IPTV;wait:2;expect-player"
//
//  Every check appends a line to Status/modals.log.
//

#if DEBUG
import AVFoundation
import CoreMedia
import Foundation
import os
import SwiftData

@MainActor
enum DebugModalRoutes {

    static let all: [DebugRoute] = [
        DebugRoute("reminder-due:<channel>[,<channel>…]", "Apple TV: sets a reminder for the next programme of each channel (needs a guide, e.g. seed-guide) and delivers it now, as its timer would; several show one after the other.") { context, argument in
            let names = argument.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !names.isEmpty else {
                throw DebugRouteError.invalidArgument("reminder-due", argument)
            }
            let reminders = context.epg.reminders
            var scheduled: [GuideProgramme] = []
            for name in names {
                let item = try context.channel(named: name)
                guard let ref = await context.epg.guideRef(for: item),
                      let programme = await context.epg.upcoming(for: ref, from: .now, limit: 4).first(where: { ReminderCenter.canRemind($0) }) else {
                    throw DebugRouteError.notFound("upcoming programme on", name)
                }
                guard await reminders.schedule(programme, on: item) else {
                    throw DebugRouteError.check("could not set a reminder for \(programme.title) on \(name)")
                }
                scheduled.append(programme)
                report("reminder-due \(name): \(programme.title) at \(programme.start.formatted(date: .omitted, time: .shortened))")
            }
            // Delivered together, the earliest programme first, as `InAppReminderAlerts` delivers those due at once.
            for programme in scheduled.sorted(by: { $0.start < $1.start }) {
                guard reminders.debugDeliverNow(key: programme.reminderKey) else {
                    throw DebugRouteError.unsupported("reminder-due")
                }
            }
            // The alert presents with the next update.
            await context.wait(timeout: 2) { reminders.dueReminder != nil }
            report("reminder-due: showing \(reminders.dueReminder?.title ?? "-"), \(reminders.debugQueuedDueReminderCount) queued; \(playerState(context))")
        },
        DebugRoute("reminder-watch", "Apple TV: Watch in the reminder alert shown (plays its channel).") { context, _ in
            let reminders = context.epg.reminders
            guard let alert = reminders.dueReminder else {
                throw DebugRouteError.check("no reminder alert is shown")
            }
            reminders.openDueReminder()
            report("reminder-watch: \(alert.title) on \(alert.channelName)")
        },
        DebugRoute("reminder-not-now", "Apple TV: Not Now in the reminder alert shown.") { context, _ in
            let reminders = context.epg.reminders
            guard let alert = reminders.dueReminder else {
                throw DebugRouteError.check("no reminder alert is shown")
            }
            reminders.dismissDueReminder()
            report("reminder-not-now: \(alert.title)")
        },
        DebugRoute("guide-match:<channel>", "The TV guide picker of a channel (Choose TV Guide Channel).") { context, argument in
            context.epg.matchingTarget = try context.channel(named: argument)
        },
        DebugRoute("guide-error[:<message>]", "The alert of a TV guide that could not be loaded.") { context, argument in
            context.epg.failure = EPGStore.Failure(sourceName: "Debug Guide", message: argument.isEmpty ? "The server returned 404." : argument)
        },
        DebugRoute("playlist-error[:<message>]", "The Playlist Error alert, as after a refresh that failed.") { context, argument in
            let name = ((try? context.modelContext.fetch(FetchDescriptor<Playlist>())) ?? []).first?.name ?? "Playlist"
            context.importCenter.failure = PlaylistImportCenter.Failure(playlistName: name, message: argument.isEmpty ? "The server returned 404." : argument)
        },
        DebugRoute("dismiss-modals", "Closes the app-wide sheets and alerts as Cancel or OK would (the reminder as Not Now; on Apple TV, a link's alert too).") { context, _ in
            context.epg.reminders.dismissDueReminder()
            context.playlistActions.sheet = nil
            context.playlistActions.playlistToDelete = nil
            context.importCenter.failure = nil
            context.epg.matchingTarget = nil
            context.epg.failure = nil
            #if os(tvOS)
            context.navigation.linkFailure = nil
            #endif
        },
        DebugRoute("expect-player", "Fails unless the player is on screen and playing (or buffering); logs the app-wide sheets and alerts requested.") { context, _ in
            let state = playerState(context)
            report("expect-player: \(state); \(modalState(context))")
            let player = context.player
            guard player.isPresented, player.playbackState == .playing || player.playbackState == .buffering else {
                throw DebugRouteError.check("the player is not up and playing: \(state)")
            }
        },
        DebugRoute("modals-log", "Logs the player and the app-wide sheets and alerts requested (Status/modals.log).") { context, _ in
            report("modals-log: \(playerState(context)); \(modalState(context))")
        },
    ]

    private static func playerState(_ context: DebugRouteContext) -> String {
        let player = context.player
        let position = player.player.currentTime().seconds
        return "player presented \(player.isPresented), state \(player.playbackState), channel \(player.currentChannel?.name ?? "-"), at \(position.isFinite ? String(format: "%.1f", position) : "-") s"
    }

    private static func modalState(_ context: DebugRouteContext) -> String {
        var parts: [String] = []
        if let reminder = context.epg.reminders.dueReminder {
            parts.append("reminder \(reminder.title)")
        }
        if let sheet = context.playlistActions.sheet {
            parts.append("playlist sheet \(sheet)")
        }
        if let playlist = context.playlistActions.playlistToDelete {
            parts.append("delete \(playlist.name)")
        }
        if context.importCenter.failure != nil {
            parts.append("playlist error")
        }
        if let item = context.epg.matchingTarget {
            parts.append("guide picker \(item.displayName)")
        }
        if context.epg.failure != nil {
            parts.append("guide error")
        }
        #if os(tvOS)
        if context.navigation.linkFailure != nil {
            parts.append("link alert")
        }
        #endif
        return "modals [\(parts.joined(separator: ", "))]"
    }

    private static func report(_ line: String) {
        DebugLaunchOptions.logger.notice("\(line, privacy: .public)")
        let url = DebugEnvironment.statusDirectory.appendingPathComponent("modals.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
