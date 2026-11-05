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

    nonisolated static let limit = 250

    nonisolated private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Spotlight")

    private let container: ModelContainer
    private var pending: Task<Void, Never>?
    private var lastIndexedKeys: [String]?
    private var lastParameterSignature: [String]?

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
        let (entities, playlists) = await Task.detached(priority: .utility) {
            let entities = (try? await ChannelEntityQuery.suggestions(container: container, limit: Self.limit)) ?? []
            return (entities, LibraryLookup.visiblePlaylists(in: container).map(\.importID.uuidString))
        }.value
        let keys = entities.map(\.id)

        // The phrases first: they do not depend on Spotlight, which may be unavailable (or fail) on its own. Only
        // when what Siri would learn changed (the first suggestions, or the playlists whose first channels follow
        // them): each call makes the system run the parameter suggestions again, which costs SwiftData fetches and
        // battery, and this runs after every channel change and every return to the app.
        let parameterSignature = Array(keys.prefix(ChannelEntityQuery.suggestionLimit)) + ["|"] + playlists.sorted()
        if parameterSignature != lastParameterSignature {
            FluxoShortcuts.updateAppShortcutParameters()
            lastParameterSignature = parameterSignature
        }

        guard PlatformFeatures.spotlightIndexing, keys != lastIndexedKeys else {
            return
        }
        do {
            try await Self.replaceIndex(with: entities)
            lastIndexedKeys = keys
            Self.logger.notice("Indexed \(entities.count) channels in Spotlight")
        } catch {
            Self.logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The identifiers of the channels in Spotlight, so the next update deletes only the ones that left.
    nonisolated private static let indexedIdentifiersKey = "spotlight.indexedChannelIdentifiers"

    /// Replaces the channels of the app in the default Spotlight index: indexes `entities` and deletes the channels
    /// indexed before that are no longer among them.
    ///
    /// It never calls `deleteAppEntities(ofType:)`: on iOS 27.2 that call does not return (checked in the Simulator
    /// with `spotlight-reindex` of the debug harness), so an update that started with it never indexed anything.
    /// `deleteAllSearchableItems()` did not return within 5 s either (four launches in the 27.2 Simulator), and a
    /// bulk delete that completes late could remove the entries indexed after it: so there is no bulk cleanup of
    /// what earlier builds indexed. Those builds started every update with the call that does not return, so on
    /// iOS 27 they indexed nothing; and iOS 27 asks the app for a full index when it needs one (`IndexedEntityQuery`).
    nonisolated static func replaceIndex(with entities: [ChannelEntity]) async throws {
        #if !os(tvOS)
        let index = CSSearchableIndex.default()
        let defaults = UserDefaults.fluxo
        let identifiers = entities.map(\.id)
        let removed = Set(defaults.stringArray(forKey: indexedIdentifiersKey) ?? []).subtracting(identifiers)
        if !removed.isEmpty {
            try await index.deleteAppEntities(identifiedBy: Array(removed), ofType: ChannelEntity.self)
        }
        if !entities.isEmpty {
            try await index.indexAppEntities(entities)
        }
        defaults.set(identifiers, forKey: indexedIdentifiersKey)
        #endif
    }
}

#if !os(tvOS)
/// iOS 27: Spotlight can ask the app to index its channels again (after a restore, or when the index was reset).
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension ChannelEntityQuery: IndexedEntityQuery {

    func reindexEntities(for identifiers: [ChannelEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        let entities = try await entities(for: identifiers)
        if !entities.isEmpty {
            try await CSSearchableIndex.default().indexAppEntities(entities)
        }
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let entities = try await Self.suggestions(container: services.container, limit: ChannelSpotlightIndexer.limit)
        try await ChannelSpotlightIndexer.replaceIndex(with: entities)
    }
}
#endif
