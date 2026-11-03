//
//  CategoryChannelsModel.swift
//  Fluxo
//
//  The channels of one category for `CategoryDetailView`: fetched as values on a background context, a page
//  at a time, in the chosen order, optionally filtered by a search term. Also the letter index of the A–Z
//  order and the "Most Watched" channels of the category.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class CategoryChannelsModel {

    /// What is listed. A new request starts again from the first page.
    struct Request: Hashable, Sendable {
        let importID: UUID
        let playlistID: UUID
        let groupName: String
        let order: ChannelSortOrder
        let term: String
    }

    /// The first entry of a letter in the A–Z order.
    struct LetterOffset: Hashable, Sendable {
        let letter: String
        let offset: Int
    }

    nonisolated static let pageSize = 120
    /// Search results within a category are capped: typing more narrows them.
    nonisolated static let searchLimit = 500
    nonisolated static let mostWatchedLimit = 8

    private(set) var request: Request?
    private(set) var items: [ChannelItem] = []
    /// False until the first page of `request` is loaded (the list then shows a spinner, not "no channels").
    private(set) var isLoaded = false
    private(set) var reachedEnd = false
    /// A–Z order only: the letters of the index scroller.
    private(set) var letters: [LetterOffset] = []
    /// "Most Watched" order: the channels of the category watched most often (from the watch history).
    private(set) var mostWatched: [ChannelItem] = []

    @ObservationIgnored
    private var isLoadingPage = false

    /// Loads the first page of `request` (and the letters or the most watched channels it needs).
    func load(_ request: Request, container: ModelContainer) async {
        self.request = request
        isLoaded = false
        reachedEnd = false
        isLoadingPage = false
        let first = await Self.fetchPage(request, offset: 0, container: container)
        guard !Task.isCancelled, self.request == request else {
            return
        }
        items = first
        reachedEnd = !request.term.isEmpty || first.count < Self.pageSize
        isLoaded = true

        letters = request.order == .name && request.term.isEmpty ? await Self.fetchLetters(request, container: container) : []
        mostWatched = request.order == .mostWatched && request.term.isEmpty ? await Self.fetchMostWatched(request, container: container) : []
    }

    /// Loads the next page (when the last rows scroll in).
    func loadMore(container: ModelContainer) async {
        guard let request, isLoaded, !reachedEnd, !isLoadingPage else {
            return
        }
        isLoadingPage = true
        defer {
            isLoadingPage = false
        }
        let page = await Self.fetchPage(request, offset: items.count, container: container)
        guard self.request == request else {
            return
        }
        items.append(contentsOf: page)
        reachedEnd = page.count < Self.pageSize
    }

    /// Loads pages until the entry at `offset` is loaded (to jump to a letter or restore a position).
    func ensureLoaded(offset: Int, container: ModelContainer) async {
        while items.count <= offset, !reachedEnd, !Task.isCancelled {
            let before = items.count
            await loadMore(container: container)
            if items.count == before {
                return
            }
        }
    }

    // MARK: - Background fetches

    private nonisolated static func fetchPage(_ request: Request, offset: Int, container: ModelContainer) async -> [ChannelItem] {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let descriptor: FetchDescriptor<PlaylistChannel>
            if request.term.isEmpty {
                descriptor = HomeQueries.channels(importID: request.importID, groupName: request.groupName, order: request.order, offset: offset, limit: pageSize)
            } else {
                descriptor = HomeQueries.channels(importID: request.importID, groupName: request.groupName, matching: request.term, order: request.order, limit: searchLimit)
            }
            return ((try? context.fetch(descriptor)) ?? []).map(ChannelItem.init)
        }.value
    }

    /// Reads only the names of the whole category in A–Z order and notes where each letter starts.
    private nonisolated static func fetchLetters(_ request: Request, container: ModelContainer) async -> [LetterOffset] {
        await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            var descriptor = HomeQueries.channels(importID: request.importID, groupName: request.groupName, order: .name, limit: 0)
            descriptor.fetchLimit = nil
            descriptor.propertiesToFetch = [\.name]
            guard let names = try? context.fetch(descriptor).map(\.name) else {
                return []
            }
            return letterOffsets(of: names)
        }.value
    }

    private nonisolated static func fetchMostWatched(_ request: Request, container: ModelContainer) async -> [ChannelItem] {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let descriptor = HomeQueries.mostWatched(playlistID: request.playlistID, groupName: request.groupName, limit: mostWatchedLimit)
            return ((try? context.fetch(descriptor)) ?? []).map(ChannelItem.init)
        }.value
    }

    /// The first offset of each index letter, in list order. Letters are folded (É is E); names that start with
    /// a digit or a symbol are listed under "#".
    nonisolated static func letterOffsets(of names: [String?]) -> [LetterOffset] {
        var result: [LetterOffset] = []
        var seen: Set<String> = []
        for (offset, name) in names.enumerated() {
            let letter = indexLetter(for: name)
            if seen.insert(letter).inserted {
                result.append(LetterOffset(letter: letter, offset: offset))
            }
        }
        return result
    }

    nonisolated static func indexLetter(for name: String?) -> String {
        guard let first = name?.first(where: { !$0.isWhitespace }) else {
            return "#"
        }
        let folded = String(first).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).uppercased()
        guard let character = folded.first, character.isLetter else {
            return "#"
        }
        return String(character)
    }
}

/// Remembers, per category and order, the first row the user saw, so coming back to a category scrolls to
/// where they left it. Kept in the app's defaults (row offsets and group names only, at most `capacity`).
@MainActor
enum CategoryPositionMemory {

    private static let storageKey = "browse.categoryPositions"
    private static let capacity = 60

    static func key(for request: CategoryChannelsModel.Request) -> String {
        "\(request.importID.uuidString)|\(request.groupName)|\(request.order.rawValue)"
    }

    static func offset(for request: CategoryChannelsModel.Request) -> Int? {
        let stored = UserDefaults.fluxo.dictionary(forKey: storageKey) as? [String: Int]
        return stored?[key(for: request)]
    }

    static func save(_ offset: Int, for request: CategoryChannelsModel.Request) {
        let defaults = UserDefaults.fluxo
        var stored = (defaults.dictionary(forKey: storageKey) as? [String: Int]) ?? [:]
        let key = key(for: request)
        guard stored[key] != offset else {
            return
        }
        if offset <= 0 {
            stored[key] = nil
        } else {
            if stored.count >= capacity, stored[key] == nil, let evicted = stored.keys.sorted().first {
                stored[evicted] = nil
            }
            stored[key] = offset
        }
        defaults.set(stored, forKey: storageKey)
    }
}
