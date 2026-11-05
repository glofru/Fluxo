//
//  TVComponents.swift
//  Fluxo
//
//  Building blocks of the Apple TV pages: a focusable channel card and a shelf of them. Cards use the system's card
//  button style (they lift and tilt under focus, like the tiles of the TV app), shelves are focus sections, so a
//  swipe up or down on the Siri Remote moves to the shelf above or below wherever the focus is in the row.
//

#if os(tvOS)
import SwiftUI

/// Sizes of the 10-foot layout (points of the 1920 × 1080 tvOS canvas).
enum TVLayout {
    /// A channel card: 16:9 artwork.
    static let cardSize = CGSize(width: 352, height: 198)
    /// The logo inside a card, inset from its edges.
    static let logoSize = CGSize(width: 240, height: 128)
    /// Between two cards of a shelf.
    static let cardSpacing: CGFloat = 48
    /// Between two shelves.
    static let shelfSpacing: CGFloat = 56
}

enum TVText {
    /// The VoiceOver hint of what selecting plays (cards, rows).
    static let playsHint = LocalizedStringResource("Plays", comment: "VoiceOver hint of a channel, movie, episode or recording on Apple TV: selecting it starts playback.")
}

/// A channel, movie or episode. Selecting it plays it.
struct TVChannelCard: View {
    let item: ChannelItem

    @Environment(\.playChannel) private var playChannel
    #if DEBUG
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @FocusState private var isDebugFocused: Bool
    #endif

    var body: some View {
        Button {
            playChannel(item)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                TVChannelArtwork(item: item)
                    .frame(width: TVLayout.cardSize.width, height: TVLayout.cardSize.height)
                Text(item.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: TVLayout.cardSize.width - 32, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
        .buttonStyle(.card)
        .accessibilityLabel(Text(TextParts.line([item.displayName, item.groupName])))
        .accessibilityHint(Text(TVText.playsHint))
        #if DEBUG
        // The harness's `focus:<channel>` route.
        .focused($isDebugFocused)
        .onChange(of: navigation?.debugFocusName, initial: true) { _, name in
            if let name, item.displayName.caseInsensitiveCompare(name) == .orderedSame {
                isDebugFocused = true
            }
        }
        #endif
    }
}

/// The logo (channels) or poster (movies, episodes) of an entry, or its placeholder.
struct TVChannelArtwork: View {
    let item: ChannelItem

    var body: some View {
        ZStack {
            Theme.tileBackground
            if item.logo != nil {
                LogoImage(source: item.logo, size: item.kind == .live ? TVLayout.logoSize : TVLayout.cardSize, contentMode: item.kind == .live ? .fit : .fill) { phase in
                    if phase == .unavailable {
                        ArtworkPlaceholder(name: item.displayName, kind: item.kind)
                    } else {
                        Color.clear
                    }
                }
            } else {
                ArtworkPlaceholder(name: item.displayName, kind: item.kind)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A titled row of cards that scrolls sideways. Nothing shows while it is empty.
struct TVShelf<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: TVLayout.cardSpacing) {
                        ForEach(items) { item in
                            card(item)
                        }
                    }
                    // Room for the focused card, which grows past its frame.
                    .padding(.vertical, 32)
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
            }
            .focusSection()
        }
    }
}

extension TVShelf where Item == ChannelItem, Card == TVChannelCard {
    init(title: String, items: [ChannelItem]) {
        self.init(title: title, items: items) { item in
            TVChannelCard(item: item)
        }
    }
}

/// A page with nothing to show yet: a symbol, a title and what to do.
struct TVEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, minHeight: 600)
    }
}
#endif
