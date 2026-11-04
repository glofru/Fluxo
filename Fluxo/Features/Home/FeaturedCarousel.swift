//
//  FeaturedCarousel.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// Hero carousel at the top of Home: a handful of channels with artwork, rotating every day.
///
/// Two styles:
/// - `.billboard` (iOS): full-bleed pages that run under the status bar and the floating glass toolbar. The
///   blurred artwork uses `backgroundExtensionEffect()` so it also extends under the iPad sidebar and the
///   landscape safe areas, stretches when Home is pulled down, and fades into the screen background, so the
///   content below starts on a calm surface.
/// - `.cards` (macOS): rounded cards in a paged row, two side by side on wide windows.
///
/// The picks are fetched on a background context and kept as `ChannelItem` values, so the carousel holds no
/// models and its fetches never run on the main thread. Movie and series posters are preferred; playlists
/// without on-demand content feature live channels.
struct FeaturedCarousel: View {

    enum Style {
        case cards
        case billboard
    }

    nonisolated static let itemCount = 8
    static let cardHeight: CGFloat = 240
    /// Height of a billboard page below the top inset.
    static let billboardHeight: CGFloat = 380

    let importIDs: [UUID]
    var style: Style = .cards
    /// Billboard: height of the status bar and navigation bar the billboard runs under.
    var topInset: CGFloat = 0
    /// Billboard: set to whether the billboard shows (false while loading and when nothing has artwork).
    var isShowingBillboard: Binding<Bool>?

    @Environment(\.modelContext) private var modelContext
    @State private var items: [ChannelItem] = []
    @State private var currentID: UUID?
    /// Imports the current `items` were picked from; nil until the first load finishes.
    @State private var loadedImportIDs: [UUID]?
    /// Billboard: the side safe areas (a phone in landscape, the vertical bar of a foldable iPhone's cover
    /// display). The pages run under them, their content stays clear of them.
    @State private var sideInsets = SideInsets()

    private struct SideInsets: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

    var body: some View {
        // A container (not a Group) so `.task` runs even while there is nothing to show yet.
        VStack(spacing: 0) {
            switch style {
            case .cards:
                cards
            case .billboard:
                billboard
            }
        }
        .animation(.easeInOut(duration: 0.3), value: items.isEmpty)
        .task(id: importIDs) {
            let container = modelContext.container
            let picks = await Self.loadPicks(importIDs: importIDs, container: container)
            guard !Task.isCancelled else {
                return
            }
            items = picks
            currentID = picks.first?.id
            loadedImportIDs = importIDs
        }
        .onChange(of: items.isEmpty, initial: true) { _, isEmpty in
            isShowingBillboard?.wrappedValue = !isEmpty
        }
        .onGeometryChange(for: SideInsets.self) { proxy in
            SideInsets(leading: proxy.safeAreaInsets.leading, trailing: proxy.safeAreaInsets.trailing)
        } action: { insets in
            sideInsets = insets
        }
    }

    @ViewBuilder
    private var cards: some View {
        if loadedImportIDs == nil {
            // Placeholder of the same height while the first picks load, so the page does not jump.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.quaternary)
                .frame(height: Self.cardHeight)
                .padding(.horizontal, HomeLayout.horizontalMargin)
                .accessibilityHidden(true)
        } else if !items.isEmpty {
            VStack(spacing: 12) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: HomeLayout.rowSpacing) {
                        ForEach(items) { item in
                            FeaturedCard(item: item)
                                .containerRelativeFrame(.horizontal) { length, _ in
                                    // Two cards side by side on wide windows, one on phones.
                                    length > 760 ? (length - HomeLayout.rowSpacing) / 2 : length
                                }
                                .scrollTransition(axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity ? 1 : 0.94)
                                        .opacity(phase.isIdentity ? 1 : 0.7)
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, HomeLayout.horizontalMargin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $currentID)
                .scrollIndicators(.hidden)

                PageIndicator(ids: items.map(\.id), currentID: $currentID)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var billboard: some View {
        if loadedImportIDs == nil {
            // Same height as the billboard while the picks load, so the page does not jump.
            BillboardBackdrop(item: nil)
                .frame(height: topInset + Self.billboardHeight)
                .accessibilityHidden(true)
        } else if items.isEmpty {
            // Nothing to feature: keep the content clear of the toolbar.
            Color.clear
                .frame(height: topInset)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        BillboardPage(item: item, topInset: topInset, leadingInset: sideInsets.leading, trailingInset: sideInsets.trailing)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            // Pages as wide as the screen: inside the side safe areas the next page would show under them.
            .ignoresSafeArea(.container, edges: .horizontal)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .frame(height: topInset + Self.billboardHeight)
            // One backdrop for every page, behind the pager rather than inside it: the pager clips its pages,
            // and the backdrop has to grow above the billboard when Home is pulled down. It cross-fades to the
            // artwork of the page that settles.
            .background {
                let current = items.first { $0.id == currentID } ?? items[0]
                ZStack {
                    BillboardBackdrop(item: current)
                        .id(current.id)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.45), value: current.id)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                PageIndicator(ids: items.map(\.id), currentID: $currentID)
                    .padding(.bottom, 4)
            }
            .transition(.opacity)
        }
    }

    /// Picks `itemCount` consecutive channels with artwork starting at an offset that changes every day.
    private static func loadPicks(importIDs: [UUID], container: ModelContainer) async -> [ChannelItem] {
        guard !importIDs.isEmpty else {
            return []
        }
        return await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            do {
                var descriptor = HomeQueries.featured(importIDs: importIDs, onDemand: true)
                var count = try context.fetchCount(descriptor)
                if count < 3 {
                    descriptor = HomeQueries.featured(importIDs: importIDs, onDemand: false)
                    count = try context.fetchCount(descriptor)
                }
                guard count > 0 else {
                    return []
                }
                let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
                let windows = max(1, count - Self.itemCount + 1)
                descriptor.fetchOffset = (day &* 7_919) % windows
                descriptor.fetchLimit = Self.itemCount
                return try context.fetch(descriptor).map(ChannelItem.init)
            } catch {
                return []
            }
        }.value
    }
}

