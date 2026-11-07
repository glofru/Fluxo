//
//  HeroActions.swift
//  Fluxo
//
//  The glass actions under a hero: Home's billboard and the top of a series page.
//

import SwiftUI

/// The prominent Play button of a hero and the round icon buttons after it (favorite, more), in one glass
/// container. They share a row while Play's title fits on one line next to them; when it does not (long
/// translations, the accessibility text sizes, "Continue S12 E104"), Play takes the whole width and the icon
/// buttons go on the row under it.
///
/// Play's title is always one line, never wrapped: a word that does not fit would be hyphenated into a tall
/// pill ("Ab-spie-len"). It grows up to AX3 (its title then shrinks to fit the width if needed, and a long press
/// shows it in the Large Content Viewer), like the other controls that keep their size.
struct HeroActions<Secondary: View>: View {
    let title: String
    let systemImage: String
    var isDisabled = false
    let action: () -> Void
    @ViewBuilder var secondary: () -> Secondary

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    playButton(fillsWidth: false)
                    secondary()
                }
                VStack(alignment: .leading, spacing: 10) {
                    playButton(fillsWidth: true)
                    HStack(spacing: 10) {
                        secondary()
                    }
                }
            }
        }
        .controlSize(.large)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private func playButton(fillsWidth: Bool) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)
                // On the shared row at its full size (that row is used only when it fits); on the full-width
                // button smaller rather than cut or wrapped.
                .minimumScaleFactor(fillsWidth ? 0.5 : 1)
                .fixedSize(horizontal: !fillsWidth, vertical: false)
                .padding(.horizontal, 8)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .contentTransition(.numericText())
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accentFill)
        .disabled(isDisabled)
        .largeContentControl(title, systemImage: systemImage)
    }
}
