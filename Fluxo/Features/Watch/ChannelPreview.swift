//
//  ChannelPreview.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-04.
//

import SwiftUI

/// Card of a channel in the Home rows and grids: a landscape logo card for live channels and a
/// poster for movies and series. Tapping plays it; the context menu adds it to the favorites.
struct ChannelPreview: View {

    static let liveSize = CGSize(width: 220, height: 132)
    static let posterSize = CGSize(width: 150, height: 222)

    let item: ChannelItem
    /// Shown under the title (e.g. the playlist name when several playlists are listed together).
    var subtitle: String?
    /// Extra context menu entries (e.g. "Remove from history").
    var extraActions: [ChannelCardAction] = []

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel

    private let borderShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    private var size: CGSize {
        item.kind.usesPosterArtwork ? Self.posterSize : Self.liveSize
    }

    var body: some View {
        let isFavorite = library.isFavorite(item)
        Button {
            playChannel(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ChannelArtwork(logo: item.logo, name: item.displayName, kind: item.kind, size: size)
                    .frame(width: size.width, height: size.height)
                    .background(artworkBackground)
                    .clipShape(borderShape)
                    .overlay(alignment: .topTrailing) {
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.yellow)
                                .padding(6)
                                .glassEffect(.regular, in: .circle)
                                .padding(8)
                                .accessibilityLabel("Favorite")
                        }
                    }
                    .overlay {
                        borderShape.strokeBorder(.white.opacity(0.08))
                    }

                Text(item.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
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
        .contextMenuPreviewShape(borderShape)
        .contextMenu {
            ChannelContextMenu(item: item, isFavorite: isFavorite, extraActions: extraActions)
        }
        .accessibilityHint("Plays the channel")
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

    var body: some View {
        Text(item.displayName)

        Button("Play", systemImage: "play.fill") {
            playChannel(item)
        }

        if item.url != nil {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star") {
                library.toggleFavorite(item)
            }
        }

        ForEach(extraActions) { action in
            Button(action.title, systemImage: action.systemImage, role: action.role, action: action.action)
        }
    }
}

/// Slight press feedback for cards.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// Logo of a live channel (fitted, centered) or poster of an on-demand item (filling the card).
/// Decoded at the displayed size by the shared logo loader.
struct ChannelArtwork: View {

    let logo: String?
    let name: String
    let kind: ChannelContentKind
    let size: CGSize

    var body: some View {
        let isPoster = kind.usesPosterArtwork
        let imageSize = isPoster ? size : CGSize(width: size.width * 0.5, height: size.height * 0.6)
        LogoImage(
            source: logo,
            size: imageSize,
            contentMode: isPoster ? .fill : .fit,
            accessibilityLabel: name
        ) { phase in
            switch phase {
            case .loading:
                ProgressView()
            case .unavailable:
                ArtworkPlaceholder(name: name, kind: kind)
                    .frame(width: imageSize.width, height: imageSize.height)
            }
        }
    }
}

/// Initials on a tinted background when a channel has no usable artwork.
struct ArtworkPlaceholder: View {
    let name: String
    let kind: ChannelContentKind

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: kind.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(initials)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary.opacity(0.7))
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "|" }).prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
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