/// One full-bleed billboard page: the artwork, the title and glass actions (the blurred backdrop is shared by
/// the pages, see `FeaturedCarousel.billboard`).
private struct BillboardPage: View {

    static let posterSize = CGSize(width: 112, height: 166)
    static let logoSize = CGSize(width: 132, height: 92)

    let item: ChannelItem
    let topInset: CGFloat
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    @Environment(\.playChannel) private var playChannel
    @Environment(ChannelLibrary.self) private var library
    /// The player zooms out of this page's artwork.
    @State private var sourceID = UUID().uuidString

    var body: some View {
        let isFavorite = library.isFavorite(item)
        ZStack(alignment: .bottomLeading) {
            Color.clear

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: 16) {
                    artwork
                        .playerTransitionSource(id: sourceID)
                        .contextMenu {
                            ChannelContextMenu(item: item, isFavorite: isFavorite)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(kindLabel)
                            .font(.caption.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(.tint)
                        Text(item.displayName)
                            .font(Theme.Typography.heroTitle)
                            .lineLimit(3)
                            .minimumScaleFactor(0.85)
                        if !item.groupName.isEmpty {
                            Text(item.groupName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                // Glass belongs to the controls, not to the artwork.
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            playChannel(item, from: sourceID)
                        } label: {
                            Label(item.kind == .live ? "Watch Live" : "Play", systemImage: "play.fill")
                                .font(.headline)
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.glassProminent)

                        if item.url != nil {
                            Button {
                                library.toggleFavorite(item)
                            } label: {
                                Image(systemName: isFavorite ? "star.fill" : "star")
                                    .font(.headline)
                                    .foregroundStyle(isFavorite ? Theme.favorite : Color.primary)
                                    .contentTransition(.symbolEffect(.replace))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                        }
                    }
                }
                .controlSize(.large)
            }
            .padding(.leading, HomeLayout.horizontalMargin + leadingInset)
            .padding(.trailing, HomeLayout.horizontalMargin + trailingInset)
            .padding(.bottom, 30)
        }
        .frame(height: topInset + FeaturedCarousel.billboardHeight)
        .contentShape(.rect)
        .onTapGesture {
            playChannel(item, from: sourceID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: item.kind == .live ? "Watch Live" : "Play") {
            playChannel(item, from: sourceID)
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .live:
            return "Live Now"
        case .movie:
            return "Featured Movie"
        case .series:
            return "Featured Series"
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let isPoster = item.kind.usesPosterArtwork
        let size = isPoster ? Self.posterSize : Self.logoSize
        LogoImage(source: item.logo, size: isPoster ? size : CGSize(width: size.width - 20, height: size.height - 20), contentMode: isPoster ? .fill : .fit, accessibilityLabel: item.displayName) { phase in
            if phase == .unavailable {
                ArtworkPlaceholder(name: item.displayName, kind: item.kind)
                    .frame(width: size.width, height: size.height)
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.thinMaterial)
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }
}

/// Blurred, tiny-decoded artwork on the brand gradient, faded into the screen background at the bottom (and
/// slightly at the top, so the status bar and the toolbar stay legible in light and dark mode).
///
/// When Home is pulled down (pull to refresh), the backdrop stretches upward from its bottom edge so it always
/// fills the gap above the content: the top of the screen shows the blurred cover, never an empty background.
private struct BillboardBackdrop: View {

    /// Decoded tiny and blurred: a few kilobytes instead of a full-size bitmap.
    static let decodeSize = CGSize(width: 24, height: 24)

    let item: ChannelItem?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            artwork
                .clipped()
                .backgroundExtensionEffect()

            LinearGradient(
                stops: [
                    .init(color: Color.appBackground.opacity(reduceTransparency ? 0.7 : 0.45), location: 0),
                    .init(color: Color.appBackground.opacity(0), location: 0.25),
                    .init(color: Color.appBackground.opacity(0), location: 0.4),
                    .init(color: Color.appBackground.opacity(reduceTransparency ? 0.95 : 0.8), location: 0.72),
                    .init(color: Color.appBackground, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // Over the extended artwork too (side safe areas, the vertical bar of a foldable's cover display):
            // otherwise it shows there unfaded, with a hard edge.
            .ignoresSafeArea(.container, edges: .horizontal)
            .allowsHitTesting(false)
        }
        .visualEffect { content, proxy in
            // How far the top of the billboard has been pulled below the top of the scroll view.
            let overscroll = max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY)
            let height = max(1, proxy.size.height)
            return content.scaleEffect(x: 1 + overscroll / height * 0.35, y: 1 + overscroll / height, anchor: .bottom)
        }
    }

    private var artwork: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.brandGradient

                if let item {
                    LogoImage(source: item.logo, size: Self.decodeSize, contentMode: .fill) { _ in
                        Color.clear
                    }
                    .scaleEffect(max(proxy.size.width, proxy.size.height) / Self.decodeSize.width * 1.3)
                    .blur(radius: 28)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .opacity(0.95)
                }
            }
        }
    }
}

/// One hero card: blurred artwork backdrop, the artwork itself and a Play call to action on glass.
private struct FeaturedCard: View {

