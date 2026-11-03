//
//  Theme.swift
//  Fluxo
//
//  The Fluxo theme in one place: brand palette, semantic color tokens, surfaces and the type scale.
//
//  The palette comes from the app icon (Design/Icon/generate_layers.py): Fluxo Violet #6A4CFF on Fluxo Ink
//  #140F3C, crossed by three streams, Signal Cyan #3CD6FF, Lilac #A08CFF and Flux Pink #FF5C9E. Every color is
//  an asset color with a light and a dark variant (Assets.xcassets): the light variants are deeper so that
//  text and thin strokes keep their contrast on white.
//
//  Feature code uses the semantic tokens (`Theme.live`, `Theme.surface`, `Theme.Typography.cardTitle`, …),
//  never raw colors, so the look can change here without touching the screens. System colors are kept only
//  where they carry a meaning users already know, one meaning each: red for recording and for errors (the
//  system's own destructive buttons are red too), yellow for favorites, orange for warnings.
//

import SwiftUI

enum Theme {

    // MARK: Brand palette

    /// Fluxo Violet: the accent (tint of buttons, selections, links). Same as the app's AccentColor.
    static let accent = Color("AccentColor")
    /// Signal Cyan: the leading stream of the icon.
    static let cyan = Color("FluxoCyan")
    /// Lilac: the middle stream of the icon.
    static let lilac = Color("FluxoLilac")
    /// Flux Pink: the trailing stream of the icon.
    static let pink = Color("FluxoPink")
    /// Fluxo Ink: the deep background of the icon (the same in light and dark mode).
    static let ink = Color("FluxoInk")

    // MARK: Semantic colors

    /// Live TV: LIVE badges, the live edge of the time-shift bar, the "now" line of the guide.
    static let live = pink
    /// Time-shifted playback (behind live): the "-m:ss" of "Go Live".
    static let timeShift = cyan
    /// Recording in progress. Red, as on every recorder.
    static let recording = Color.red
    /// Favorites (stars).
    static let favorite = Color.yellow
    /// Warnings and recoverable problems (reconnecting, playlists to refresh).
    static let warning = Color.orange
    /// Errors: playback that failed, invalid input, imports that failed.
    static let error = Color.red

    // MARK: Surfaces

    /// Content surfaces on the screen background: cards, banners, rows (a faint violet tint of the background).
    static let surface = Color("FluxoSurface")
    /// Hairline border of content surfaces.
    static let surfaceStroke = Color.primary.opacity(0.07)

    // MARK: Gradients

    /// The three streams of the icon, leading to trailing: the played part of the player's timeline.
    static let streamGradient = LinearGradient(colors: [cyan, lilac, pink], startPoint: .leading, endPoint: .trailing)
    /// The icon background (violet to ink): placeholders and backdrops without artwork.
    static let brandGradient = LinearGradient(colors: [accent, ink], startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Player

    /// Colors of the full-screen player, which is always dark.
    enum Player {
        /// The unplayed track of the timeline.
        static let track = Color.white.opacity(0.22)
        /// Labels on the video (time, status).
        static let secondaryLabel = Color.white.opacity(0.75)
        /// Top and bottom scrims behind the controls.
        static func scrim(reduceTransparency: Bool) -> Color {
            .black.opacity(reduceTransparency ? 0.9 : 0.7)
        }
    }

    // MARK: Typography

    /// The type scale. All Dynamic Type styles, so everything scales with the user's text size.
    enum Typography {
        /// Billboard and featured card titles.
        static let heroTitle = Font.title.bold()
        /// Home section titles ("Continue Watching", group names).
        static let sectionTitle = Font.title3.bold()
        /// Channel names on cards and in the mini player.
        static let cardTitle = Font.subheadline.weight(.semibold)
        /// Second lines on cards (group, playlist, "now").
        static let cardSubtitle = Font.caption
        /// The channel name in the full-screen player.
        static let playerTitle = Font.headline
        /// Status lines under the player title.
        static let playerStatus = Font.caption.weight(.semibold)
        /// Small capsules such as LIVE.
        static let badge = Font.caption2.weight(.heavy)
        /// Timeline times.
        static let timecode = Font.caption.monospacedDigit()
    }
}

/// The LIVE capsule of live channels (player, mini player, cards).
struct LiveBadge: View {
    var compact = false

    var body: some View {
        Text("LIVE")
            .font(Theme.Typography.badge)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(Theme.live, in: .capsule)
            .foregroundStyle(.white)
            .accessibilityLabel("Live")
    }
}

#Preview("Theme") {
    VStack(alignment: .leading, spacing: 16) {
        HStack {
            ForEach(Array([Theme.accent, Theme.cyan, Theme.lilac, Theme.pink, Theme.ink].enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 10).fill(color).frame(width: 48, height: 48)
            }
        }
        Capsule().fill(Theme.streamGradient).frame(height: 6)
        HStack {
            LiveBadge()
            LiveBadge(compact: true)
        }
        Text("Sky Sport F1").font(Theme.Typography.cardTitle)
            .padding()
            .background(Theme.surface, in: .rect(cornerRadius: 16))
    }
    .padding()
}
