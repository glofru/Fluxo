//
//  ChannelSpotlightIndexer.swift
//  Fluxo
//
//  Puts the favorites and the recently watched channels in Spotlight (as `ChannelEntity`s, so opening one runs
//  `PlayChannelIntent`), and refreshes the parameters of the Siri phrases with them. Large playlists are not
//  indexed whole: hundreds of thousands of entries would bloat the index for little use.
//

import AppIntents
import CoreSpotlight
import Foundation
import os
import SwiftData

@MainActor
final class ChannelSpotlightIndexer {

    static let limit = 250

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Spotlight")

    private let container: ModelContainer
    private var pending: Task<Void, Never>?
    private var lastIndexedKeys: [String]?

    init(container: ModelContainer) {
        self.container = container
    }

    /// Re-indexes after `delay` (calls in the meantime are merged).
    func scheduleUpdate(after delay: Duration = .seconds(2)) {
        #if DEBUG && os(macOS)
        // A debug run on an isolated library shares the bundle identifier, and so the Spotlight index, with the
        // user's copy of the app: keep the real library's entries.
        if DebugEnvironment.shared != nil {
            return
        }
        #endif
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            await self?.update()
        }
    }

    private func update() async {
        let container = container
        let entities = await Task.detached(priority: .utility) {
            (try? await ChannelEntityQuery.suggestions(container: container, limit: Self.limit)) ?? []
        }.value
        let keys = entities.map(\.id)
        guard keys != lastIndexedKeys else {
            return
        }
        do {
            let index = CSSearchableIndex.default()
            try await index.deleteAppEntities(ofType: ChannelEntity.self)
            if !entities.isEmpty {
                try await index.indexAppEntities(entities)
            }
            lastIndexedKeys = keys
            FluxoShortcuts.updateAppShortcutParameters()
            Self.logger.notice("Indexed \(entities.count) channels in Spotlight")
        } catch {
            Self.logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
