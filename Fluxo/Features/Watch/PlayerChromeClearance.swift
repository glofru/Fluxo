//
//  PlayerChromeClearance.swift
//  Fluxo
//

import CoreGraphics

/// The room the player's controls take at the top and the bottom of the video while they show, as laid out: the top
/// bar and the bottom bar grow with the text size, the recording and Cast messages and a phone's two-row top bar, so
/// a fixed allowance is too small at large text sizes. What the player shows over the middle of the video (the
/// message cards, `PlayerMessageCard`; the next-episode button and card, `NextEpisodeOverlay`) stays clear of them.
/// Zero while the controls are hidden.
struct PlayerChromeClearance: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}
