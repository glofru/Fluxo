//
//  Stubs.swift
//  FeaturedCheck
//
//  What the sources compiled by Tools/FeaturedCheck use from SwiftUI files that the tool leaves out.
//

import Foundation

/// `ChannelRows.swift`: a category as the UI hands it around (LibraryLookup returns them).
struct GroupItem: Sendable {
    let name: String

    init(_ group: PlaylistChannelGroup) {
        name = group.name
    }
}
