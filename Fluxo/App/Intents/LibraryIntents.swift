//
//  LibraryIntents.swift
//  Fluxo
//
//  Siri and Shortcuts actions for the library: favorites, search (in the app, or as an answer with results),
//  and personal recommendations.
//

import AppIntents
import Foundation
import SwiftUI

struct ToggleFavoriteIntent: AppIntent {

    static let title: LocalizedStringResource = "Toggle Favorite"
    static let description = IntentDescription("Adds a channel to your favorites, or removes it if it is one.", categoryName: "Library")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Channel", description: "Leave empty for the channel that is playing.")
    var channel: ChannelEntity?

    @Dependency
    var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle favorite for \(\.$channel)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog & ShowsSnippetView {
        guard let item = channel?.item ?? services.player.currentItem else {
            throw FluxoIntentError.nothingPlaying
        }
        services.library.toggleFavorite(item)
        let isFavorite = services.library.isFavorite(item)
        let dialog: IntentDialog = isFavorite ? "Added \(item.displayName) to your favorites." : "Removed \(item.displayName) from your favorites."
        return .result(
            value: isFavorite,
            dialog: dialog,
            view: ConfirmationSnippetView(
                systemImage: isFavorite ? "star.fill" : "star.slash",
                title: item.displayName,
                subtitle: isFavorite ? String(localized: "In your favorites") : String(localized: "Not in your favorites"),
                tint: Theme.favorite
            )
        )
    }
}

/// Adds a channel to the favorites; does nothing when it already is one. The Siri phrases "Add … to my Fluxo
/// favorites" and "Favorite this channel" use it, so saying them twice never removes the channel.
struct AddFavoriteIntent: AppIntent {

    static let title: LocalizedStringResource = "Add to Favorites"
    static let description = IntentDescription("Adds a channel to your favorites. It stays a favorite if it already is one.", categoryName: "Library")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Channel", description: "Leave empty for the channel that is playing.")
    var channel: ChannelEntity?

    @Dependency
    var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$channel) to favorites")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let item = channel?.item ?? services.player.currentItem else {
            throw FluxoIntentError.nothingPlaying
        }
        let wasFavorite = services.library.isFavorite(item)
        if !wasFavorite {
            services.library.setFavorite(true, for: item)
        }
        let dialog: IntentDialog = wasFavorite ? "\(item.displayName) is already in your favorites." : "Added \(item.displayName) to your favorites."
        return .result(
            dialog: dialog,
            view: ConfirmationSnippetView(systemImage: "star.fill", title: item.displayName, subtitle: String(localized: "In your favorites"), tint: Theme.favorite)
        )
    }
}

/// Opens Search with a query (the system "search in app" intent). On iOS and from macOS 27 it adopts the system
/// `searchInApp` schema (see `AppSchemaAdoption.swift`).
struct SearchInFluxoIntent: ShowInAppSearchResultsIntent {

    static let title: LocalizedStringResource = "Search in Fluxo"
    static let description = IntentDescription("Opens Fluxo's search with your words. Searches like “football tonight” also show matching programmes.", categoryName: "Library", searchKeywords: ["Find", "Channel", "Show", "Programme"])
    static let searchScopes: [StringSearchScope] = [.general, .tv, .movies]

    @Parameter(title: "Search", requestValueDialog: "What are you looking for?")
    var criteria: StringSearchCriteria

    @Dependency
    var services: AppServices

    @MainActor
    func perform() async throws -> some IntentResult {
        services.showSearch(criteria.term)
        return .result()
    }
}

/// Removes a channel from the favorites; does nothing when it is not one.
struct RemoveFavoriteIntent: AppIntent {

    static let title: LocalizedStringResource = "Remove from Favorites"
    static let description = IntentDescription("Removes a channel from your favorites. Nothing changes if it is not one.", categoryName: "Library")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Channel", description: "Leave empty for the channel that is playing.")
    var channel: ChannelEntity?

    @Dependency
    var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Remove \(\.$channel) from favorites")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let item = channel?.item ?? services.player.currentItem else {
            throw FluxoIntentError.nothingPlaying
        }
        let wasFavorite = services.library.isFavorite(item)
        if wasFavorite {
            services.library.setFavorite(false, for: item)
        }
        let dialog: IntentDialog = wasFavorite ? "Removed \(item.displayName) from your favorites." : "\(item.displayName) is not in your favorites."
        return .result(
            dialog: dialog,
            view: ConfirmationSnippetView(systemImage: "star.slash", title: item.displayName, subtitle: String(localized: "Not in your favorites"), tint: Theme.favorite)
        )
    }
}

/// The favorite channels, in the user's order, as a value for shortcuts and as an answer for Siri.
struct GetFavoritesIntent: AppIntent {

    static let title: LocalizedStringResource = "Get Favorites"
    static let description = IntentDescription("Lists your favorite channels, movies and series, in your order.", categoryName: "Library")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Type")
    var kind: ChannelKindAppEnum?

