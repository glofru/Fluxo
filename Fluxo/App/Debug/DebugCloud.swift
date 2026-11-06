//
//  DebugCloud.swift
//  Fluxo
//
//  Debug harness for iCloud sync, compiled out of release builds. See Tools/Simulator/README.md ("iCloud sync").
//
//  -FluxoDebugCloud memory|<folder>               A simulated cloud instead of CloudKit (`SimulatedCloud`): in memory,
//                                                  or a folder of JSON records that simulator clones share, so one
//                                                  clone's playlists reach another without an iCloud account.
//  -FluxoDebugCloudSeed "<name>=<url>[;…]"         Playlists that "another device" put in the simulated cloud (for the
//                                                  first-run import on a new device).
//
//  Routes: `cloud-sync` (sync now), `cloud-offer` (the import sheet), `cloud-add:<all|name,…>` (Add in the sheet),
//  `cloud-menu` (closes the sheet as Menu does), `cloud-expect-closed` (fails if the sheet comes back),
//  `cloud-reject-saves:<on|off>` (iCloud storage full), `cloud-focus:` (Apple TV focus), `cloud-privacy`,
//  `cloud-wait-imports`, `cloud-log` (records and links to Status/cloud.log); data safety: `cloud-ask` (the
//  turn-on question), `cloud-favorite:`, `cloud-lose-library`, `cloud-lose-favorites` (an emptied store, mass removals), `cloud-answer:`,
//  `cloud-restore` (Restore from iCloud), `cloud-expect-no-deletions`, `cloud-deleted-elsewhere:` and `cloud-sync-kept`
//  (a playlist kept despite its deletion elsewhere, synced again), `cloud-expect-live:`.
//

#if DEBUG
import Foundation

enum DebugCloud {

