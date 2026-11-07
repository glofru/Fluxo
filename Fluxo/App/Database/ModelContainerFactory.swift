//
//  ModelContainerFactory.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import os
import SwiftData

enum ModelContainerFactory {

    /// The library of this launch: the user's (`LibraryStore`), or an isolated debug library. A library that cannot be
    /// opened is reported, never replaced: the app then shows `LibraryRecoveryView`.
    @MainActor
    static func open() -> Result<ModelContainer, LibraryOpenFailure> {
        #if DEBUG
        if let demo = DebugGuideDemo.makeContainerIfRequested() {
            return .success(demo)
        }
        if let failure = DebugLaunchOptions.current.takeSimulatedLibraryFailure() {
            return .failure(failure)
        }
        // -FluxoDebugStore: an isolated library that never touches the real store.
        if let environment = DebugEnvironment.shared {
            return environment.openLibrary()
        }
        #endif
        return LibraryStore.open(.standard)
    }

    /// The library, when opening it starts with the one-time split of a store of the first builds: opened off the
    /// main thread (`LibraryStore.open` touches no actor state), behind "Updating Your Library…".
    @MainActor
    static var locationNeedingUpgrade: LibraryStoreLocation? {
        #if DEBUG
        if DebugLaunchOptions.current.libraryFailure != nil {
            return nil
        }
        #endif
        guard let location, LibraryStore.needsUpgrade(location) else {
            return nil
        }
        return location
    }

    /// Where the library of this launch is on disk (nil for an in-memory debug library).
    static var location: LibraryStoreLocation? {
        #if DEBUG
        if DebugGuideDemo.isEnabled {
            return nil
        }
        if let environment = DebugEnvironment.shared {
            return environment.libraryLocation
        }
        #endif
        return .standard
    }
}

extension ModelContainerFactory {
    /// In-memory container for SwiftUI previews.
    @MainActor
    static func preview() -> ModelContainer {
        do {
            return try LibraryStore.makeInMemoryContainer()
        } catch {
            preconditionFailure("Could not create the preview container: \(error)")
        }
    }
}
