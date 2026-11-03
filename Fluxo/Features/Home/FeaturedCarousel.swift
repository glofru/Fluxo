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
/// The picks are fetched on a background context and kept as `ChannelItem` values, so the carousel holds no
/// models and its fetches never run on the main thread. Movie and series posters are preferred; playlists
/// without on-demand content feature live channels.
struct FeaturedCarousel: View {

    nonisolated static let itemCount = 8
    static let cardHeight: CGFloat = 240

    let importIDs: [UUID]

    @Environment(\.modelContext) private var modelContext
    @State private var items: [ChannelItem] = []
    @State private var currentID: UUID?
    /// Imports the current `items` were picked from; nil until the first load finishes.
    @State private var loadedImportIDs: [UUID]?

    var body: some View {
        // A container (not a Group) so `.task` runs even while there is nothing to show yet.
        VStack(spacing: 0) {
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

/// One hero card: blurred artwork backdrop, the artwork itself and a Play call to action on glass.
private struct FeaturedCard: View {

    static let posterSize = CGSize(width: 120, height: 178)
    static let logoSize = CGSize(width: 140, height: 100)
    /// The backdrop is decoded tiny and blurred: it costs a few kilobytes instead of a full-size bitmap.
    static let backdropSize = CGSize(width: 24, height: 24)

    let item: ChannelItem

    @Environment(\.playChannel) private var playChannel
    @Environment(ChannelLibrary.self) private var library

    private let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        let isFavorite = library.isFavorite(item)
        Button {
            playChannel(item)
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
                        .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
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
                        .foregroundStyle(.yellow)
                        .padding(8)
                        .glassEffect(.regular, in: .circle)
                        .padding(14)
                        .accessibilityLabel("Favorite")
                }
            }
            .contentShape(shape)
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
        LogoImage(source: item.logo, size: size, contentMode: isPoster ? .fill : .fit, accessibilityLabel: item.displayName) { _ in
            ArtworkPlaceholder(name: item.displayName, kind: item.kind)
        }
        .padding(isPoster ? 0 : 10)
        .background(isPoster ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.ultraThinMaterial), in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    private var backdrop: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [.accentColor.opacity(0.9), .indigo.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)

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
