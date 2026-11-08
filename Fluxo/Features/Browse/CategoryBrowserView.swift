//
//  CategoryBrowserView.swift
//  Fluxo
//

import SwiftData
import SwiftUI

/// Every category of one kind (Live TV, Movies or Series) as a grid of cards with artwork mosaics and counts,
/// with a search over the category names and three orders. Fetched a page at a time as the grid scrolls.
struct CategoryBrowserView: View {

    static let pageSize = 60
    /// Sibling categories of the chip bar in `CategoryDetailView`.
    nonisolated static let siblingLimit = 1_000

    let importIDs: [UUID]
    let kind: ChannelContentKind
    /// Names of the playlists, when categories of several are listed together.
    var playlistNames: [UUID: String] = [:]

    @AppStorage("browse.categoryOrder") private var order = GroupSortOrder.playlist
    @State private var searchText = ""
    @State private var limit = CategoryBrowserView.pageSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The cards' own growth with the text size (`CategoryCard`).
    private var scale = CardScale(maximum: 1.3)

    var body: some View {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        GeometryReader { geometry in
            let isLargeText = dynamicTypeSize.prefersStackedLayout
            let columns = Self.columns(
                width: geometry.size.width,
                cardWidth: isLargeText ? max(Self.largeTextColumnWidth, scale.scaled(CategoryCard.Size.large.width)) : scale.scaled(CategoryCard.Size.large.width),
                minimumCount: isLargeText ? 1 : 2
            )
            ScrollView {
                CategoryBrowserPage(importIDs: importIDs, kind: kind, order: order, term: term, limit: limit, columns: columns, playlistNames: playlistNames) {
                    limit += Self.pageSize
                }
                .padding(.horizontal, HomeLayout.horizontalMargin)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .navigationTitle(title)
        .largeTitleAdaptingToTextSize()
        .searchable(text: $searchText, prompt: Text("Search categories"))
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $order) {
                        ForEach(GroupSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage)
                                .tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort By", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .onChange(of: term) {
            limit = Self.pageSize
        }
        .onChange(of: order) {
            limit = Self.pageSize
        }
    }

    private var title: String {
        switch kind {
        case .live:
            return String(localized: "Live TV Categories")
        case .movie:
            return String(localized: "Movie Categories")
        case .series:
            return String(localized: "Series Categories")
        }
    }

    /// The narrowest column at the accessibility text sizes: room for a name of one long word ("Intrattenimento",
    /// "Deutschland") on a line.
    private static let largeTextColumnWidth: CGFloat = 380

    /// Two columns on phones, more as the width allows. At the accessibility text sizes, as many columns of
    /// `largeTextColumnWidth` as fit, down to one: in half a phone's width (or a quarter of an iPad's) a name of one
    /// long word was split ("Test Stream" then "s", "Intratten-imento").
    private static func columns(width: CGFloat, cardWidth: CGFloat, minimumCount: Int) -> [GridItem] {
        let spacing = HomeLayout.rowSpacing
        let available = width - HomeLayout.horizontalMargin * 2
        let count = max(minimumCount, Int((available + spacing) / (cardWidth + spacing)))
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
    }
}

private struct CategoryBrowserPage: View {

    @Query private var groups: [PlaylistChannelGroup]

    private let limit: Int
    private let columns: [GridItem]
    private let playlistNames: [UUID: String]
    private let term: String
    private let onReachEnd: () -> Void

    init(importIDs: [UUID], kind: ChannelContentKind, order: GroupSortOrder, term: String, limit: Int, columns: [GridItem], playlistNames: [UUID: String], onReachEnd: @escaping () -> Void) {
        self.limit = limit
        self.columns = columns
        self.playlistNames = playlistNames
        self.term = term
        self.onReachEnd = onReachEnd
        _groups = Query(HomeQueries.groups(importIDs: importIDs, kind: kind, order: order, matching: term, limit: limit))
    }

    var body: some View {
        if groups.isEmpty, !term.isEmpty {
            ContentUnavailableView.search(text: term)
                .padding(.top, 40)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(groups) { group in
                    let item = GroupItem(group)
                    CategoryCard(group: item, size: .large, playlistName: playlistNames.count > 1 ? playlistNames[item.playlistID] : nil, fillsWidth: true)
                        .onAppear {
                            if groups.count >= limit, group.persistentModelID == groups.last?.persistentModelID {
                                onReachEnd()
                            }
                        }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        CategoryBrowserView(importIDs: PreviewSampleData.importIDs, kind: .live)
            .channelDestinations()
    }
    .fluxoPreviewEnvironment()
}
