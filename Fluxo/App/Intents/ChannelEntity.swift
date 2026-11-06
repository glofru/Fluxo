//
//  ChannelEntity.swift
//  Fluxo
//
//  A playlist channel (live channel, movie or episode) for Siri, Shortcuts and Spotlight.
//
//  It stands for a bookmark key (playlist + stream URL), not the channel row's UUID: a playlist refresh rewrites
//  every row with new UUIDs, while a channel keeps its URL, so shortcuts and Spotlight results made with an older
//  copy of the playlist still find it. The identifier the system sees is opaque (`ChannelEntityID`): stream URLs
//  can carry account credentials.
//

import AppIntents
import CoreSpotlight
import Foundation
import SwiftData

struct ChannelEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Channel", numericFormat: "\(placeholder: .int) channels")
    }

    static let defaultQuery = ChannelEntityQuery()

    /// Opaque (`ChannelEntityID`); `item.bookmarkKey` is the key it stands for.
    let id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Group")
    var group: String

    @Property(title: "Type")
    var kind: ChannelKindAppEnum

    @Property(title: "Playlist")
    var playlistName: String?

    /// The position in the playlist, from 1 (nil for a channel known only from the favorites or the history).
    @Property(title: "Channel Number")
    var number: Int?

    /// The channel itself, for playing it.
    let item: ChannelItem

    init?(_ item: ChannelItem, playlistName: String? = nil) {
        guard let key = item.bookmarkKey, let identifier = ChannelEntityID.make(forKey: key) else {
            return nil
        }
        id = identifier
        self.item = item
        self.name = item.displayName
        self.group = ChannelCandidate.displayGroup(item.groupName)
        self.kind = ChannelKindAppEnum(item.kind)
        self.playlistName = playlistName
        self.number = item.number
    }

    /// The system's reference to a channel, for on-screen awareness (`View.appEntityIdentifier(_:)`).
    static func entityIdentifier(for item: ChannelItem) -> EntityIdentifier? {
        ChannelEntity(item).map { EntityIdentifier(for: $0) }
    }

    /// The synonyms are the names people say for the playlist's name ("Sky Sport F1" for "IT: Sky Sport F1 FHD",
    /// `ChannelSpokenNames`): Siri matches the words of "Play … in Fluxo" against the title and the synonyms.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(TextParts.line([group, playlistName]))",
            image: DisplayRepresentation.Image(systemName: item.kind.systemImage),
            synonyms: ChannelSpokenNames.variants(of: name).map { "\($0)" }
        )
    }

}

#if !os(tvOS)
/// Spotlight (not on tvOS, `PlatformFeatures.spotlightIndexing`).
extension ChannelEntity: IndexedEntity {

    /// Spotlight: the name, the kind, the group and the playlist, so "Sky Sport F1", "F1" or "Sport" find it.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.displayName = name
        attributes.contentDescription = TextParts.line([item.kind.title, group, playlistName])
        attributes.keywords = [group, item.kind.title, playlistName].compactMap { $0 } + ChannelNameNormalizer.tokens(name) + ChannelSpokenNames.variants(of: name)
        attributes.alternateNames = ChannelSpokenNames.variants(of: name)
        return attributes
    }
}
#endif

/// The content kinds, for Shortcuts filters and parameters.
enum ChannelKindAppEnum: String, AppEnum {
    case live
    case movie
    case series

    init(_ kind: ChannelContentKind) {
        switch kind {
        case .live:
            self = .live
        case .movie:
            self = .movie
        case .series:
            self = .series
        }
    }

    var contentKind: ChannelContentKind {
        switch self {
        case .live:
            return .live
        case .movie:
            return .movie
        case .series:
            return .series
        }
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Content Type"
    }

    static var caseDisplayRepresentations: [ChannelKindAppEnum: DisplayRepresentation] {
        [
            .live: DisplayRepresentation(title: "Live TV", image: .init(systemName: ChannelContentKind.live.systemImage)),
            .movie: DisplayRepresentation(title: "Movie", image: .init(systemName: ChannelContentKind.movie.systemImage)),
            .series: DisplayRepresentation(title: "Series", image: .init(systemName: ChannelContentKind.series.systemImage)),
        ]
    }
}

