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

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Database")

    /// Opens the app store. If an existing store cannot be opened with the current schema (e.g. a pre-release
    /// layout that lightweight migration cannot map), it is moved aside and a fresh store is created instead of
    /// crashing at launch. Playlist content can always be downloaded again.
    static func make() -> ModelContainer {
        let schema = Schema(ModelRegistry.all)
        let configuration = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            logger.error("Could not open the store, recreating it: \(error.localizedDescription, privacy: .public)")
            moveStoreAside(at: configuration.url)
        }

        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Could not create the model container: \(error)")
        }
    }

    private static func moveStoreAside(at storeURL: URL) {
        let fileManager = FileManager.default
        let suffix = ".incompatible-\(Int(Date().timeIntervalSince1970))"
        for fileSuffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: storeURL.path + fileSuffix)
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            let backup = URL(fileURLWithPath: storeURL.path + suffix + fileSuffix)
            try? fileManager.removeItem(at: backup)
            do {
                try fileManager.moveItem(at: url, to: backup)
            } catch {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

extension ModelContainerFactory {
    /// In-memory container for SwiftUI previews.
    static func preview() -> ModelContainer {
        do {
            return try ModelContainer(for: Schema(ModelRegistry.all), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("Could not create the preview container: \(error)")
        }
    }
}
