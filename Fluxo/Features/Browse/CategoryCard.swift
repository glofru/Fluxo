//
//  CategoryCard.swift
//  Fluxo
//
//  Cards of the categories (playlist groups): an artwork mosaic of the first channels of the group on a tint
//  derived from its name, the name and the number of channels. Used by the Home category strip, the category
//  browser and search.
//

import SwiftData
import SwiftUI

/// A category card that opens the category. The mosaic fetches only the first `mosaicCount` channels that
/// have artwork (an indexed query with a small limit), when the card scrolls in.
struct CategoryCard: View {

    enum Size {
        /// The Home strip and search.
        case regular
        /// The category browser grid.
        case large

        var width: CGFloat {
            switch self {
            case .regular:
                return 168
            case .large:
                return 176
            }
        }

        var mosaicHeight: CGFloat {
            switch self {
            case .regular:
                return 104
            case .large:
                return 116
            }
        }
    }

    let group: GroupItem
    var size: Size = .regular
    /// Shown under the count (the playlist, when several are listed together).
    var playlistName: String?
    /// Fills the grid column instead of a fixed width (category browser).
    var fillsWidth = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Strip cards grow a little with the text size, and their names wrap.
    private var scale = CardScale(maximum: 1.3)

    /// Corner radius of the mosaic, the shape the category's screen zooms out of.
    static let cornerRadius: CGFloat = 20

    private let shape = RoundedRectangle(cornerRadius: CategoryCard.cornerRadius, style: .continuous)

    var body: some View {
        let width = scale.scaled(size.width)
        NavigationLink(value: group.route) {
            VStack(alignment: .leading, spacing: 8) {
                CategoryMosaic(group: group, height: size.mosaicHeight)
                    .frame(maxWidth: fillsWidth ? .infinity : width)
                    .frame(height: size.mosaicHeight)
                    // The logo tiles inside follow its corners (concentric).
                    .containerShape(shape)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(Theme.surfaceStroke)
                    }
                    // The category zooms out of the mosaic only: a rounded clip of the whole card would cut
                    // the corners of the name and the count under it.
                    .routeTransitionSource(group.route, cornerRadius: CategoryCard.cornerRadius)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(CardTextMetrics.titleLineLimit(1, at: dynamicTypeSize))
                    Text(countText)
                        .font(Theme.Typography.cardSubtitle)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(CardTextMetrics.titleLineLimit(1, at: dynamicTypeSize))
                }
                .padding(.horizontal, 2)
            }
            .frame(width: fillsWidth ? nil : width, alignment: .leading)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(CardButtonStyle())
        .cardHoverEffect()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityInputLabels([Text(group.displayName)])
        .help(group.displayName)
    }

    private var countText: String {
        TextParts.line([Self.countText(group), playlistName])
    }

    /// "128 channels", "42 movies", "3 series · 30 episodes" (or "16 episodes" when the episodes are not grouped).
    static func countText(_ group: GroupItem) -> String {
        switch group.kind {
        case .live:
            return String(localized: "\(group.channelCount) channels")
        case .movie:
            return String(localized: "\(group.channelCount) movies")
        case .series:
            let episodes = String(localized: "\(group.channelCount) episodes")
            guard group.seriesCount > 0 else {
                return episodes
            }
            return TextParts.line([String(localized: "\(group.seriesCount) series", comment: "Number of series in a category (a category card)."), episodes])
        }
    }

    private var accessibilityLabel: String {
        TextParts.spoken([group.displayName, Self.countText(group), playlistName])
    }
}

/// Up to four channel logos in a 2 × 2 grid, or three posters side by side, on a gradient tinted from the
/// group's name. A group without artwork shows its initials and the symbol of its kind.
struct CategoryMosaic: View {

    static let mosaicCount = 4

    let group: GroupItem
    let height: CGFloat

    @Query private var channels: [PlaylistChannel]

    init(group: GroupItem, height: CGFloat) {
        self.group = group
        self.height = height
        _channels = Query(HomeQueries.groupArtwork(importID: group.importID, groupName: group.name, limit: Self.mosaicCount))
    }

