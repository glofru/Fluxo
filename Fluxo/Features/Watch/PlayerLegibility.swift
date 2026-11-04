//
//  PlayerLegibility.swift
//  Fluxo
//
//  Backings that keep the player's guide legible over the video: a thin, mostly clear Liquid Glass platter behind
//  the channel and what is on now / next in the top bar, and a dimmed backdrop for the channel guide sheet. The
//  video still shows through both; bright pictures (snow, a studio, sport on grass) no longer wash out the white
//  text, and dark ones are not covered by a grey slab. Reduce Transparency swaps the glass for a near-opaque fill;
//  Increase Contrast dims more and adds a hairline edge.
//

import SwiftUI

extension Theme.Player {
    /// Corner radius of the top bar's platter: concentric with the channel logo inside it (8 pt corners, 4 pt
    /// padding) at the platter's 10 pt inset.
    static let platterCornerRadius: CGFloat = 18
    /// How far the platter extends past the text it backs. Small, so it hugs the text instead of taking a band
    /// of the video.
    static let platterInsets = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)

    /// The tint of the clear glass: it gives the glass a slight smoky body (a tint alone darkens a white picture
    /// very little).
    static let platterTint = Color.black.opacity(0.2)
    /// The darkening layer on the glass, under the text. Clear glass barely darkens a white picture; this much keeps
    /// white text at about 4.5:1 over one, while a dark picture looks almost unchanged through it.
    static func platterDimming(increasedContrast: Bool) -> Color {
        .black.opacity(increasedContrast ? 0.6 : 0.4)
    }

    /// The fill that replaces the glass with Reduce Transparency.
    static let platterOpaqueFill = Color(white: 0.08).opacity(0.92)
    /// The hairline around the platter with Increase Contrast.
    static let platterEdge = Color.white.opacity(0.35)
}

extension View {
    /// A thin, mostly clear glass platter behind text that sits on the video (the player's channel and programme
    /// information), padded by `Theme.Player.platterInsets`.
    func playerLegibilityPlatter(cornerRadius: CGFloat = Theme.Player.platterCornerRadius) -> some View {
        modifier(PlayerLegibilityPlatter(cornerRadius: cornerRadius))
    }

    /// The backdrop of a sheet over the video (the channel guide): the sheet's glass, dimmed so its rows stay
    /// legible over a bright picture; opaque with Reduce Transparency.
    func playerSheetBackdrop() -> some View {
        modifier(PlayerSheetBackdrop())
    }
}

private struct PlayerLegibilityPlatter: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let increasedContrast = contrast == .increased
        let padded = content.padding(Theme.Player.platterInsets)
        Group {
            if reduceTransparency {
                padded
                    .background(Theme.Player.platterOpaqueFill, in: shape)
            } else {
                // Not interactive: only part of it (now / next) is a button, with its own highlight.
                padded
                    .background(Theme.Player.platterDimming(increasedContrast: increasedContrast), in: shape)
                    .glassEffect(.clear.tint(Theme.Player.platterTint), in: shape)
            }
        }
        .overlay {
            if increasedContrast {
                shape
                    .strokeBorder(Theme.Player.platterEdge, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct PlayerSheetBackdrop: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .presentationBackground {
                if reduceTransparency {
                    Color(white: 0.09)
                } else {
                    // A thin material (it blurs the video so rows do not sit on its detail) with a dark layer that
                    // keeps the sheet dark over a white picture; the video's colors still show through.
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(contrast == .increased ? 0.7 : 0.55))
                }
            }
        #else
        content
        #endif
    }
}
