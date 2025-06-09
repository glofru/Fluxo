//
//  Playlist.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-08.
//

import SwiftData
import Foundation

@Model
class Playlist {
    private(set) var id: UUID
    var name: String
    var url: URL
    private(set) var createdOn: Date

    init(id: UUID, name: String, url: URL, createdOn: Date) {
        self.id = id
        self.name = name
        self.url = url
        self.createdOn = createdOn
    }
}
