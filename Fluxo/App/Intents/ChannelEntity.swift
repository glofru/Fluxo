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

struct ChannelEntity: AppEntity, IndexedEntity {

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
    }

    /// The system's reference to a channel, for on-screen awareness (`View.appEntityIdentifier(_:)`).
    static func entityIdentifier(for item: ChannelItem) -> EntityIdentifier? {
        ChannelEntity(item).map { EntityIdentifier(for: $0) }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\([group, playlistName].compactMap { $0 }.joined(separator: " · "))",
            image: DisplayRepresentation.Image(systemName: item.kind.systemImage)
        )
    }

    /// Spotlight: the name, the kind, the group and the playlist, so "Sky Sport F1", "F1" or "Sport" find it.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.displayName = name
        attributes.contentDescription = [item.kind.title, group, playlistName].compactMap { $0 }.joined(separator: " · ")
        attributes.keywords = [group, item.kind.title, playlistName].compactMap { $0 } + ChannelNameNormalizer.tokens(name)
        return attributes
    }
}

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
    private var services: AppServices

    static let suggestionLimit = 40

    func entities(for identifiers: [ChannelEntity.ID]) async throws -> [ChannelEntity] {
        let container = services.container
        let names = Self.playlistNames(container)
        return identifiers.compactMap { identifier in
            ChannelEntityID.key(for: identifier, in: container)
                .flatMap { LibraryLookup.channel(forKey: $0, in: container) }
                .flatMap { ChannelEntity($0, playlistName: names[$0.playlistID]) }
        }
    }

    func entities(matching string: String) async throws -> [ChannelEntity] {
        let container = services.container
        let playlists = LibraryLookup.visiblePlaylists(in: container)
        let names = Dictionary(playlists.map { ($0.playlistID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let items = await LibraryLookup.searchChannels(string, importIDs: playlists.map(\.importID), limit: 30, in: container)
        return items.compactMap { ChannelEntity($0, playlistName: names[$0.playlistID]) }
    }

    func suggestedEntities() async throws -> [ChannelEntity] {
        try await Self.suggestions(container: services.container, limit: Self.suggestionLimit)
    }

    /// Favorites first, then the watch history, without repeats.
    static func suggestions(container: ModelContainer, limit: Int) async throws -> [ChannelEntity] {
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
