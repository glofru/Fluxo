//
//  CloudSync.swift
//  Fluxo
//
//  iCloud sync of the library across the user's iPhone, iPad, Mac and Apple TV: playlists (name and address), the TV
//  guides the user added, favorites, watch history and resume positions, and the player's main settings. The screens
//  read this object (Settings › iCloud, the "Your Playlists from iCloud" sheet); the work is done by the
//  `CloudSyncReconciler` over a `LibrarySyncStore` and a transport (CloudKit). See "iCloud sync" in the README.
//

import Foundation
import Observation
import os
import SwiftData

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
    private let transport: CloudSyncTransport?
    @ObservationIgnored
    private let reconciler: CloudSyncReconciler
    @ObservationIgnored
    private let store: LibrarySyncStore
    @ObservationIgnored
    private var observers: [NSObjectProtocol] = []
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
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true

        let store = LibrarySyncStore(container: container, importCenter: importCenter, library: library, epg: epg)
        context = container.mainContext
        self.library = library
        let directory = Self.directory
        let transport = Self.makeTransport(directory: directory)
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
        guard enabled != isEnabled else {
            return
        }
        isEnabled = enabled
        UserDefaults.fluxo.set(enabled, forKey: Self.enabledKey)
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
            await reconciler.localStateMayHaveChanged()
            // Changes the cloud has not confirmed: refused for good (iCloud storage full), cancelled, or queued
            // just before the app was quit.
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
            isSyncing = false
            await refreshAvailability()
            refreshCloudPlaylists()
        }
    }

    func sceneDidBecomeActive() {
        syncNow()
    }

    /// Sends what changed before the app is suspended.
    func sceneDidEnterBackground() {
        guard isEnabled, let transport else {
            return
        }
        cancelPendingPass()
        Task {
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
            await reconciler.localStateMayHaveChanged()
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
        transport.start()
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
        ledgerRevision += 1
        offerImportIfAppropriate()
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

    private func track(name: String, playlistID: UUID, task: Task<PlaylistImportSummary, Error>) {
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

    private static func makeTransport(directory: URL) -> CloudSyncTransport? {
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
    var debugTransport: CloudSyncTransport? {
        transport
    }

    /// The records (addresses reduced to their host), links and imports, for `cloud-log`.
    var debugDescription: String {
        var lines = [
            "enabled: \(isEnabled) availability: \(availability) accepts: \(acceptsCloudPlaylists) fetched: \(hasFetched) sheet: \(isImportSheetPresented) offerDismissed: \(UserDefaults.fluxo.bool(forKey: Self.offerDismissedKey))",
            "local passes: \(debugCounters.localPasses) coalesced progress saves: \(debugCounters.coalescedProgressSaves) unsent: \(reconciler.unsentRecordIDs.count)",
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

    func transportDidSend(_ sent: [SyncRecordID: Date]) {
        reconciler.recordsSent(sent)
        lastSyncedOn = .now
        if !sent.isEmpty {
            lastError = nil
        }
    }

    func transportDidFail(_ error: Error) {
        report(error)
    }

    /// Shows `error` in the status row, in the user's language (CloudKit's own descriptions are often English
    /// developer text), and logs what CloudKit said.
    private func report(_ error: Error) {
        // The domain, code and description only: the full error can carry the records (playlist addresses).
        let nsError = error as NSError
        Self.logger.error("Sync failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public): \(error.localizedDescription, privacy: .public)")
        lastError = CloudSyncErrorText.message(for: error)
    }
}
