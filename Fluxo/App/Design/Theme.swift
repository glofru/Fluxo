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
//  never raw colors, so the look can change here without touching the screens. The hues of red (recording and
//  errors), yellow (favorites) and orange (warnings) keep the meaning users know from the system colors, one
//  meaning each, in tones of our own that pass the contrast checks below.
//
//  Contrast (WCAG 2.2 AA: 4.5:1 for text, 3:1 for icons, strokes and large text; measured on white, the light
//  surface #F4F2FB, black and the dark surface #17142B): every token that is drawn as text or as a thin glyph
//  passes 4.5:1 on the backgrounds of its mode (the favorite yellow, an icon only, passes 3:1). Colors drawn
//  behind white text (`accentFill`, `liveFill`, `recordingFill`) are the same deep tone in both modes, since the
//  bright dark-mode accent, pink and red give white text only about 3:1. Every asset also has an Increase Contrast
//  variant (deeper in light mode, lighter in dark mode, 6:1 or more), and the hairlines and translucent player
//  colors below get stronger with Increase Contrast too. `Tools/Simulator/AccessibilityAudit` checks contrast on
//  screen.
//

import SwiftUI

enum Theme {

    // MARK: Brand palette

    /// Fluxo Violet: the accent (tint of buttons, selections, links). Same as the app's AccentColor.
    static let accent = Color("AccentColor")
    /// Fluxo Violet as a fill behind white text and glyphs (selected chips, prominent buttons, badges): the
    /// light-mode violet in both modes (5.1:1 with white; the dark-mode accent would give 3.3:1).
    static let accentFill = Color("FluxoAccentFill")
    /// Signal Cyan: the leading stream of the icon.
    static let cyan = Color("FluxoCyan")
    /// Lilac: the middle stream of the icon.
    static let lilac = Color("FluxoLilac")
    /// Flux Pink: the trailing stream of the icon.
    static let pink = Color("FluxoPink")
    /// Fluxo Ink: the deep background of the icon (the same in light and dark mode).
    static let ink = Color("FluxoInk")

    // MARK: Semantic colors

    /// Live TV: the "now" line of the guide, live icons and strokes, LIVE as text.
    static let live = pink
    /// Behind white text that means live (the LIVE badge, the current time of the guide): a deep pink.
    static let liveFill = Color("FluxoLiveFill")
    /// Time-shifted playback (behind live): the "-m:ss" of "Go Live".
    static let timeShift = cyan
    /// Recording in progress. Red, as on every recorder.
    static let recording = Color("FluxoRed")
    /// Behind white text that means recording (the REC badge): the deep light-mode red in both modes (5.4:1 with
    /// white; the bright dark-mode red would give about 2.6:1).
    static let recordingFill = Color("FluxoRecordingFill")
    /// Favorites (stars).
    static let favorite = Color("FluxoFavorite")
    /// Behind white text that means favorite (swipe actions): a deep gold.
    static let favoriteFill = Color("FluxoFavoriteFill")
    /// Behind white text in the cyan of the guide (the swipe action that opens a channel's schedule).
    static let cyanFill = Color("FluxoCyanFill")
    /// Warnings and recoverable problems (reconnecting, playlists to refresh).
    static let warning = Color("FluxoOrange")
    /// Errors: playback that failed, invalid input, imports that failed.
    static let error = Color("FluxoRed")

    // MARK: Surfaces

    /// Content surfaces on the screen background: cards, banners, rows (a faint violet tint of the background).
    static let surface = Color("FluxoSurface")
    /// Hairline border of content surfaces; a visible border with Increase Contrast.
    static let surfaceStroke = ContrastAdaptiveStyle(color: .primary, standard: 0.07, increased: 0.35)
    /// Behind logos in rows and tiles: a soft neutral that keeps both dark and light logos readable.
    static let tileBackground = LinearGradient(
        colors: [Color.artworkPlaceholder.opacity(0.55), Color.artworkPlaceholder.opacity(0.28)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Text

    /// Secondary text and glyphs (subtitles, times, counts). The system's secondary label is a translucent gray
    /// of about 3.4:1 on white; this one keeps the hierarchy at about 5.6:1 on white (5:1 on the surfaces and
    /// system fills, 6:1 on black), and gets stronger with Increase Contrast. Use it instead of `.secondary`.
    static let secondaryText = Color("FluxoSecondaryText")
    /// Tertiary text (hints, ended programmes): about 4.6:1 on white instead of the system's 1.9:1.
    static let tertiaryText = Color("FluxoTertiaryText")

    // MARK: Gradients

    /// The three streams of the icon, leading to trailing: the played part of the player's timeline.
    static let streamGradient = LinearGradient(colors: [cyan, lilac, pink], startPoint: .leading, endPoint: .trailing)
    /// The icon background (violet to ink): placeholders and backdrops without artwork.
    static let brandGradient = LinearGradient(colors: [accent, ink], startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Player

    /// Colors of the full-screen player, which is always dark.
    enum Player {
        /// The unplayed track of the timeline.
        static let track = ContrastAdaptiveStyle(color: .white, standard: 0.22, increased: 0.45)
        /// Labels on the video (time, status).
        static let secondaryLabel = ContrastAdaptiveStyle(color: .white, standard: 0.75, increased: 0.92)
        /// Top and bottom scrims behind the controls (stronger without transparency or with more contrast).
        static func scrim(reduceTransparency: Bool, increasedContrast: Bool = false) -> Color {
            .black.opacity(reduceTransparency ? 0.9 : (increasedContrast ? 0.8 : 0.7))
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


/// A translucent color that becomes more opaque with Increase Contrast (hairlines, tracks, labels over video).
struct ContrastAdaptiveStyle: ShapeStyle {
    let color: Color
    let standard: Double
    let increased: Double

    func resolve(in environment: EnvironmentValues) -> Color {
        color.opacity(environment.colorSchemeContrast == .increased ? increased : standard)
    }
}

/// The LIVE capsule of live channels (player, mini player, cards). White on the deep live pink in both modes,
/// with a white hairline under Increase Contrast so the capsule stands out from pink artwork too.
struct LiveBadge: View {
    var compact = false

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text("LIVE")
            .font(Theme.Typography.badge)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(Theme.liveFill, in: .capsule)
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1)
                }
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Live")
            .accessibilityAddTraits(.isStaticText)
    }
}

#Preview("Theme") {
    VStack(alignment: .leading, spacing: 16) {
        HStack {
            ForEach(Array([Theme.accent, Theme.accentFill, Theme.cyan, Theme.lilac, Theme.pink, Theme.liveFill, Theme.ink].enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 10).fill(color).frame(width: 40, height: 40)
            }
        }
        Capsule().fill(Theme.streamGradient).frame(height: 6)
        HStack {
            LiveBadge()
            LiveBadge(compact: true)
        }
        Text(verbatim: "Sky Sport F1").font(Theme.Typography.cardTitle)
            .padding()
            .background(Theme.surface, in: .rect(cornerRadius: 16))
    }
    .padding()
}
