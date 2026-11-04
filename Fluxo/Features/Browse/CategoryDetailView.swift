//
//  CategoryDetailView.swift
//  Fluxo
//
//  One category (a playlist group) with everything needed to browse it quickly: a pinned bar of the sibling
//  categories to hop between them without going back, a list (channel numbers, logos, now / next) or a grid,
//  sorting (number, A–Z, recently added, most watched), search within the category, an A–Z quick scroller,
//  and the position remembered per category.
//

import SwiftData
import SwiftUI

/// How a category lists its channels.
enum CategoryLayout: String, CaseIterable, Sendable {
    case list
    case grid
}

/// The order and layout chosen for each content kind, kept in one `@AppStorage` string.
struct BrowsePreferences: RawRepresentable, Equatable {

    static let storageKey = "browse.preferences"

    private var orders: [ChannelContentKind: ChannelSortOrder] = [:]
    private var layouts: [ChannelContentKind: CategoryLayout] = [:]

    init() {}

    /// "o0=name;l1=grid": `o` an order, `l` a layout, then the kind's raw value.
    init?(rawValue: String) {
        for entry in rawValue.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let type = parts[0].first, let kind = Int(parts[0].dropFirst()).flatMap(ChannelContentKind.init(rawValue:)) else {
                continue
            }
            switch type {
            case "o":
                orders[kind] = ChannelSortOrder(rawValue: parts[1])
            case "l":
                layouts[kind] = CategoryLayout(rawValue: parts[1])
            default:
                break
            }
        }
    }

    var rawValue: String {
        let orderEntries = orders.sorted { $0.key.rawValue < $1.key.rawValue }.map { "o\($0.key.rawValue)=\($0.value.rawValue)" }
        let layoutEntries = layouts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "l\($0.key.rawValue)=\($0.value.rawValue)" }
        return (orderEntries + layoutEntries).joined(separator: ";")
    }

    func order(for kind: ChannelContentKind) -> ChannelSortOrder {
        orders[kind] ?? .playlist
    }

    /// Live channels are a list by default (numbers and the guide), movies and series a poster grid.
    func layout(for kind: ChannelContentKind) -> CategoryLayout {
        layouts[kind] ?? (kind == .live ? .list : .grid)
    }

    mutating func setOrder(_ order: ChannelSortOrder, for kind: ChannelContentKind) {
        orders[kind] = order
    }

    mutating func setLayout(_ layout: CategoryLayout, for kind: ChannelContentKind) {
        layouts[kind] = layout
    }
}

struct CategoryDetailView: View {

    let importID: UUID
    let groupName: String
    let title: String

