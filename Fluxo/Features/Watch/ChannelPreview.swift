//
//  ChannelPreview.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-04.
//

import SwiftUI

/// Card of a channel in the Home rows and grids: a landscape logo card for live channels and a
/// poster for movies and series. Tapping plays it; the context menu adds it to the favorites.
///
/// Every live card is 5:3 and every poster 2:3, whatever the artwork, so rows and grids line up.
struct ChannelPreview: View {

    static let liveSize = CGSize(width: 220, height: 132)
    static let posterSize = CGSize(width: 150, height: 225)

    let item: ChannelItem
    /// Shown under the title (e.g. the playlist name when several playlists are listed together).
    var subtitle: String?
    /// Extra context menu entries (e.g. "Remove from history").
    var extraActions: [ChannelCardAction] = []
    /// Width of the card (grids stretch cards to fill their columns); nil for the standard size. The height
    /// keeps the 5:3 (live) or 2:3 (poster) shape.
    var width: CGFloat?

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The player zooms out of this card's artwork. Unique per card: the same channel can be in several rows.
    @State private var sourceID = UUID().uuidString

    private let borderShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    private var size: CGSize {
        let standard = item.kind.usesPosterArtwork ? Self.posterSize : Self.liveSize
        guard let width else {
            return standard
        }
        return CGSize(width: width, height: (width * standard.height / standard.width).rounded())
    }

    var body: some View {
        let isFavorite = library.isFavorite(item)
        Button {
            playChannel(item, from: sourceID)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ChannelArtwork(logo: item.logo, name: item.displayName, kind: item.kind, size: size)
                    .frame(width: size.width, height: size.height)
                    .background(artworkBackground)
                    .clipShape(borderShape)
                    // Badges are content: a small material, not glass (glass is for controls).
                    .overlay(alignment: .topTrailing) {
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption.bold())
                                .foregroundStyle(Theme.favorite)
                                .padding(6)
                                .background(.thinMaterial, in: .circle)
                                .padding(8)
                                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                                .accessibilityLabel("Favorite")
                        }
                    }
                    // What a live channel shows now, from the TV guide.
                    .overlay(alignment: .bottom) {
                        ChannelCardProgrammeOverlay(item: item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .clipShape(borderShape)
                    }
                    // How far a movie or episode was watched.
                    .overlay(alignment: .bottom) {
                        if let progress = library.watchProgress(for: item) {
                            ProgrammeProgressBar(progress: progress.fraction, tint: .white, height: 4)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 10)
                                .shadow(color: .black.opacity(0.5), radius: 3)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay {
                        borderShape.strokeBorder(Theme.surfaceStroke)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if item.kind != .live, library.watchProgress(for: item) == nil {
                            Image(systemName: item.kind.systemImage)
                                .font(.caption2.bold())
                                .padding(5)
                                .background(.thinMaterial, in: .circle)
                                .padding(8)
                                .accessibilityHidden(true)
                        }
                    }
                    .playerTransitionSource(id: sourceID)
                    .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4), value: isFavorite)

                // Two lines of title, or one line of title and one of subtitle: cards with and without a
                // subtitle are as tall, and a one-line name leaves no gap above its subtitle.
                Text(item.displayName)
                    .font(Theme.Typography.cardTitle)
                    .lineLimit(subtitle == nil ? 2 : 1, reservesSpace: true)
                    .multilineTextAlignment(.leading)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: size.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle())
        .cardHoverEffect()
        .contextMenuPreviewShape(borderShape)
        .contextMenu {
            ChannelContextMenu(item: item, isFavorite: isFavorite, extraActions: extraActions)
        }
        // Drag onto the Favorites tab or row (iPad), or into another window.
        .channelDraggable(item)
        .accessibilityLabel(Text(accessibilityLabel(isFavorite: isFavorite)))
        .accessibilityHint(item.kind == .live ? "Plays the channel" : "Plays the video")
        .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            library.toggleFavorite(item)
        }
        .help(item.displayName)
    }

    private func accessibilityLabel(isFavorite: Bool) -> String {
        var parts = [item.displayName, item.kind.title]
        if let subtitle {
            parts.append(subtitle)
        }
        if isFavorite {
            parts.append("Favorite")
        }
        return parts.joined(separator: ", ")
    }

    private var artworkBackground: some ShapeStyle {
        LinearGradient(
            colors: [Color.artworkPlaceholder.opacity(0.55), Color.artworkPlaceholder.opacity(0.25)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// An extra context menu entry of a channel card.
struct ChannelCardAction: Identifiable {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    var id: String {
        title
    }
}

/// Play / favorite entries shared by every channel card and row.
struct ChannelContextMenu: View {

    let item: ChannelItem
    let isFavorite: Bool
    var extraActions: [ChannelCardAction] = []

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @Environment(EPGStore.self) private var epg: EPGStore?
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @Environment(\.openChannelWindow) private var openChannelWindow

    var body: some View {
        Text(item.displayName)

        if library.watchProgress(for: item) != nil {
            Button("Resume", systemImage: "play.fill") {
                playChannel(item)
            }
            Button("Play from Beginning", systemImage: "arrow.counterclockwise") {
                library.saveWatchProgress(for: item, position: 0, duration: library.watchProgress(for: item)?.duration ?? 1)
                playChannel(item)
            }
        } else {
            Button("Play", systemImage: "play.fill") {
                playChannel(item)
            }
        }

        if openChannelWindow.isAvailable, item.url != nil {
            // iPad: the channel in a window of its own, e.g. next to the guide in Split View.
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                openChannelWindow(item)
            }
        }

        if item.url != nil {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star") {
                library.toggleFavorite(item)
            }
        }

        if let epg, let navigation, item.kind == .live, epg.hasGuide {
            Button("Today's Schedule", systemImage: "calendar.day.timeline.left") {
                navigation.scheduleChannel = item
            }
        }

        if let epg, item.kind == .live, item.url != nil {
            Button("Guide Channel…", systemImage: "calendar.badge.checkmark") {
                epg.matchingTarget = item
            }
        }

        ForEach(extraActions) { action in
            Button(action.title, systemImage: action.systemImage, role: action.role, action: action.action)
        }
    }
}

/// Press feedback for cards, plus a lift on hover and keyboard focus (macOS).
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration)
    }
}

