//
//  CloudSync.swift
//  Fluxo
//
//  iCloud sync of the library across the user's iPhone, iPad, Mac and Apple TV: playlists (name and address), the TV
//  guides the user added, favorites, watch history and resume positions, and the player's main settings. The screens
//  read this object (Settings › iCloud, the "Your Playlists from iCloud" sheet); the work is done by the
//  `CloudSyncReconciler` over a `LibrarySyncStore` and a transport (CloudKit). See docs/icloud-sync.md.
//

import CloudKit
import Foundation
import Observation
import os
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
final class CloudSync {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "CloudSync")

    // Device settings (`UserDefaults.fluxo`; never synced).
    static let enabledKey = "sync.enabled"
    static let acceptsCloudPlaylistsKey = "sync.acceptsCloudPlaylists"
    static let declinedPlaylistsKey = "sync.declinedPlaylists"
    static let offerDismissedKey = "sync.importOfferDismissed"
    static let deviceIDKey = "sync.deviceID"
    /// Record names of lost playlists and guides whose restore the user put off (the prompt does not come back for
    /// them; Settings › iCloud still offers them).
    static let restoreDeclinedKey = "sync.restoreDeclined"
    /// Not Now in the held-removals question: when, and how many removals were held then
    /// (`SyncHeldRemovalsReminder`; asked again a day later, not at every launch).
    static let heldRemovalsPostponedOnKey = "sync.heldRemovalsPostponedOn"
    static let heldRemovalsPostponedCountKey = "sync.heldRemovalsPostponedCount"

    /// The Info.plist key that names the CloudKit container; empty in builds that are not signed with the iCloud
    /// entitlement (unsigned command-line builds, the ad hoc signed Mac build), which then cannot sync.
    static let containerInfoKey = "FluxoCloudKitContainer"

    enum Availability: Equatable {
        case checking
        case available
        /// This build has no iCloud entitlement.
        case notConfigured
        case noAccount
        case restricted
        case temporarilyUnavailable
    }

    /// A playlist in iCloud that this device does not have.
    struct CloudPlaylist: Identifiable, Hashable {
        /// The record name.
        let id: String
        let name: String
        /// The server, for the list (never the path or the query, which may carry the account).
        let host: String?
        let createdOn: Date
    }

    /// A playlist this device is adding from iCloud.
    struct PlaylistImport: Equatable {
        enum Phase: Equatable {
            case importing
            case finished(channelCount: Int)
            case failed(String)
        }

        let playlistID: UUID
        var phase: Phase
    }

    private(set) var isEnabled: Bool
    private(set) var availability: Availability = .checking
    private(set) var isSyncing = false
    private(set) var lastSyncedOn: Date?
    /// The last error the cloud reported (cleared by the next successful sync).
    private(set) var lastError: String?
    /// Whether the cloud was read once since launch (the import sheet waits for it).
    private(set) var hasFetched = false
    /// Turning sync on: the transport forgets its fetch position (when the ledger needs a baseline), then starts.
    @ObservationIgnored
    private var transportStartup: Task<Void, Never>?
    /// Playlists in iCloud this device does not have, oldest first.
    private(set) var cloudPlaylists: [CloudPlaylist] = []
    /// Playlists this device added from iCloud during this launch, by record name.
    private(set) var imports: [String: PlaylistImport] = [:]
    /// What the user chose in the iCloud playlists sheet: the sheet then shows the progress of the chosen ones.
    struct ImportSession: Equatable {
        /// Every playlist the sheet listed, in its order.
        let playlists: [CloudPlaylist]
        /// Record names of the ones to add.
        let chosen: Set<String>
    }

    private(set) var importSession: ImportSession?

    /// A question sync asks once, as an alert over the window (`cloudPlaylistImport()` presents it).
    enum Prompt: Equatable, Identifiable {
        /// A device that had a library before this version: turn sync on? (New installs sync by default.)
        case turnOn
        /// Playlists or guides this device had are gone without being deleted (an emptied store); iCloud has them.
        /// `playlists` is how many playlists (0: only TV guides).
        case restoreLibrary(playlists: Int)
        /// Favorites or history vanished in large numbers at once: remove them everywhere, or restore them? (How
        /// many favorites, and how many watched items.)
        case confirmRemovals(favorites: Int, history: Int)

        var id: String {
            switch self {
            case .turnOn: "turn-on"
            case .restoreLibrary: "restore"
            case .confirmRemovals: "removals"
            }
        }
    }

    /// The question on screen, if any.
    private(set) var prompt: Prompt?
    /// The user has not said yet whether this device syncs: it had a library before sync existed, and sync stays off
    /// until the user answers (`Prompt.turnOn`).
    private(set) var needsSyncChoice = false
    /// Lost playlists and guides that iCloud still has, and held removals: what Restore from iCloud brings back.
    private(set) var restorableCount = 0
    /// Playlists and guides deleted on another device that this device kept: on this device only until the user
    /// syncs them again (Settings › iCloud, `syncKeptAgain()`).
    private(set) var keptOnDeviceCount = 0
    /// Restore from iCloud is running.
    private(set) var isRestoring = false
    /// The outcome of the last Restore from iCloud, for Settings.
    private(set) var restoreMessage: String?
    /// The "Your Playlists from iCloud" sheet.
    var isImportSheetPresented = false
    /// What's Synced and Privacy as a sheet over the window (the debug harness, `cloud-privacy`).
    var isPrivacyPagePresented = false
    /// Changes after every pass: what the screens read from the ledger (`syncsPlaylist(_:)`) is read again.
    private(set) var ledgerRevision = 0

    /// Whether the "Your Playlists from iCloud" offer may cover the window now: not over the player, or over a sheet
    /// the user is busy with (Add Playlist). Set by the app.
    @ObservationIgnored
    var mayPresentImportOffer: () -> Bool = { true }

    /// How long a resume position saved during playback (every few seconds) may wait before it is published: a
    /// pause, a stop, another item or the app going to the background publishes it at once.
    static let progressPublishDelay: Duration = .seconds(300)

    @ObservationIgnored
    private let transport: (any CloudSyncTransport)?
    @ObservationIgnored
    private let reconciler: CloudSyncReconciler
    @ObservationIgnored
    private let store: LibrarySyncStore
    @ObservationIgnored
    private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored
    private let context: ModelContext
    @ObservationIgnored
    private let library: ChannelLibrary
    @ObservationIgnored
    private var pendingPass: Task<Void, Never>?
    /// Tells the scheduled pass from a newer one (which replaced it).
    @ObservationIgnored
    private var passGeneration = 0
    @ObservationIgnored
    private var isStarted = false
    /// A question waits for the window to be uncovered (`windowIsCovered`): asked again shortly.
    @ObservationIgnored
    private var promptRetry: Task<Void, Never>?
    /// The synced settings at the last check, to tell their changes from other writes to the defaults.
    @ObservationIgnored
    private var preferenceValues: [String] = []
    #if DEBUG
    /// Passes started by library saves, and progress saves that waited (the debug harness, `cloud-log`).
    @ObservationIgnored
    private(set) var debugCounters = (localPasses: 0, coalescedProgressSaves: 0)
    #endif

    #if DEBUG
    /// The running instance, for the debug routes.
    static weak var debugCurrent: CloudSync?
    #endif

    init(container: ModelContainer, importCenter: PlaylistImportCenter, library: ChannelLibrary, epg: EPGStore) {
        let defaults = UserDefaults.fluxo
        let deviceID: String
        if let saved = defaults.string(forKey: Self.deviceIDKey) {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Self.deviceIDKey)
        }
        let store = LibrarySyncStore(container: container, importCenter: importCenter, library: library, epg: epg)
        context = container.mainContext
        self.library = library
        let directory = Self.directory
        let transport = Self.makeTransport(directory: directory)
        if let stored = defaults.object(forKey: Self.enabledKey) as? Bool {
            isEnabled = stored
        } else if Self.hasLibrary(container.mainContext) {
            // An update to the version with sync, on a device that has playlists: nothing is uploaded before the
            // user says so (asked once, `Prompt.turnOn`). A build that cannot sync asks nothing.
            isEnabled = false
            needsSyncChoice = transport != nil
        } else {
            // A new install: syncing is the point (a new Apple TV gets the playlists of the user's iPhone).
            isEnabled = true
            if transport != nil {
                defaults.set(true, forKey: Self.enabledKey)
            }
        }
        self.store = store
        self.transport = transport
        reconciler = CloudSyncReconciler(deviceID: deviceID, store: store, storage: FileSyncLedgerStorage(url: directory.appendingPathComponent("ledger.json")))
        lastSyncedOn = reconciler.ledger.lastSyncedOn

        if defaults.object(forKey: Self.acceptsCloudPlaylistsKey) == nil {
            // A device that already has playlists shares them and takes the others; a new one asks first.
            let count = (try? container.mainContext.fetchCount(FetchDescriptor<Playlist>())) ?? 0
            defaults.set(count > 0, forKey: Self.acceptsCloudPlaylistsKey)
        }

        store.mayAddPlaylist = { [weak self] name in
            self?.mayAddPlaylist(name) ?? false
        }
        store.playlistImportStarted = { [weak self] name, playlistID, task in
            self?.track(name: name, playlistID: playlistID, task: task)
        }
        reconciler.onRecordsChanged = { [weak self] ids in
            self?.transport?.recordsChanged(ids)
        }
        reconciler.onPassFinished = { [weak self] in
            self?.refreshCloudPlaylists()
        }
        transport?.events = self
        #if DEBUG
        Self.debugCurrent = self
        #endif
    }

    /// Starts syncing (at launch): observes the library and the settings, and reads the cloud.
    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        observeLocalChanges()
        guard isEnabled else {
            Task {
                await refreshAvailability()
            }
            return
        }
        startTransport()
    }

    // MARK: - State for the screens

    /// Whether this build can sync at all.
    var isConfigured: Bool {
        transport != nil
    }

    var acceptsCloudPlaylists: Bool {
        UserDefaults.fluxo.bool(forKey: Self.acceptsCloudPlaylistsKey)
    }

    /// Whether the playlist is synced: deleting it here deletes it on the user's other devices.
    func syncsPlaylist(_ playlistID: UUID) -> Bool {
        _ = ledgerRevision
        return isEnabled && isConfigured && reconciler.ledger.links.playlistName(forLocalID: playlistID) != nil
    }

    // MARK: - Actions

    func setEnabled(_ enabled: Bool) {
        // The switch answers the first-run question too.
        needsSyncChoice = false
        if prompt == .turnOn {
            prompt = nil
        }
        UserDefaults.fluxo.set(enabled, forKey: Self.enabledKey)
        guard enabled != isEnabled else {
            return
        }
        isEnabled = enabled
        if enabled {
            startTransport()
        } else {
            cancelPendingPass()
            transport?.stop()
            isSyncing = false
            isImportSheetPresented = false
        }
    }

    /// Sync Now (Settings), and when the app comes to the foreground.
    func syncNow() {
        guard isEnabled, let transport else {
            return
        }
        isSyncing = true
        Task {
            await sendAndFetch(transport)
            isSyncing = false
            await refreshAvailability()
            refreshCloudPlaylists()
        }
    }

    private func sendAndFetch(_ transport: any CloudSyncTransport) async {
        await transportStartup?.value
        await reconciler.localStateMayHaveChanged()
        // Changes the cloud has not confirmed: refused for good (iCloud storage full), cancelled, or queued just
        // before the app was quit.
        transport.recordsChanged(reconciler.unsentRecordIDs)
        // A refused save reports itself while it is sent (`transportDidFail`): cleared first, not after.
        lastError = nil
        do {
            try await transport.sendChanges()
            try await transport.fetchChanges()
        } catch {
            report(error)
        }
        hasFetched = true
    }

    func sceneDidBecomeActive() {
        guard isEnabled else {
            // The first-run question may have waited for the player to close, or for an iCloud account.
            if needsSyncChoice {
                Task {
                    await refreshAvailability()
                }
            }
            return
        }
        syncNow()
    }

    /// Sends what changed before the app is suspended.
    func sceneDidEnterBackground() {
        guard isEnabled, let transport else {
            return
        }
        cancelPendingPass()
        Task {
            await transportStartup?.value
            await reconciler.localStateMayHaveChanged()
            transport.recordsChanged(reconciler.unsentRecordIDs)
            try? await transport.sendChanges()
        }
    }

    /// Adds the chosen playlists of iCloud to this device (the others stay in iCloud, and can be added later from
    /// Settings). From now on, playlists added on the user's other devices are added here too.
    func addPlaylists(_ names: Set<String>) {
        importSession = ImportSession(playlists: cloudPlaylists, chosen: names)
        let declined = Set(cloudPlaylists.map(\.id)).subtracting(names).union(declinedPlaylists.subtracting(names))
        UserDefaults.fluxo.set(true, forKey: Self.acceptsCloudPlaylistsKey)
        UserDefaults.fluxo.set(Array(declined).sorted(), forKey: Self.declinedPlaylistsKey)
        Task {
            // Playlists this device lost are restored with their guides, favorites and history.
            await reconciler.restore(playlists: names)
        }
    }

    // MARK: - Questions and recovery

    /// The first-run question: sync this device's library with iCloud, or not (Settings › iCloud can change it).
    func answerSyncChoice(turnOn: Bool) {
        prompt = nil
        setEnabled(turnOn)
    }

    /// Restore in the lost-library question: the playlists and guides this device lost come back from iCloud, with
    /// their favorites and history; the sheet shows the progress of each playlist.
    func restoreLostLibrary() {
        prompt = nil
        let names = Set(reconciler.recordsAwaitingRestore.filter { $0.id.kind == .playlist }.map(\.id.name))
        let rows = cloudPlaylists.filter { names.contains($0.id) }
        let defaults = UserDefaults.fluxo
        defaults.set(true, forKey: Self.acceptsCloudPlaylistsKey)
        defaults.set(Array(declinedPlaylists.subtracting(names)).sorted(), forKey: Self.declinedPlaylistsKey)
        if !rows.isEmpty {
            importSession = ImportSession(playlists: rows, chosen: names)
        }
        Task {
            await reconciler.restore()
            if !rows.isEmpty, mayPresentImportOffer() {
                isImportSheetPresented = true
            }
        }
    }

    /// Not Now in the lost-library question: it does not come back for these playlists; Settings › iCloud (Playlists
    /// in iCloud, Restore from iCloud) and the empty Home still offer them.
    func postponeRestore() {
        prompt = nil
        let names = Set(reconciler.recordsAwaitingRestore.map(\.id.recordName))
        let declined = Set(UserDefaults.fluxo.stringArray(forKey: Self.restoreDeclinedKey) ?? []).union(names)
        UserDefaults.fluxo.set(Array(declined).sorted(), forKey: Self.restoreDeclinedKey)
    }

    /// The answer to the mass-removal question: restore the favorites and history here (`remove` false), or remove
    /// them from every device.
    func resolveHeldRemovals(remove: Bool) {
        prompt = nil
        Task {
            if remove {
                await reconciler.confirmHeldDeletions()
            } else {
                await reconciler.restoreHeldDeletions()
            }
        }
    }

    /// Not Now in the mass-removal question: nothing is removed elsewhere, nothing comes back here; asked again a
    /// day later (or sooner if more removals are held), not at every launch (`SyncHeldRemovalsReminder`).
    func postponeHeldRemovals() {
        prompt = nil
        let defaults = UserDefaults.fluxo
        defaults.set(Date.now, forKey: Self.heldRemovalsPostponedOnKey)
        defaults.set(reconciler.heldDeletionIDs.count, forKey: Self.heldRemovalsPostponedCountKey)
    }

    /// Since the last Not Now, if the question about held removals was put off.
    private var heldRemovalsReminder: SyncHeldRemovalsReminder {
        let defaults = UserDefaults.fluxo
        return SyncHeldRemovalsReminder(
            postponedOn: defaults.object(forKey: Self.heldRemovalsPostponedOnKey) as? Date,
            postponedCount: defaults.integer(forKey: Self.heldRemovalsPostponedCountKey)
        )
    }

    /// Settings › iCloud › Restore from iCloud: reads the whole cloud again, brings back the favorites, history and
    /// settings this device lost, and lists the playlists of iCloud it does not have (all checked) to add them.
    /// Nothing of the cloud is deleted, and nothing of this device is overwritten but what is missing.
    func restoreFromICloud() {
        guard isEnabled, let transport, !isRestoring else {
            return
        }
        isRestoring = true
        restoreMessage = nil
        Task {
            await reconciler.prepareFullRestore()
            // Returns once the running engine is cancelled and a new one reads from the start (never two at once).
            await transport.forgetFetchPosition()
            await sendAndFetch(transport)
            refreshCloudPlaylists()
            if !cloudPlaylists.isEmpty {
                importSession = nil
                isImportSheetPresented = true
            } else if lastError == nil {
                restoreMessage = String(localized: "Everything in iCloud is on this device", comment: "Settings › iCloud: Restore from iCloud finished and found nothing missing on this device.")
            }
            isRestoring = false
        }
    }

    /// Settings › iCloud › Kept on This Device › Sync Again: the playlists and guides deleted on another device that
    /// this device kept are synced again, so they come back on the user's other devices (with their favorites and
    /// history).
    func syncKeptAgain() {
        guard isEnabled, transport != nil else {
            return
        }
        Task {
            await reconciler.syncKeptAgain()
            refreshCloudPlaylists()
        }
    }

    /// "Not Now": the sheet does not come back on its own; Settings › iCloud lists the playlists.
    func dismissImportOffer() {
        UserDefaults.fluxo.set(true, forKey: Self.offerDismissedKey)
        isImportSheetPresented = false
    }

    /// Settings › iCloud › Playlists in iCloud.
    func presentImportSheet() {
        isImportSheetPresented = true
    }

    /// Clears the finished imports once the sheet is closed (the sheet shows the running ones when it opens again).
    /// Closed without Add (Menu on the Siri Remote, a swipe down, Escape): the same as Not Now, so the offer does not
    /// come back on its own.
    func importSheetDidClose() {
        if importSession == nil {
            UserDefaults.fluxo.set(true, forKey: Self.offerDismissedKey)
        }
        imports = imports.filter { $0.value.phase == .importing }
        if let session = importSession, !session.chosen.contains(where: { imports[$0] != nil }) {
            importSession = nil
        }
    }

    /// Delete iCloud Data: removes everything Fluxo stored in iCloud and turns sync off on this device. The library
    /// of every device stays as it is.
    func deleteCloudData() async throws {
        guard let transport else {
            return
        }
        try await transport.deleteAllRemoteData()
        reconciler.resetSyncState()
        setEnabled(false)
        transport.stop()
        cloudPlaylists = []
    }

    // MARK: - Private

    private var declinedPlaylists: Set<String> {
        Set(UserDefaults.fluxo.stringArray(forKey: Self.declinedPlaylistsKey) ?? [])
    }

    private func mayAddPlaylist(_ name: String) -> Bool {
        isEnabled && acceptsCloudPlaylists && !declinedPlaylists.contains(name)
    }

    private func startTransport() {
        guard let transport else {
            availability = .notConfigured
            return
        }
        // A new, lost or reset ledger: the first fetch reads everything, not only what changed since the engine last
        // fetched (its state may have outlived the ledger). Sends and fetches wait for this (`sendAndFetch`).
        let readsFromStart = reconciler.needsBaseline
        let previous = transportStartup
        transportStartup = Task {
            await previous?.value
            if readsFromStart {
                await transport.forgetFetchPosition()
            }
            // Turned off again meanwhile: its `stop()` already ran.
            if isEnabled {
                transport.start()
            }
        }
        Task {
            await refreshAvailability()
        }
        syncNow()
    }

    private func refreshAvailability() async {
        guard let transport else {
            availability = .notConfigured
            return
        }
        if let cloudKit = transport as? CloudKitSyncTransport {
            switch await cloudKit.accountStatus() {
            case .available:
                availability = .available
                updatePrompt()
            case .noAccount:
                availability = .noAccount
            case .restricted:
                availability = .restricted
            case .temporarilyUnavailable:
                availability = .temporarilyUnavailable
            case .couldNotDetermine:
                availability = .temporarilyUnavailable
            @unknown default:
                availability = .temporarilyUnavailable
            }
        } else {
            availability = .available
            updatePrompt()
        }
    }

    /// Library saves (playlists, guides, favorites, progress) and settings changes start a pass a moment later, so a
    /// burst of saves (an import, a few favorites in a row) is compared once. The resume positions playback saves
    /// every few seconds wait longer (`progressPublishDelay`): a pass reads the library and may upload a record, and
    /// doing that every 10 seconds of a movie would cost battery.
    private func observeLocalChanges() {
        let synced: Set<String> = ["Playlist", "EPGSource", "ChannelBookmark", "SeriesBookmark"]
        // No queue: the check runs on the thread that saved (imports save in the background, with long lists of
        // identifiers), and the main thread only hears of saves that matter.
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self, library] notification in
            let info = notification.userInfo ?? [:]
            let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
            var relevant = info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] != nil
            for key in keys where !relevant {
                if let identifiers = info[key.rawValue] as? [PersistentIdentifier] {
                    relevant = identifiers.contains { synced.contains($0.entityName) }
                }
            }
            guard relevant else {
                return
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    // Saved by `ChannelLibrary` during playback, synchronously: it says which save this is.
                    self?.libraryDidSave(periodicProgress: library.isSavingPeriodicProgress)
                }
            } else {
                Task { @MainActor in
                    self?.libraryDidSave(periodicProgress: false)
                }
            }
        })
        preferenceValues = Self.currentPreferenceValues()
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard notification.object as? UserDefaults === UserDefaults.fluxo else {
                return
            }
            MainActor.assumeIsolated {
                self?.defaultsDidChange()
            }
        })
    }

    /// The defaults change for many reasons (the player's state, the guide's refresh times): only a synced
    /// setting starts a pass.
    private func defaultsDidChange() {
        let values = Self.currentPreferenceValues()
        guard values != preferenceValues else {
            return
        }
        preferenceValues = values
        scheduleLocalPass(delay: .seconds(2))
    }

    private static func currentPreferenceValues() -> [String] {
        let defaults = UserDefaults.fluxo
        return LibrarySyncStore.syncedPreferences.map { preference in
            defaults.object(forKey: preference.key).map { String(describing: $0) } ?? ""
        }
    }

    private func libraryDidSave(periodicProgress: Bool) {
        guard periodicProgress else {
            scheduleLocalPass()
            return
        }
        #if DEBUG
        debugCounters.coalescedProgressSaves += 1
        #endif
        // A pass is coming anyway (it publishes the position too); else one in a few minutes, which later progress
        // saves do not postpone.
        if pendingPass == nil {
            schedulePass(after: Self.progressPublishDelay)
        }
    }

    private func scheduleLocalPass(delay: Duration = .seconds(3)) {
        schedulePass(after: delay)
    }

    private func schedulePass(after delay: Duration) {
        guard isEnabled, transport != nil else {
            return
        }
        pendingPass?.cancel()
        passGeneration += 1
        let generation = passGeneration
        pendingPass = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else {
                return
            }
            if self.passGeneration == generation {
                self.pendingPass = nil
            }
            #if DEBUG
            self.debugCounters.localPasses += 1
            #endif
            await self.reconciler.localStateMayHaveChanged()
        }
    }

    private func cancelPendingPass() {
        pendingPass?.cancel()
        pendingPass = nil
        passGeneration += 1
    }

    private func refreshCloudPlaylists() {
        let local = reconciler.ledger.links.playlists
        cloudPlaylists = reconciler.liveRecords(of: .playlist).compactMap { record -> CloudPlaylist? in
            guard local[record.id.name] == nil, case .playlist(let playlist) = record.payload else {
                return nil
            }
            return CloudPlaylist(id: record.id.name, name: playlist.name, host: playlist.url.host(), createdOn: playlist.createdOn)
        }
        .sorted { $0.createdOn < $1.createdOn }
        lastSyncedOn = reconciler.ledger.lastSyncedOn ?? lastSyncedOn
        let restorable = reconciler.recordsAwaitingRestore
        restorableCount = restorable.count + reconciler.heldDeletionIDs.count
        keptOnDeviceCount = reconciler.keptDespiteDeletionIDs.count
        _ = prunedRestoreDeclined(restorable)
        ledgerRevision += 1
        offerImportIfAppropriate()
        updatePrompt()
    }

    /// Asks the question that applies, one at a time, never over the player, the Add Playlist sheet or the iCloud
    /// playlists sheet: the first-run choice, then a lost library, then a mass removal.
    func updatePrompt() {
        guard prompt == nil, !isImportSheetPresented, mayPresentImportOffer(), let next = promptToAsk() else {
            return
        }
        guard !Self.windowIsCovered else {
            // The alert is presented at the root of the window, which cannot present it over a sheet or popover
            // (Settings on iPhone, a share sheet): asked once the window is uncovered.
            if promptRetry == nil {
                promptRetry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self else {
                        return
                    }
                    self.promptRetry = nil
                    self.updatePrompt()
                }
            }
            return
        }
        promptRetry?.cancel()
        promptRetry = nil
        prompt = next
    }

    /// The question that applies now, if any (`updatePrompt`).
    private func promptToAsk() -> Prompt? {
        if needsSyncChoice {
            return isConfigured && availability == .available ? .turnOn : nil
        }
        guard isEnabled, isConfigured else {
            return nil
        }
        let restorable = reconciler.recordsAwaitingRestore
        let declined = prunedRestoreDeclined(restorable)
        let awaiting = restorable.filter { !declined.contains($0.id.recordName) }
        if !awaiting.isEmpty {
            return .restoreLibrary(playlists: awaiting.filter { $0.id.kind == .playlist }.count)
        }
        let held = reconciler.heldDeletionIDs
        if held.isEmpty, UserDefaults.fluxo.object(forKey: Self.heldRemovalsPostponedOnKey) != nil {
            // Answered another way (Restore from iCloud, the items came back): a later loss is asked about at once.
            UserDefaults.fluxo.removeObject(forKey: Self.heldRemovalsPostponedOnKey)
            UserDefaults.fluxo.removeObject(forKey: Self.heldRemovalsPostponedCountKey)
        }
        if heldRemovalsReminder.shouldAsk(held: held.count, now: .now) {
            let favorites = held.filter { $0.kind == .channelFavorite || $0.kind == .seriesFavorite }.count
            return .confirmRemovals(favorites: favorites, history: held.count - favorites)
        }
        return nil
    }

    /// Whether the key window shows a sheet, popover or other modal presentation (not an alert, and not one being
    /// dismissed) that the root of the window cannot present a question over.
    private static var windowIsCovered: Bool {
        #if canImport(UIKit)
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene, scene.activationState == .foregroundActive else {
                continue
            }
            for window in scene.windows where window.isKeyWindow {
                if let presented = window.rootViewController?.presentedViewController,
                   !(presented is UIAlertController), !presented.isBeingDismissed {
                    return true
                }
            }
        }
        return false
        #elseif canImport(AppKit)
        return NSApp.keyWindow?.attachedSheet != nil || NSApp.modalWindow != nil
        #else
        return false
        #endif
    }

    /// The restores the user put off that still apply: one restored since (or gone from iCloud) is forgotten, so
    /// the question comes back if it is lost again.
    private func prunedRestoreDeclined(_ restorable: [SyncRecord]) -> Set<String> {
        let defaults = UserDefaults.fluxo
        let stored = Set(defaults.stringArray(forKey: Self.restoreDeclinedKey) ?? [])
        let pruned = stored.intersection(restorable.map(\.id.recordName))
        if pruned != stored {
            defaults.set(Array(pruned).sorted(), forKey: Self.restoreDeclinedKey)
        }
        return pruned
    }

    /// Whether the store has anything a user made (playlists, guides, favorites or history of channels or series).
    private static func hasLibrary(_ context: ModelContext) -> Bool {
        if ((try? context.fetchCount(FetchDescriptor<Playlist>())) ?? 0) > 0 {
            return true
        }
        if ((try? context.fetchCount(FetchDescriptor<EPGSource>(predicate: #Predicate { $0.playlistID == nil }))) ?? 0) > 0 {
            return true
        }
        if ((try? context.fetchCount(FetchDescriptor<ChannelBookmark>())) ?? 0) > 0 {
            return true
        }
        return ((try? context.fetchCount(FetchDescriptor<SeriesBookmark>())) ?? 0) > 0
    }

    /// The automatic "Your Playlists from iCloud" offer: on a device that has no playlist (a new Apple TV), once,
    /// and never over the player or a sheet in use. Closed without Add, it does not come back on its own (Settings
    /// › iCloud and the empty Home lead to it).
    private func offerImportIfAppropriate() {
        guard isEnabled, hasFetched, !acceptsCloudPlaylists, !cloudPlaylists.isEmpty, !isImportSheetPresented,
              !UserDefaults.fluxo.bool(forKey: Self.offerDismissedKey) else {
            return
        }
        let playlistCount = (try? context.fetchCount(FetchDescriptor<Playlist>())) ?? 0
        guard playlistCount == 0, mayPresentImportOffer() else {
            return
        }
        isImportSheetPresented = true
    }

    private func track(name: String, playlistID: UUID, task: Task<PlaylistImportSummary, any Error>) {
        imports[name] = PlaylistImport(playlistID: playlistID, phase: .importing)
        Task { [weak self] in
            let result = await task.result
            guard let self else {
                return
            }
            switch result {
            case .success(let summary):
                self.imports[name]?.phase = .finished(channelCount: summary.channelCount)
            case .failure(let error):
                self.imports[name]?.phase = .failed(error is CancellationError ? String(localized: "Cancelled", comment: "iCloud playlist import: the import was cancelled.") : error.localizedDescription)
            }
        }
    }

    /// Application Support/CloudSync (a debug run keeps its own, next to its isolated library).
    private static var directory: URL {
        #if DEBUG
        if let environment = DebugEnvironment.shared {
            return environment.rootDirectory.appendingPathComponent("CloudSync", isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("CloudSync", isDirectory: true)
    }

    private static func makeTransport(directory: URL) -> (any CloudSyncTransport)? {
        #if DEBUG
        if let simulated = DebugCloud.makeTransport() {
            return simulated
        }
        if DebugEnvironment.shared != nil {
            // An isolated debug library never syncs with the real iCloud.
            return nil
        }
        #endif
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: containerInfoKey) as? String,
              identifier.hasPrefix("iCloud.") else {
            return nil
        }
        return CloudKitSyncTransport(containerIdentifier: identifier, directory: directory)
    }
}

#if DEBUG
extension CloudSync {
    /// The transport, for the debug routes (`cloud-reject-saves`).
    var debugTransport: (any CloudSyncTransport)? {
        transport
    }

    /// `cloud-ask`: the first-run question, as a device updated with a library would ask it.
    func debugAskSyncChoice() {
        prompt = nil
        needsSyncChoice = true
        updatePrompt()
    }

    /// `cloud-lose-library`: empties the store the way a store recreated after it could not be opened does (no
    /// deletion goes through the app, so nothing is journaled), then compares it with the ledger.
    func debugLoseLibrary() async throws {
        try context.delete(model: ChannelBookmark.self)
        try context.delete(model: SeriesBookmark.self)
        for source in try context.fetch(FetchDescriptor<EPGSource>(predicate: #Predicate { $0.playlistID == nil })) {
            context.delete(source)
        }
        for playlist in try context.fetch(FetchDescriptor<Playlist>()) {
            context.delete(playlist)
        }
        try context.save()
        library.reloadFromStore()
        await reconciler.localStateMayHaveChanged()
    }

    /// `cloud-deleted-elsewhere:<playlist>`: another device deletes the playlist while this one is away and loses its
    /// ledger; at its next sync this device keeps the playlist (`keptDespiteDeletion`), and Settings › iCloud says so.
    func debugDeleteElsewhereWhileAway(_ playlistName: String) async throws {
        guard let simulated = transport as? SimulatedCloudTransport else {
            throw DebugRouteError.unsupported("cloud-deleted-elsewhere needs -FluxoDebugCloud")
        }
        guard let playlist = try context.fetch(FetchDescriptor<Playlist>()).first(where: { $0.name.localizedCaseInsensitiveCompare(playlistName) == .orderedSame }),
              let recordName = reconciler.ledger.links.playlistName(forLocalID: playlist.uuid) else {
            throw DebugRouteError.notFound("synced playlist", playlistName)
        }
        _ = simulated.backend.save(SyncRecord(id: SyncRecordID(.playlist, recordName), payload: nil, modifiedAt: Date.now.syncRounded, deviceID: "debug-other-device"))
        reconciler.resetSyncState()
        await transport?.forgetFetchPosition()
        syncNow()
    }

    /// `cloud-lose-favorites`: every favorite vanishes at once (the playlists stay), without the user removing them.
    func debugLoseFavorites() async throws {
        for bookmark in try context.fetch(FetchDescriptor<ChannelBookmark>(predicate: #Predicate { $0.isFavorite == true })) {
            bookmark.isFavorite = false
            bookmark.favoritedOn = nil
        }
        for bookmark in try context.fetch(FetchDescriptor<SeriesBookmark>(predicate: #Predicate { $0.isFavorite == true })) {
            bookmark.isFavorite = false
            bookmark.favoritedOn = nil
        }
        try context.save()
        library.reloadFromStore()
        await reconciler.localStateMayHaveChanged()
    }

    /// The records (addresses reduced to their host), links and imports, for `cloud-log`.
    var debugDescription: String {
        var lines = [
            "enabled: \(isEnabled) availability: \(availability) accepts: \(acceptsCloudPlaylists) fetched: \(hasFetched) sheet: \(isImportSheetPresented) offerDismissed: \(UserDefaults.fluxo.bool(forKey: Self.offerDismissedKey))",
            "local passes: \(debugCounters.localPasses) coalesced progress saves: \(debugCounters.coalescedProgressSaves) unsent: \(reconciler.unsentRecordIDs.count)",
            "baseline: \(!reconciler.needsBaseline) needs choice: \(needsSyncChoice) prompt: \(prompt?.id ?? "-") awaiting restore: \(reconciler.recordsAwaitingRestore.count) held removals: \(reconciler.heldDeletionIDs.count)",
        ]
        for record in reconciler.ledger.records.values.sorted(by: { $0.id < $1.id }) {
            let summary: String
            switch record.payload {
            case .playlist(let playlist): summary = "playlist \(playlist.name) @ \(playlist.url.host() ?? "-")"
            case .guideSource(let source): summary = "guide \(source.name) @ \(source.url.host() ?? "-") enabled: \(source.isEnabled)"
            case .channelFavorite(let favorite): summary = "favorite \(favorite.channel.name ?? "-") order: \(favorite.order)"
            case .channelProgress(let progress): summary = "progress \(progress.channel.name ?? "-") at \(Int(progress.resumePosition)) s of \(Int(progress.knownDuration)) s, watched \(progress.watchCount)x"
            case .seriesFavorite(let favorite): summary = "series favorite \(favorite.series.title)"
            case .seriesProgress(let progress): summary = "series progress \(progress.series.title) watched \(progress.watchedEpisodeCodes.count)"
            case .preference(let value): summary = "setting \(record.id.name) = \(value)"
            case nil: summary = "deleted"
            }
            let applied = reconciler.ledger.lastSeenLocal[record.id.recordName] == record.payload ? "applied" : "pending"
            lines.append("\(record.id.kind.recordType) \(record.id.name.prefix(12)) by \(record.deviceID.prefix(8)) [\(applied)]: \(summary)")
        }
        lines.append("linked playlists: \(reconciler.ledger.links.playlists.count), guides: \(reconciler.ledger.links.guideSources.count)")
        for (name, state) in imports.sorted(by: { $0.key < $1.key }) {
            lines.append("import \(name.prefix(12)): \(state.phase)")
        }
        return lines.joined(separator: "\n")
    }
}
#endif

// MARK: - Transport events

extension CloudSync: CloudSyncTransportEvents {
    func transportRecord(for id: SyncRecordID) -> SyncRecord? {
        reconciler.record(for: id)
    }

    func transportDidFetch(_ records: [SyncRecord]) async {
        // Sync is off (an engine still winding down): nothing of the cloud is applied.
        guard isEnabled else {
            return
        }
        hasFetched = true
        await reconciler.receive(records)
    }

    func transportAccountDidChange(_ change: CloudAccountChange) async {
        switch change {
        case .signedIn:
            await refreshAvailability()
            syncNow()
        case .signedOut:
            // What was synced is kept: signing in again to the same account goes on from there (another account
            // is told by the transport, `.switched`). Nothing is republished as new, which would override changes
            // the other devices made meanwhile.
            availability = .noAccount
            cloudPlaylists = []
        case .switched:
            // What was synced belongs to the other account: the library of this device is sent to the new one.
            reconciler.resetSyncState()
            await refreshAvailability()
            syncNow()
        case .remoteDataDeleted:
            reconciler.resetSyncState()
            setEnabled(false)
            cloudPlaylists = []
        }
    }

    func transportDidFinishFetching() async {
        guard isEnabled else {
            return
        }
        await reconciler.fetchDidFinish()
    }

    func transportDidSend(_ sent: [SyncRecordID: Date]) {
        reconciler.recordsSent(sent)
        lastSyncedOn = .now
        if !sent.isEmpty {
            lastError = nil
        }
    }

    func transportDidFail(_ error: any Error) {
        report(error)
    }

    /// Shows `error` in the status row, in the user's language (CloudKit's own descriptions are often English
    /// developer text), and logs what CloudKit said.
    private func report(_ error: any Error) {
        // The domain, code and description only: the full error can carry the records (playlist addresses).
        let nsError = error as NSError
        Self.logger.error("Sync failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public): \(error.localizedDescription, privacy: .public)")
        lastError = CloudSyncErrorText.message(for: error)
    }
}
