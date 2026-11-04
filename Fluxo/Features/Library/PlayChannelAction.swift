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
    /// The window the action plays in (iPad: the player moves to the window the channel was picked in).
    private let coordinator: WindowCoordinator?
    private let windowID: UUID?

    init() {
        library = nil
        player = nil
        coordinator = nil
        windowID = nil
    }

    init(library: ChannelLibrary, player: AVPlayerViewModel, coordinator: WindowCoordinator? = nil, windowID: UUID? = nil) {
        self.library = library
        self.player = player
        self.coordinator = coordinator
        self.windowID = windowID
    }

    /// - Parameter sourceID: the view the player zooms out of (`playerTransitionSource(id:)`); nil zooms
    ///   from the mini player.
    @MainActor
    func callAsFunction(_ item: ChannelItem, from sourceID: String? = nil) {
        library?.recordWatch(item)
        if let coordinator, let windowID {
            coordinator.move(.player, to: windowID)
        }
        player?.presentationSourceID = sourceID
        player?.play(item)
    }

    static func == (lhs: PlayChannelAction, rhs: PlayChannelAction) -> Bool {
        lhs.library === rhs.library && lhs.player === rhs.player && lhs.coordinator === rhs.coordinator && lhs.windowID == rhs.windowID
    }
}

extension EnvironmentValues {
    @Entry var playChannel = PlayChannelAction()
}
