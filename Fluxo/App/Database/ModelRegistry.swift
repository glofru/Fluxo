//
//  ModelRegistry.swift
//  Fluxo
//
//  Every SwiftData model of the app, in one place: the schema of the stores is built from these lists. Add new
//  `@Model` types to `user` or `cache` (and so to `all`), and see "Changing a model" in `FluxoSchema.swift`.
//

import SwiftData

enum ModelRegistry {
    /// The current schema (`FluxoSchemaV2`).
    static var all: [any PersistentModel.Type] {
        user + cache
    }

    /// What the user made and cannot get back from a server: playlists (with their addresses and credentials), guide
    /// sources and the channels matched by hand, favorites, watch history and progress, series progress, reminders.
    /// In the library store, which is backed up and never recreated without the user's consent.
    static let user: [any PersistentModel.Type] = [
        ChannelBookmark.self,
        EPGChannelOverride.self,
        EPGSource.self,
        Playlist.self,
        ProgrammeReminder.self,
        SeriesBookmark.self,
    ]

    /// What an import writes and a refresh writes again: the channels, categories and series of the playlists, the
    /// channels and programmes of the guides. In the cache store, outside the backups, recreated whenever it cannot be
    /// opened (the next refresh fills it again).
    static let cache: [any PersistentModel.Type] = [
        EPGChannel.self,
        EPGProgramme.self,
        PlaylistChannel.self,
        PlaylistChannelGroup.self,
        PlaylistSeries.self,
    ]
}