    /// The simulated transport of `-FluxoDebugCloud`, nil without it.
    @MainActor
    static func makeTransport() -> CloudSyncTransport? {
        guard let value = DebugLaunchOptions.current.cloud else {
            return nil
        }
        let backend: SimulatedCloudBackend
        if value.lowercased() == "memory" {
            backend = MemoryCloudBackend()
        } else {
            backend = DirectoryCloudBackend(directory: URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true))
        }
        seed(backend)
        DebugLaunchOptions.logger.notice("Simulated iCloud: \(value, privacy: .public)")
        return SimulatedCloudTransport(backend: backend, automaticallySyncs: true)
    }

    /// `-FluxoDebugCloudSeed`: playlist records of another device (a record the cloud already has is kept).
    @MainActor
    private static func seed(_ backend: SimulatedCloudBackend) {
        guard let value = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["FluxoDebugCloudSeed"] as? String else {
            return
        }
        var createdOn = Date.now.addingTimeInterval(-86_400 * 30).syncRounded
        for entry in value.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let url = URL(string: parts[1]) else {
                DebugLaunchOptions.logger.error("Invalid -FluxoDebugCloudSeed entry \(String(entry), privacy: .public)")
                continue
            }
            let id = SyncRecordID(.playlist, SyncIdentity.playlistName(for: url))
            let record = SyncRecord(
                id: id,
                payload: .playlist(PlaylistPayload(name: parts[0], url: url, createdOn: createdOn)),
                modifiedAt: createdOn,
                deviceID: "debug-other-device"
            )
            _ = backend.save(record)
            createdOn = createdOn.addingTimeInterval(3_600)
        }
    }

    static let routes: [DebugRoute] = [
        DebugRoute("cloud-sync", "iCloud sync: compares the library and syncs with the (simulated) cloud now.") { _, _ in
            let sync = try current()
            sync.syncNow()
            try await Task.sleep(for: .seconds(1))
        },
        DebugRoute("cloud-offer", "Shows the Your Playlists from iCloud sheet.") { context, _ in
            let sync = try current()
            await context.wait(timeout: 15) { sync.hasFetched }
            sync.presentImportSheet()
        },
        DebugRoute("cloud-add:<all|name,…>", "Adds playlists from iCloud, like Add in the sheet.") { context, argument in
            let sync = try current()
            await context.wait(timeout: 15) { !sync.cloudPlaylists.isEmpty }
            let wanted = argument.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let names = sync.cloudPlaylists.filter { wanted.isEmpty || wanted == ["all"] || wanted.contains($0.name.lowercased()) }.map(\.id)
            guard !names.isEmpty else {
                throw DebugRouteError.notFound("iCloud playlist", argument)
            }
            sync.addPlaylists(Set(names))
            await context.wait(timeout: 10) { !sync.imports.isEmpty }
        },
        DebugRoute("cloud-focus:<name|add|not-now|done|sync-toggle|restore|kept|kept-ask|privacy>", "Apple TV: focuses a row or button of the iCloud playlists sheet or of Settings › iCloud, for screenshots (kept-ask: asks the Deleted on Other Devices question).") { _, argument in
            NotificationCenter.default.post(name: .fluxoDebugCloudFocus, object: argument)
            try await Task.sleep(for: .milliseconds(700))
        },
        DebugRoute("cloud-done", "Closes the iCloud playlists sheet (Done).") { _, _ in
            try current().isImportSheetPresented = false
            try await Task.sleep(for: .milliseconds(700))
        },
        DebugRoute("cloud-not-now", "Not Now in the iCloud playlists sheet.") { _, _ in
            try current().dismissImportOffer()
            try await Task.sleep(for: .milliseconds(700))
        },
        DebugRoute("cloud-menu", "Closes the iCloud playlists sheet as Menu on the Siri Remote or a swipe down does (not Not Now).") { _, _ in
            // The presentation's own dismissal: SwiftUI calls its onDismiss (`importSheetDidClose`), as for Menu.
            try current().isImportSheetPresented = false
            try await Task.sleep(for: .milliseconds(900))
        },
        DebugRoute("cloud-expect-closed[:<seconds>]", "Fails if the iCloud playlists sheet shows within that many seconds (6 by default), e.g. after cloud-menu and cloud-sync.") { _, argument in
            let sync = try current()
            let seconds = Double(argument) ?? 6
            let deadline = Date.now.addingTimeInterval(seconds)
            while Date.now < deadline {
                if sync.isImportSheetPresented {
                    throw DebugRouteError.check("the iCloud playlists sheet came back after it was closed")
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            DebugLaunchOptions.logger.notice("cloud-expect-closed: the iCloud playlists sheet stayed closed for \(seconds, privacy: .public) s")
        },
        DebugRoute("cloud-reject-saves:<on|off>", "The simulated cloud refuses every save as CloudKit does when iCloud storage is full (not retried); off: it accepts them again.") { _, argument in
            let sync = try current()
            guard let transport = sync.debugTransport as? SimulatedCloudTransport else {
                throw DebugRouteError.unsupported("cloud-reject-saves needs -FluxoDebugCloud")
            }
            transport.rejectsSaves = argument.lowercased() == "on"
            try await Task.sleep(for: .milliseconds(300))
        },
        DebugRoute("cloud-privacy", "Shows What's Synced and Privacy: pushed in Settings on Apple TV, as the row does; a sheet elsewhere.") { context, _ in
            #if os(tvOS)
            context.navigation.tab = .settings
            try await Task.sleep(for: .milliseconds(600))
            NotificationCenter.default.post(name: .fluxoDebugCloudPrivacy, object: nil)
            #else
            try current().isPrivacyPagePresented = true
            #endif
            try await Task.sleep(for: .milliseconds(900))
        },
        DebugRoute("cloud-wait-imports", "Waits until the playlists added from iCloud are imported (60 s at most).") { context, _ in
            let sync = try current()
            await context.wait(timeout: 60) { !sync.imports.isEmpty && sync.imports.values.allSatisfy { $0.phase != .importing } }
        },
        DebugRoute("cloud-favorite:<channel,…>", "Adds channels to the favorites (by name), for the mass-removal checks.") { context, argument in
            for name in argument.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
                context.library.setFavorite(true, for: try context.channel(named: name))
            }
            try await Task.sleep(for: .milliseconds(300))
        },
        DebugRoute("cloud-ask", "Asks the turn-on-sync question, as a device updated with a library does once.") { _, _ in
            try current().debugAskSyncChoice()
            try await Task.sleep(for: .milliseconds(900))
        },
        DebugRoute("cloud-lose-library", "Empties the library as a store recreated after it could not be opened does (no deletion is journaled), then syncs: the restore question must show, and nothing may be deleted in the cloud.") { context, _ in
            let sync = try current()
            try await sync.debugLoseLibrary()
            await context.wait(timeout: 10) { sync.prompt != nil }
            try await Task.sleep(for: .milliseconds(600))
        },
        DebugRoute("cloud-deleted-elsewhere:<playlist>", "Another device deletes the playlist while this one is away and loses its ledger: this device keeps it, on this device only, and Settings › iCloud offers to sync it again.") { context, argument in
            let sync = try current()
            try await sync.debugDeleteElsewhereWhileAway(argument)
            await context.wait(timeout: 10) { sync.keptOnDeviceCount > 0 }
            try await Task.sleep(for: .milliseconds(600))
        },
        DebugRoute("cloud-sync-kept", "Settings › iCloud › Deleted on Other Devices › Sync Again: the kept playlists and guides come back on the other devices.") { context, _ in
            let sync = try current()
            sync.syncKeptAgain()
            await context.wait(timeout: 10) { sync.keptOnDeviceCount == 0 }
            try await Task.sleep(for: .milliseconds(600))
        },
        DebugRoute("cloud-expect-live:<playlist>", "Fails unless the simulated cloud has the playlist as a live record (not a deletion), e.g. after cloud-sync-kept.") { _, argument in
            let sync = try current()
            guard let transport = sync.debugTransport as? SimulatedCloudTransport else {
                throw DebugRouteError.unsupported("cloud-expect-live needs -FluxoDebugCloud")
            }
            let live = transport.backend.records(after: Int.min).records.contains { record in
                if case .playlist(let playlist) = record.payload {
                    return playlist.name.localizedCaseInsensitiveCompare(argument) == .orderedSame
                }
                return false
            }
            guard live else {
                throw DebugRouteError.check("the cloud has no live record of the playlist \(argument)")
            }
            DebugLaunchOptions.logger.notice("cloud-expect-live: \(argument, privacy: .public) is live in the cloud")
        },
        DebugRoute("cloud-lose-favorites", "Every favorite vanishes at once (playlists stay), without the user removing them: the removals are held and the question shows.") { context, _ in
            let sync = try current()
            try await sync.debugLoseFavorites()
            await context.wait(timeout: 10) { sync.prompt != nil }
            try await Task.sleep(for: .milliseconds(600))
        },
        DebugRoute("cloud-answer:<primary|remove|cancel>", "Answers the sync question on screen: its first button (Turn On, Restore, Restore Them), Remove Everywhere, or Not Now.") { _, argument in
            let sync = try current()
            switch (sync.prompt, argument.lowercased()) {
            case (.turnOn, "primary"): sync.answerSyncChoice(turnOn: true)
            case (.turnOn, _): sync.answerSyncChoice(turnOn: false)
            case (.restoreLibrary, "primary"): sync.restoreLostLibrary()
            case (.restoreLibrary, _): sync.postponeRestore()
            case (.confirmRemovals, "primary"): sync.resolveHeldRemovals(remove: false)
            case (.confirmRemovals, "remove"): sync.resolveHeldRemovals(remove: true)
            case (.confirmRemovals, _): sync.postponeHeldRemovals()
            case (nil, _): throw DebugRouteError.check("no sync question is on screen")
            }
            try await Task.sleep(for: .seconds(1))
        },
        DebugRoute("cloud-restore", "Settings › iCloud › Restore from iCloud.") { context, _ in
            let sync = try current()
            sync.restoreFromICloud()
            await context.wait(timeout: 15) { !sync.isRestoring }
            try await Task.sleep(for: .milliseconds(600))
        },
        DebugRoute("cloud-expect-no-deletions", "Fails if the simulated cloud holds any deletion record (needs -FluxoDebugCloud).") { _, _ in
            guard let transport = try current().debugTransport as? SimulatedCloudTransport else {
                throw DebugRouteError.unsupported("cloud-expect-no-deletions needs -FluxoDebugCloud")
            }
            let records = transport.backend.records(after: Int.min).records
            let deletions = records.filter(\.isDeletion)
            guard deletions.isEmpty else {
                throw DebugRouteError.check("the cloud has \(deletions.count) deletion records: \(deletions.map(\.id.kind.rawValue))")
            }
            DebugLaunchOptions.logger.notice("cloud-expect-no-deletions: \(records.count, privacy: .public) records, no deletion")
        },
        DebugRoute("cloud-log", "Writes the sync state (records, links, imports) to Status/cloud.log.") { _, _ in
            let sync = try current()
            let text = sync.debugDescription
            try? FileManager.default.createDirectory(at: DebugEnvironment.statusDirectory, withIntermediateDirectories: true)
            try? text.write(to: DebugEnvironment.statusDirectory.appendingPathComponent("cloud.log"), atomically: true, encoding: .utf8)
            DebugLaunchOptions.logger.notice("\(text, privacy: .public)")
        },
    ]

    @MainActor
    private static func current() throws -> CloudSync {
        guard let sync = CloudSync.debugCurrent else {
            throw DebugRouteError.notFound("iCloud sync", "CloudSync")
        }
        return sync
    }
}
#endif