    var body: some View {
        let hue = ArtworkPlaceholder.hue(for: group.displayName)
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.5, brightness: 0.55),
                        Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.28),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if channels.isEmpty {
                    emptyMosaic
                } else if group.kind.usesPosterArtwork {
                    posters(in: proxy.size)
                } else {
                    logos(in: proxy.size)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var emptyMosaic: some View {
        VStack(spacing: 4) {
            Image(systemName: group.kind.systemImage)
                .font(.title2.weight(.semibold))
            Text(group.displayName)
                .font(.caption.weight(.heavy))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    /// Logos on light tiles, so dark logos stay readable on the tint. Each tile's outer corner is concentric
    /// with the card's (its radius less the padding), the inner ones keep a small fixed radius.
    private func logos(in size: CGSize) -> some View {
        let spacing: CGFloat = 6
        let padding: CGFloat = 8
        let tileSize = CGSize(width: (size.width - padding * 2 - spacing) / 2, height: (size.height - padding * 2 - spacing) / 2)
        let rows = [Array(channels.prefix(2)), Array(channels.dropFirst(2).prefix(2))].filter { !$0.isEmpty }
        return VStack(spacing: spacing) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(rows[row]) { channel in
                        LogoImage(source: channel.logo, size: CGSize(width: tileSize.width * 0.8, height: tileSize.height * 0.72)) { _ in
                            Color.clear
                        }
                        .frame(width: tileSize.width, height: tileSize.height)
                        .background(.white.opacity(0.82), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(9))))
                    }
                }
            }
        }
        .padding(padding)
        .frame(width: size.width, height: size.height, alignment: rows.count == 1 ? .center : .top)
    }

    /// Three posters fanned out from the centre.
    private func posters(in size: CGSize) -> some View {
        let posterHeight = size.height - 14
        let posterSize = CGSize(width: posterHeight * 2 / 3, height: posterHeight)
        let shown = Array(channels.prefix(3))
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.persistentModelID) { index, channel in
                let offset = CGFloat(index) - CGFloat(shown.count - 1) / 2
                LogoImage(source: channel.logo, size: posterSize, contentMode: .fill) { _ in
                    Color.white.opacity(0.15)
                }
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                .rotationEffect(.degrees(Double(offset) * 7), anchor: .bottom)
                .offset(x: offset * posterSize.width * 0.62, y: abs(offset) * 6)
                .zIndex(-abs(Double(offset)))
            }
        }
        .frame(width: size.width, height: size.height)
        .offset(y: 4)
    }
}

/// A pinned bar of category chips: the current one is highlighted and kept in view, a tap switches to another.
struct CategoryChipBar: View {

    let groups: [GroupItem]
    let selectedID: GroupItem.ID
    let onSelect: (GroupItem) -> Void
    /// Opens every category of the kind.
    var onShowAll: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if let onShowAll {
                            Button(action: onShowAll) {
                                Image(systemName: "square.grid.2x2")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(width: 20, height: 20)
                                    .padding(8)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .accessibilityLabel("All Categories")
                        }

                        ForEach(groups) { group in
                            chip(group)
                                .id(group.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .contentMargins(.horizontal, HomeLayout.horizontalMargin, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onAppear {
                proxy.scrollTo(selectedID, anchor: .center)
            }
            .onChange(of: selectedID) { _, id in
                withAnimation(reduceMotion ? nil : .smooth) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedID)
    }

    private func chip(_ group: GroupItem) -> some View {
        let isSelected = group.id == selectedID
        return Button {
            onSelect(group)
        } label: {
            HStack(spacing: 6) {
                SelectionCheckmark(isSelected: isSelected)
                Text(group.displayName)
                    .lineLimit(1)
                Text(group.itemCount, format: .number)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(Theme.secondaryText))
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(Theme.accentFill).interactive() : .regular.interactive(), in: .capsule)
        .glassEffectID(isSelected ? "category.selection" : group.id, in: glassNamespace)
        .accessibilityLabel(Text("\(group.displayName), \(CategoryCard.countText(group))"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Category cards") {
    NavigationStack {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                CategoryCard(group: PreviewSampleData.firstGroup())
                CategoryCard(group: PreviewSampleData.firstGroup(), size: .large, playlistName: "Freeview")
            }
            .padding()
        }
        .channelDestinations()
    }
    .fluxoPreviewEnvironment()
}
