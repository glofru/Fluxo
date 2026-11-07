//
//  LibrarySession.swift
//  Fluxo
//
//  Opens the library at launch and builds the app's objects on it (`AppGraph`). When the library cannot be opened
//  the app shows `LibraryRecoveryView` instead, and nothing else runs (no sync, imports, downloads or guide refresh
//  that could act on an empty library): Try Again, Export a Copy, Start with an Empty Library.
//

import Foundation
import Observation
import os
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class LibrarySession {

    enum State {
        /// The one-time split of a store of the first builds runs (`LibraryStore.needsUpgrade`).
        case upgrading
        case ready(AppGraph)
        case unavailable(LibraryOpenFailure)
    }

    private(set) var state: State
    /// A Try Again or Start Over is running.
    private(set) var isWorking = false

    @ObservationIgnored
    private var protectedDataObserver: (any NSObjectProtocol)?

    init() {
        state = .unavailable(.cannotOpen)
        if let location = ModelContainerFactory.locationNeedingUpgrade {
            // Once, after the update that split the store (and at the next launch, which compacts the library file):
            // seconds for a large library, so not on the main thread (the launch would be stopped by the system).
            // A reminder notification that launched the app meanwhile waits in `ReminderNotificationDelegate`,
            // installed before this (`FluxoApp.init`).
            openInBackground(location)
            return
        }
        finishOpening(ModelContainerFactory.open())
    }

    /// Opens the library off the main thread, behind "Updating Your Library…".
    private func openInBackground(_ location: LibraryStoreLocation) {
        state = .upgrading
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                LibraryStore.open(location)
            }.value
            self?.finishOpening(result)
        }
    }

    private func finishOpening(_ result: Result<ModelContainer, LibraryOpenFailure>) {
        switch result {
        case .success(let container):
            // Before anything of the app saves: only the history of earlier launches goes.
            StoreHistory.pruneEarlierLaunches(in: container, openedAt: .now)
            state = .ready(AppGraph(container: container))
            stopWatchingProtectedData()
        case .failure(let failure):
            state = .unavailable(failure)
            watchProtectedData()
        }
    }

    var graph: AppGraph? {
        if case .ready(let graph) = state {
            return graph
        }
        return nil
    }

    var failure: LibraryOpenFailure? {
        if case .unavailable(let failure) = state {
            return failure
        }
        return nil
    }

    /// Where the library is on disk (nil for an in-memory debug library).
    var location: LibraryStoreLocation? {
        ModelContainerFactory.location
    }

    /// Opens the library again (the device was unlocked, space was freed, the app was updated).
    func retry() {
        guard failure != nil, !isWorking else {
            return
        }
        // The attempt that runs the one-time split (after it lacked space, say) takes seconds: off the main thread.
        if let location = ModelContainerFactory.locationNeedingUpgrade {
            LibraryStore.logger.notice("Trying again to open the library: its one-time update runs first")
            openInBackground(location)
            return
        }
        isWorking = true
        defer {
            isWorking = false
        }
        let result = ModelContainerFactory.open()
        if case .success = result {
            LibraryStore.logger.notice("The library opened on a new attempt")
        }
        finishOpening(result)
    }

    /// Start with an Empty Library: the library goes to a backup (never deleted), and an empty one opens.
    func startOver() throws {
        guard failure != nil, let location else {
            return
        }
        try LibraryStore.startOver(location)
        retry()
    }

    /// The app's services for App Intents: at once when the library is open; an error the intent shows when it
    /// cannot be opened (the app shows why).
    func services() async throws -> AppServices {
        // An intent that launched the app during the one-time upgrade waits for it (a few seconds).
        while case .upgrading = state {
            try await Task.sleep(for: .milliseconds(200))
        }
        if let graph {
            return graph.services
        }
        throw LibraryUnavailableError()
    }

    /// A launch before the first unlock cannot read the files (data protection): try again once they can be.
    private func watchProtectedData() {
        #if canImport(UIKit)
        guard failure == .temporarilyUnavailable, protectedDataObserver == nil else {
            return
        }
        protectedDataObserver = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retry()
            }
        }
        #endif
    }

    private func stopWatchingProtectedData() {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
        protectedDataObserver = nil
    }
}

/// An App Intent ran while the library could not be opened.
struct LibraryUnavailableError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Fluxo can't open your library right now. Open Fluxo to see why.", comment: "Error of a Siri or Shortcuts action run while the app's library cannot be opened.")
    }
}
