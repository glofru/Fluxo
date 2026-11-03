//
//  PlayChannelAction.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftUI

/// Plays a channel and records it in the watch history. Set once at the root of the app.
///
/// It holds references rather than a closure so the environment value compares equal across root re-renders
/// and does not invalidate every card that reads it.
struct PlayChannelAction: Equatable {
    private let library: ChannelLibrary?
    private let player: AVPlayerViewModel?

    init() {
        library = nil
        player = nil
    }

    init(library: ChannelLibrary, player: AVPlayerViewModel) {
        self.library = library
        self.player = player
    }

    @MainActor
    func callAsFunction(_ item: ChannelItem) {
        library?.recordWatch(item)
        player?.play(item)
    }

    static func == (lhs: PlayChannelAction, rhs: PlayChannelAction) -> Bool {
        lhs.library === rhs.library && lhs.player === rhs.player
    }
}

extension EnvironmentValues {
    @Entry var playChannel = PlayChannelAction()
}