    static let posterSize = CGSize(width: 120, height: 178)
    static let logoSize = CGSize(width: 140, height: 100)
    /// The backdrop is decoded tiny and blurred: it costs a few kilobytes instead of a full-size bitmap.
    static let backdropSize = CGSize(width: 24, height: 24)

    let item: ChannelItem

    @Environment(\.playChannel) private var playChannel
    @Environment(ChannelLibrary.self) private var library

    @State private var sourceID = UUID().uuidString

    private let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        let isFavorite = library.isFavorite(item)
        Button {
            playChannel(item, from: sourceID)
        } label: {
            HStack(alignment: .bottom, spacing: 18) {
                artwork

                VStack(alignment: .leading, spacing: 8) {
                    Label(item.kind == .live ? "Live Now" : "Featured \(item.kind == .movie ? "Movie" : "Series")", systemImage: item.kind.systemImage)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)

                    Text(item.displayName)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    if !item.groupName.isEmpty {
                        Text(item.groupName)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }

                    Label(item.kind == .live ? "Watch Live" : "Play", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                        .padding(.top, 4)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: FeaturedCarousel.cardHeight, maxHeight: FeaturedCarousel.cardHeight, alignment: .bottomLeading)
            .background {
                backdrop
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.12))
            }
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Theme.favorite)
                        .padding(8)
                        .glassEffect(.regular, in: .circle)
                        .padding(14)
                        .accessibilityLabel("Favorite")
                }
            }
            .contentShape(shape)
            .playerTransitionSource(id: sourceID, cornerRadius: 28)
        }
        .buttonStyle(CardButtonStyle())
        .contextMenu {
            ChannelContextMenu(item: item, isFavorite: isFavorite)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let isPoster = item.kind.usesPosterArtwork
        let size = isPoster ? Self.posterSize : Self.logoSize
        LogoImage(source: item.logo, size: size, contentMode: isPoster ? .fill : .fit, accessibilityLabel: item.displayName) { phase in
            if phase == .unavailable {
                ArtworkPlaceholder(name: item.displayName, kind: item.kind)
            } else {
                Color.clear
            }
        }
        .padding(isPoster ? 0 : 10)
        .background(isPoster ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.ultraThinMaterial), in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    private var backdrop: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.brandGradient

                LogoImage(source: item.logo, size: Self.backdropSize, contentMode: .fill) { _ in
                    Color.clear
                }
                .scaleEffect(max(proxy.size.width, proxy.size.height) / Self.backdropSize.width * 1.3)
                .blur(radius: 24)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .opacity(0.9)

                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Dots under the carousel; tapping one scrolls to its card.
private struct PageIndicator: View {
    let ids: [UUID]
    @Binding var currentID: UUID?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ids, id: \.self) { id in
                Capsule()
                    .fill(id == currentID ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: id == currentID ? 18 : 6, height: 6)
                    .onTapGesture {
                        withAnimation(.snappy) {
                            currentID = id
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .animation(.snappy, value: currentID)
    }
}

#Preview {
    ScrollView {
        FeaturedCarousel(importIDs: PreviewSampleData.importIDs)
    }
    .fluxoPreviewEnvironment()
}