    @Dependency
    var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Get favorite \(\.$kind)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ChannelEntity]> & ProvidesDialog & ShowsSnippetView {
        let container = services.container
        let names = ChannelEntityQuery.playlistNames(container)
        let favorites = LibraryLookup.bookmarks(playlistIDs: nil, historyLimit: 0, favoriteLimit: 200, in: container).favorites
        let entities = favorites
            .filter { kind == nil || $0.item.kind == kind?.contentKind }
            .compactMap { ChannelEntity($0.item, playlistName: names[$0.item.playlistID]) }
        guard !entities.isEmpty else {
            throw FluxoIntentError.noFavorites
        }
        let rows = entities.map { ChannelListSnippetView.Row(id: $0.id, name: $0.name, kind: $0.item.kind, detail: $0.group) }
        let top = entities.prefix(3).map(\.name).formatted(.list(type: .and))
        let dialog: IntentDialog = entities.count <= 3 ? "Your favorites are \(top)." : "You have \(entities.count) favorites, starting with \(top)."
        return .result(value: entities, dialog: dialog, view: ChannelListSnippetView(rows: rows))
    }
}

/// Finds channels and answers with them, without opening the app. Understands natural language with Apple
/// Intelligence ("italian news channels", "something like Sky Sport F1").
struct FindChannelsIntent: AppIntent {

    static let title: LocalizedStringResource = "Find Channels"
    static let description = IntentDescription("Finds channels, movies and series in your playlists. With Apple Intelligence it understands requests like “italian news channels”.", categoryName: "Library")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Search", requestValueDialog: "What are you looking for?")
    var query: String

    @Parameter(title: "Type")
    var kind: ChannelKindAppEnum?

    @Dependency
    var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$kind) matching \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ChannelEntity]> & ProvidesDialog & ShowsSnippetView {
        let importIDs = services.allImportIDs()
        guard !importIDs.isEmpty else {
            throw FluxoIntentError.noPlaylists
        }
        var items = await LibraryLookup.searchChannels(query, importIDs: importIDs, kind: kind?.contentKind, limit: 20, in: services.container)
        if SmartSearch.isNaturalLanguage(query) {
            var plan = await SmartSearch.plan(for: query, useModel: services.intelligence.isAvailable)
            if let kind {
                plan.kind = SmartSearchPlan.Kind(kind.contentKind)
            }
            if !plan.isEmpty {
                // Channels only: the guide part of smart search is not part of this answer.
                let smart = await SmartSearch.run(plan, query: query, importIDs: importIDs, container: services.container, epg: services.epg, includeGuide: false)
                if !smart.channels.isEmpty {
                    items = smart.channels
                }
            }
        }
        let names = ChannelEntityQuery.playlistNames(services.container)
        let entities = items.compactMap { ChannelEntity($0, playlistName: names[$0.playlistID]) }
        guard let first = entities.first else {
            throw FluxoIntentError.channelNotFound(query)
        }
        let rows = entities.map { ChannelListSnippetView.Row(id: $0.id, name: $0.name, kind: $0.item.kind, detail: $0.group) }
        let dialog: IntentDialog = entities.count == 1 ? "I found \(first.name)." : "I found \(entities.count) channels. The best match is \(first.name)."
        return .result(value: entities, dialog: dialog, view: ChannelListSnippetView(rows: rows))
    }
}

/// "What should I watch?": the For You suggestions of Home.
struct GetRecommendationsIntent: AppIntent {

    static let title: LocalizedStringResource = "Get Suggestions"
    static let description = IntentDescription("Suggests channels to watch now, from what you watch, your favorites and the TV guide. With Apple Intelligence the suggestions are chosen and explained on this device.", categoryName: "Library")
    static let supportedModes: IntentModes = .background

    @Dependency
    var services: AppServices

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ChannelEntity]> & ProvidesDialog & ShowsSnippetView {
        let importIDs = services.allImportIDs()
        guard !importIDs.isEmpty else {
            throw FluxoIntentError.noPlaylists
        }
        _ = await services.waitForGuide()
        let list = await services.intelligence.recommendations.channels(for: RecommendationScope(importIDs: importIDs))
        let items = list?.items ?? []
        let names = ChannelEntityQuery.playlistNames(services.container)
        // The opaque entity id, not the bookmark key: that is the stream URL, which may hold credentials.
        let suggestions = items.compactMap { recommendation in
            ChannelEntity(recommendation.item, playlistName: names[recommendation.item.playlistID]).map { (recommendation, $0) }
        }
        let entities = suggestions.map(\.1)
        guard !entities.isEmpty else {
            throw FluxoIntentError.noSuggestions
        }
        let rows = suggestions.map { recommendation, entity in
            ChannelListSnippetView.Row(id: entity.id, name: entity.name, kind: recommendation.item.kind, detail: recommendation.reason)
        }
        let top = entities.prefix(3).map(\.name).formatted(.list(type: .and))
        return .result(
            value: entities,
            dialog: "You might like \(top).",
            view: ChannelListSnippetView(rows: rows, showsSparkles: list?.isPersonalized ?? false)
        )
    }
}

extension SmartSearchPlan.Kind {
    init(_ kind: ChannelContentKind) {
        switch kind {
        case .live:
            self = .live
        case .movie:
            self = .movies
        case .series:
            self = .series
        }
    }
}