private struct CardButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @State private var isHovered = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isLifted = (isHovered || isFocused) && !configuration.isPressed
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : (isLifted && !reduceMotion ? 1.03 : 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .shadow(color: .black.opacity(isLifted ? 0.28 : 0), radius: isLifted ? 14 : 0, y: isLifted ? 8 : 0)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
            .animation(.spring(duration: 0.3), value: isLifted)
            #if os(macOS)
            .onHover { hovering in
                isHovered = hovering
            }
            #endif
    }
}

/// Logo of a live channel (fitted, centered) or poster of an on-demand item (filling the card).
/// Decoded at the displayed size by the shared logo loader. Without usable artwork the whole card shows
/// the channel's initials on a gradient tinted from its name.
struct ChannelArtwork: View {

    let logo: String?
    let name: String
    let kind: ChannelContentKind
    let size: CGSize

    @State private var isUnavailable = false

    var body: some View {
        let isPoster = kind.usesPosterArtwork
        let imageSize = isPoster ? size : CGSize(width: size.width * 0.5, height: size.height * 0.6)
        ZStack {
            if logo == nil {
                ArtworkPlaceholder(name: name, kind: kind)
                    .frame(width: size.width, height: size.height)
            } else {
                // LogoImage stays in the hierarchy even when it fails: it is the only writer of the
                // preference, so removing it would reset the preference and make the card flip forever.
                LogoImage(
                    source: logo,
                    size: imageSize,
                    contentMode: isPoster ? .fill : .fit,
                    accessibilityLabel: name
                ) { phase in
                    // Reported to the card, which then draws the placeholder over its full size.
                    ZStack {
                        Color.clear
                        if phase == .loading {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                    }
                    .preference(key: ArtworkUnavailableKey.self, value: phase == .unavailable)
                }
                if isUnavailable {
                    ArtworkPlaceholder(name: name, kind: kind)
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .onPreferenceChange(ArtworkUnavailableKey.self) { unavailable in
            isUnavailable = unavailable
        }
        .onChange(of: logo) {
            isUnavailable = false
        }
    }
}

private struct ArtworkUnavailableKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Initials on a gradient tinted from the name (stable across launches) when a channel has no usable artwork.
struct ArtworkPlaceholder: View {
    let name: String
    let kind: ChannelContentKind

    var body: some View {
        let hue = Self.hue(for: name)
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.62),
                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.38),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 4) {
                Text(initials)
                    .font(.title2.weight(.heavy))
                    .minimumScaleFactor(0.5)
                Image(systemName: kind.systemImage)
                    .font(.caption)
                    .opacity(0.75)
            }
            .foregroundStyle(.white)
            .padding(6)
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "|" || $0 == "_" }).prefix(2)
        let letters = words.compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
        let result = letters.map(String.init).joined().uppercased()
        return result.isEmpty ? "TV" : result
    }

    /// djb2 over the name: `String.hashValue` is randomized per launch, which would change the colors.
    static func hue(for name: String) -> Double {
        var hash: UInt64 = 5_381
        for scalar in name.unicodeScalars {
            hash = (hash &<< 5) &+ hash &+ UInt64(scalar.value)
        }
        return Double(hash % 360) / 360
    }
}

#Preview("Cards") {
    ScrollView(.horizontal) {
        HStack(alignment: .top) {
            ForEach(PreviewSampleData.sampleItems) { item in
                ChannelPreview(item: item, subtitle: "Preview playlist")
            }
        }
        .padding()
    }
    .fluxoPreviewEnvironment()
}