    @Environment(\.modelContext) private var modelContext
    @Environment(ChannelLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(BrowsePreferences.storageKey) private var preferences = BrowsePreferences()

    /// The category shown; starts as the one of the route and changes with the chip bar.
    @State private var current: GroupItem?
    @State private var siblings: [GroupItem] = []
    @State private var model = CategoryChannelsModel()
    @State private var searchText = ""
    @State private var showsAllCategories = false
    /// Offsets of the rows on screen (not observed: updating it never re-renders the list).
    @State private var visibleRows = VisibleRows()

    var body: some View {
        let kind = current?.kind ?? .live
        let order = preferences.order(for: kind)
        let layout = preferences.layout(for: kind)
        let request = current.map {
            CategoryChannelsModel.Request(
                importID: $0.importID,
                playlistID: $0.playlistID,
                groupName: $0.name,
                order: order,
                term: searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        ScrollViewReader { proxy in
            Group {
                switch layout {
                case .list:
                    list(order: order)
                case .grid:
                    grid(kind: kind, order: order)
                }
            }
            .overlay(alignment: .trailing) {
                if showsLetterIndex {
                    AlphabetIndexBar(letters: model.letters.map(\.letter)) { letter in
                        jump(to: letter, proxy: proxy)
                    }
                    .padding(.trailing, 4)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay {
                if let request, model.isLoaded, model.items.isEmpty {
                    if request.term.isEmpty {
                        ContentUnavailableView("No Channels", systemImage: "tv.slash", description: Text("This category is empty."))
                    } else {
                        ContentUnavailableView.search(text: request.term)
                    }
                } else if !model.isLoaded {
                    ProgressView()
                }
            }
            .task(id: request) {
                guard let request else {
                    return
                }
                if !request.term.isEmpty {
                    // Debounce typing.
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        return
                    }
                }
                await model.load(request, container: modelContext.container)
                await restorePosition(for: request, proxy: proxy)
            }
        }
        .animation(.smooth, value: model.letters.isEmpty)
        .navigationTitle(current?.displayName ?? title)
        .inlineNavigationBar()
        .searchable(text: $searchText, prompt: Text("Search in \(current?.displayName ?? title)"))
        .safeAreaInset(edge: .top, spacing: 0) {
            if siblings.count > 1, let current {
                CategoryChipBar(groups: siblings, selectedID: current.id) { group in
                    switchTo(group)
                } onShowAll: {
                    showsAllCategories = true
                }
            }
        }
        .toolbar {
            ToolbarItem {
                optionsMenu(kind: kind, order: order, layout: layout)
            }
        }
        .navigationDestination(isPresented: $showsAllCategories) {
            if let current {
                CategoryBrowserView(importIDs: [current.importID], kind: current.kind)
            }
        }
        .task(id: importID) {
            await resolveCategory()
        }
        .onDisappear {
            savePosition()
        }
    }

    // MARK: - Layouts

    private func list(order: ChannelSortOrder) -> some View {
        List {
            if order == .mostWatched, !model.mostWatched.isEmpty {
                Section {
                    ForEach(model.mostWatched, id: \.mostWatchedRowID) { item in
                        ChannelListRow(item: item, showsNumber: false)
                    }
                } header: {
                    Label("Most Watched", systemImage: "flame.fill")
                        .foregroundStyle(Theme.pink)
                }
            }

            Section {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { offset, item in
                    ChannelListRow(item: item)
                        .onAppear {
                            rowAppeared(offset)
                        }
                        .onDisappear {
                            visibleRows.offsets.remove(offset)
                        }
                }
            } header: {
                if order == .mostWatched, !model.mostWatched.isEmpty {
                    Text("All Channels")
                }
            } footer: {
                footer
            }
        }
        .listStyle(.plain)
        .channelListRotors(model.items, library: library)
        // Room for the A–Z index along the trailing edge.
        .contentMargins(.trailing, showsLetterIndex ? 26 : 0, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
    }

    private var showsLetterIndex: Bool {
        guard let request = model.request else {
            return false
        }
        return request.order == .name && request.term.isEmpty && model.letters.count > 3
    }

    private func grid(kind: ChannelContentKind, order: ChannelSortOrder) -> some View {
        GeometryReader { geometry in
            let metrics = GridMetrics(width: geometry.size.width, usesPosters: kind.usesPosterArtwork, isLargeText: dynamicTypeSize.prefersStackedLayout)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if order == .mostWatched, !model.mostWatched.isEmpty {
                        HomeSectionHeader(title: String(localized: "Most Watched"), systemImage: "flame.fill")
                        CardRow {
                            ForEach(model.mostWatched, id: \.mostWatchedRowID) { item in
                                ChannelPreview(item: item, width: metrics.cardWidth)
                            }
                        }
                        HomeSectionHeader(title: String(localized: "All"))
                    }

                    LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: 18) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { offset, item in
                            ChannelPreview(item: item, width: metrics.cardWidth)
                                .onAppear {
                                    rowAppeared(offset)
                                }
                                .onDisappear {
                                    visibleRows.offsets.remove(offset)
                                }
                        }
                    }
                    .padding(.horizontal, HomeLayout.horizontalMargin)

                    footer
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 12)
            }
            .channelListRotors(model.items, library: library)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoaded, !model.reachedEnd {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        } else if let request = model.request, !request.term.isEmpty, model.items.count >= CategoryChannelsModel.searchLimit {
            Text("Showing the first \(CategoryChannelsModel.searchLimit) matches. Type more to narrow the search.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func optionsMenu(kind: ChannelContentKind, order: ChannelSortOrder, layout: CategoryLayout) -> some View {
        Menu {
            Picker("Sort By", selection: Binding(get: { order }, set: { preferences.setOrder($0, for: kind) })) {
                ForEach(ChannelSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage)
                        .tag(order)
                }
            }
            .pickerStyle(.inline)

            Picker("View As", selection: Binding(get: { layout }, set: { preferences.setLayout($0, for: kind) })) {
                Label("List", systemImage: "list.bullet")
                    .tag(CategoryLayout.list)
                Label("Grid", systemImage: "square.grid.2x2")
                    .tag(CategoryLayout.grid)
            }
            .pickerStyle(.inline)

            if siblings.count > 1 {
                Button("All Categories", systemImage: "square.grid.2x2") {
                    showsAllCategories = true
                }
            }
        } label: {
            Label("Sort and View", systemImage: "line.3.horizontal.decrease")
        }
        #if os(iOS)
        // Trying another order or layout keeps the menu open.
        .menuActionDismissBehavior(.disabled)
        #endif
    }

    // MARK: - Actions

    private func switchTo(_ group: GroupItem) {
        guard group.id != current?.id else {
            return
        }
        savePosition()
        searchText = ""
        visibleRows.offsets.removeAll()
        current = group
    }

    private func rowAppeared(_ offset: Int) {
        visibleRows.offsets.insert(offset)
        if offset >= model.items.count - 30 {
            Task {
                await model.loadMore(container: modelContext.container)
            }
        }
    }

    private func jump(to letter: String, proxy: ScrollViewProxy) {
        guard let offset = model.letters.first(where: { $0.letter == letter })?.offset else {
            return
        }
        Task {
            await model.ensureLoaded(offset: offset, container: modelContext.container)
            guard model.items.indices.contains(offset) else {
                return
            }
            proxy.scrollTo(model.items[offset].id, anchor: .top)
        }
    }

    private func savePosition() {
        guard let request = model.request, request.term.isEmpty, model.isLoaded else {
            return
        }
        CategoryPositionMemory.save(visibleRows.offsets.min() ?? 0, for: request)
    }

    private func restorePosition(for request: CategoryChannelsModel.Request, proxy: ScrollViewProxy) async {
        guard request.term.isEmpty, let offset = CategoryPositionMemory.offset(for: request), offset > 0 else {
            return
        }
        await model.ensureLoaded(offset: offset, container: modelContext.container)
        guard !Task.isCancelled, model.items.indices.contains(offset) else {
            return
        }
        // After the rows of the new page are laid out.
        await Task.yield()
        proxy.scrollTo(model.items[offset].id, anchor: .top)
    }

    /// Finds the group of the route and its sibling categories (same playlist and kind) off the main thread.
    private func resolveCategory() async {
        let container = modelContext.container
        let importID = importID
        let groupName = groupName
        let resolved: (GroupItem?, [GroupItem]) = await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<PlaylistChannelGroup>(predicate: #Predicate { $0.importID == importID && $0.name == groupName })
            descriptor.fetchLimit = 1
            guard let group = try? context.fetch(descriptor).first.map(GroupItem.init) else {
                return (nil, [])
            }
            let siblings = ((try? context.fetch(HomeQueries.groups(importIDs: [importID], kind: group.kind, limit: CategoryBrowserView.siblingLimit))) ?? [])
                .map(GroupItem.init)
            return (group, siblings)
        }.value
        guard !Task.isCancelled else {
            return
        }
        if current == nil {
            // A group that no longer exists (the playlist was refreshed) still lists what the route names.
            current = resolved.0 ?? GroupItem(importID: importID, playlistID: UUID(), name: groupName, channelCount: 0, kind: .live)
        }
        siblings = resolved.1
    }
}

/// Offsets of the rows on screen. A reference that SwiftUI does not observe, so rows scrolling in and out do
/// not re-render the screen.
private final class VisibleRows {
    var offsets: Set<Int> = []
}

/// Columns of the category grid: as many as fit, at least two on phones, cards stretched to fill the row.
struct GridMetrics {
    let columns: [GridItem]
    let cardWidth: CGFloat

    /// - Parameter isLargeText: the accessibility text sizes: wider cards (one live card per row on a phone), so
    ///   their titles and programmes stay readable.
    init(width: CGFloat, usesPosters: Bool, isLargeText: Bool = false) {
        let minimum: CGFloat = isLargeText ? (usesPosters ? 150 : 300) : (usesPosters ? 104 : 158)
        let spacing = HomeLayout.rowSpacing
        let available = max(minimum, width - HomeLayout.horizontalMargin * 2)
        let fewest = isLargeText ? (usesPosters ? 2 : 1) : (usesPosters ? 3 : 2)
        let count = max(fewest, Int((available + spacing) / (minimum + spacing)))
        let fitted = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        // Narrow phones: never narrower than what still shows a readable card.
        cardWidth = max(usesPosters ? 92 : 140, floor(fitted))
        let columnCount = max(1, Int((available + spacing) / (cardWidth + spacing)))
        columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .top), count: columnCount)
    }
}

private extension ChannelItem {
    /// Most Watched rows are listed again below: a distinct identity for the second copy.
    var mostWatchedRowID: String {
        "top|\(id.uuidString)"
    }
}

#Preview {
    NavigationStack {
        CategoryDetailView(importID: PreviewSampleData.freeviewImportID, groupName: "News", title: "News")
            .channelDestinations()
    }
    .fluxoPreviewEnvironment(GuidePreviewData.container)
}