/// Finds channels for Siri and Shortcuts: by identifier, by name (the typo-tolerant token search of the Search
/// screen, across every playlist), and suggestions (favorites, then recently watched).
struct ChannelEntityQuery: EntityStringQuery {

    @Dependency
    var services: AppServices

    static let suggestionLimit = 40

    @concurrent func entities(for identifiers: [ChannelEntity.ID]) async throws -> [ChannelEntity] {
        let container = services.container
        let names = Self.playlistNames(container)
        return identifiers.compactMap { identifier in
            ChannelEntityID.key(for: identifier, in: container)
                .flatMap { LibraryLookup.channel(forKey: $0, in: container) }
                .flatMap { ChannelEntity($0, playlistName: names[$0.playlistID]) }
        }
    }

    /// What Siri runs with the words it heard for a channel ("Which channel?" answered, or Siri AI filling in a
    /// parameter): the channel `AppServices.resolveChannel` picks first ("Rai Uno" → "Rai 1", "channel 5", the
    /// favorite among same-named channels), then the other search results that have the numbers said.
    @concurrent func entities(matching string: String) async throws -> [ChannelEntity] {
        let container = services.container
        let playlists = LibraryLookup.visiblePlaylists(in: container)
        let names = Dictionary(playlists.map { ($0.playlistID, $0.name) }, uniquingKeysWith: { first, _ in first })
        // Never a channel with other numbers: "Eurosport 7" offers no "Eurosport 1" that Siri could pick alone.
        let digitTerm = ChannelResolver.digitsForNumberWords(string)
        var items = await LibraryLookup.searchChannels(string, importIDs: playlists.map(\.importID), limit: 30, in: container)
            .filter { ChannelResolver.hasNumbers(of: digitTerm, inName: $0.displayName) }
        if let best = await services.resolveChannel(string)?.item {
            items.removeAll { $0.bookmarkKey == best.bookmarkKey }
            items.insert(best, at: 0)
        }
        return items.compactMap { ChannelEntity($0, playlistName: names[$0.playlistID]) }
    }

    /// What Siri knows by name for the phrases "Play … in Fluxo" (`updateAppShortcutParameters()`), and what the
    /// Shortcuts app lists first: the favorites, the watch history, then the first live channels of each playlist.
    @concurrent func suggestedEntities() async throws -> [ChannelEntity] {
        try await Self.parameterSuggestions(container: services.container)
    }

    /// The suggestions plus the first live channels of each playlist (the main channels of a provider's list come
    /// first), up to `parameterLimit`.
    @concurrent static func parameterSuggestions(container: ModelContainer, limit: Int = parameterLimit) async throws -> [ChannelEntity] {
        var entities = try await suggestions(container: container, limit: suggestionLimit)
        guard entities.count < limit else {
            return entities
        }
        var seen = Set(entities.map(\.id))
        let playlists = LibraryLookup.visiblePlaylists(in: container)
        let names = Dictionary(playlists.map { ($0.playlistID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let perPlaylist = max(8, (limit - entities.count) / max(1, playlists.count))
        for playlist in playlists {
            var added = 0
            for group in LibraryLookup.firstGroups(importIDs: [playlist.importID], kind: .live, limit: 4, in: container) {
                for item in LibraryLookup.channels(importID: playlist.importID, groupName: group.name, limit: perPlaylist, in: container) {
                    guard added < perPlaylist, entities.count < limit, let entity = ChannelEntity(item, playlistName: names[item.playlistID]),
                          seen.insert(entity.id).inserted else {
                        continue
                    }
                    entities.append(entity)
                    added += 1
                }
            }
        }
        return entities
    }

    /// How many channels Siri knows by name.
    static let parameterLimit = 80

    /// Favorites first, then the watch history, without repeats.
    @concurrent static func suggestions(container: ModelContainer, limit: Int) async throws -> [ChannelEntity] {
        let names = playlistNames(container)
        let bookmarks = LibraryLookup.bookmarks(playlistIDs: nil, historyLimit: limit, favoriteLimit: limit, in: container)
        var seen: Set<String> = []
        return (bookmarks.favorites + bookmarks.history)
            .compactMap { ChannelEntity($0.item, playlistName: names[$0.item.playlistID]) }
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map { $0 }
    }

    static func playlistNames(_ container: ModelContainer) -> [UUID: String] {
        Dictionary(LibraryLookup.visiblePlaylists(in: container).map { ($0.playlistID, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
