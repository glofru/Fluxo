//
//  ModelRegistry.swift
//  Fluxo
//
//  Every SwiftData model of the app, in one place: the schema of the store is built from this
//  list. Add new `@Model` types here.
//

import SwiftData

enum ModelRegistry {
    static let all: [any PersistentModel.Type] = [
        ChannelBookmark.self,
        EPGChannel.self,
        EPGChannelOverride.self,
        EPGProgramme.self,
        EPGSource.self,
        Playlist.self,
        PlaylistChannel.self,
        PlaylistChannelGroup.self,
        PlaylistSeries.self,
        ProgrammeReminder.self,
        SeriesBookmark.self,
    ]
}
