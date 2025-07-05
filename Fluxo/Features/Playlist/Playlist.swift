//
//  Playlist.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-08.
//

import Foundation
import SwiftData

@Model
class Playlist: Identifiable {
    @Attribute(.unique)
    private(set) var uuid: UUID
    var name: String
    var url: URL
    private(set) var createdOn: Date

    init(uuid: UUID, name: String, url: URL, createdOn: Date) {
        self.uuid = uuid
        self.name = name
        self.url = url
        self.createdOn = createdOn
    }
}

@Model
class PlaylistChannel: Identifiable {
    private(set) var uuid: UUID
    var name: String?
    var logo: String?
    var duration: Int?
    var group: String
    var url: URL?
    @Relationship(deleteRule: .cascade)
    var playlist: Playlist

    init(uuid: UUID, name: String? = nil, logo: String? = nil, duration: Int? = nil, group: String = "", url: URL? = nil, playlist: Playlist) {
        self.uuid = uuid
        self.name = name
        self.logo = logo
        self.duration = duration
        self.group = group
        self.url = url
        self.playlist = playlist
    }

    var isLiveContent: Bool {
        url?.pathExtension.isEmpty ?? false
    }
}

@Model
class PlaylistChannelGroup: Identifiable {
    private(set) var uuid: UUID
    var name: String
    @Relationship(deleteRule: .cascade)
    var playlistChannels: [PlaylistChannel]

    init(uuid: UUID, name: String, playlistChannels: [PlaylistChannel]) {
        self.uuid = uuid
        self.name = name
        self.playlistChannels = playlistChannels
    }
}
