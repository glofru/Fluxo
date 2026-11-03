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
        Playlist.self,
        PlaylistChannel.self,
        PlaylistChannelGroup.self,
    ]
}
