//
//  FeaturedCarousel.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// Hero carousel at the top of Home: a handful of different movies, series and channels with artwork, chosen
/// again every few hours, every day and on pull to refresh (`FeaturedPicker`, `FeaturedRotation`).
///
/// Two styles:
/// - `.billboard` (iOS): full-bleed pages that run under the status bar and the floating glass toolbar. The
///   blurred artwork uses `backgroundExtensionEffect()` so it also extends under the iPad sidebar and the
///   landscape safe areas, stretches when Home is pulled down, and fades into the screen background, so the
///   content below starts on a calm surface.
/// - `.cards` (macOS): rounded cards in a paged row, two side by side on wide windows.
///
/// The picks are fetched on a background context and kept as `ChannelItem` values, so the carousel holds no
/// models and its fetches never run on the main thread (`FeaturedLoader`).
struct FeaturedCarousel: View {

    enum Style {
        case cards
        case billboard
    }

    static let cardHeight: CGFloat = 240
    /// Height of a billboard page below the top inset.
    static let billboardHeight: CGFloat = 380

    /// The billboard grows at the accessibility text sizes, where its title and buttons take more room.
    static func billboardHeight(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .accessibility1, .accessibility2:
            return 540
        case .accessibility3, .accessibility4, .accessibility5:
            return 660
        default:
            return billboardHeight
        }
    }

    let importIDs: [UUID]
    var style: Style = .cards
    /// Billboard: height of the status bar and navigation bar the billboard runs under.
    var topInset: CGFloat = 0
    /// Billboard: set to whether the billboard shows (false while loading and when nothing has artwork).
    var isShowingBillboard: Binding<Bool>?
    /// Billboard: set to the height of its pages below the top inset, as laid out.
    var billboardHeight: Binding<CGFloat>?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Series grouped at launch in a library imported before series existed: the picks are made again.
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MatureContent.hidesAdultContentKey) private var hidesAdultContent = MatureContent.hidesAdultContentByDefault
    /// The picks of the day, as loaded; `items` are those shown.
    @State private var picks: [ChannelItem] = []
    @State private var currentID: UUID?
    /// Imports the current `items` were picked from; nil until the first load finishes.
    @State private var loadedImportIDs: [UUID]?
    /// Billboard: the side safe areas (a phone in landscape, the vertical bar of a foldable iPhone's cover
    /// display). The pages run under them, their content stays clear of them.
    @State private var sideInsets = SideInsets()
    /// Billboard: the natural height of each page's content (`BillboardPage.onContentHeight`).
    @State private var contentHeights: [UUID: CGFloat] = [:]

    private struct LoadKey: Hashable {
        let importIDs: [UUID]
        let seriesRevision: Int
        let seed: UInt64
        let hidesAdultContent: Bool
    }

    private struct SideInsets: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

    /// The picks shown: offline, only those that play without a network (downloaded, or a series with downloaded
    /// episodes), so the top of Home never promotes something that cannot play.
    private var items: [ChannelItem] {
        guard NetworkMonitor.shared.isOffline else {
            return picks
        }
        guard let downloads else {
            return []
        }
        return picks.filter { item in
            if let record = downloads.record(for: item), record.status == .completed, !record.isMissing {
                return true
            }
            guard let series = item.series else {
                return false
            }
            return downloads.records(ofSeries: item.playlistID, key: series.seriesKey).contains { $0.status == .completed && !$0.isMissing }
        }
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
        .task(id: LoadKey(importIDs: importIDs, seriesRevision: importCenter.seriesIndexRevision, seed: FeaturedRotation.shared.currentSeed, hidesAdultContent: hidesAdultContent)) {
            let container = modelContext.container
            let picks = await Self.loadPicks(importIDs: importIDs, container: container)
            guard !Task.isCancelled else {
                return
            }
            self.picks = picks
            currentID = picks.first?.id
            loadedImportIDs = importIDs
            // Only the new picks' heights size the billboard: the others are forgotten.
            let ids = Set(picks.map(\.id))
            contentHeights = contentHeights.filter { ids.contains($0.key) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Other pages when the app comes back after a while (never while it stays on screen).
            if phase == .active {
                FeaturedRotation.shared.refreshIfDue()
            }
        }
        .onChange(of: items.isEmpty, initial: true) { _, isEmpty in
            isShowingBillboard?.wrappedValue = !isEmpty
        }
        .onChange(of: pageHeight, initial: true) { _, height in
            billboardHeight?.wrappedValue = height
        }
        .onChange(of: items.map(\.id)) { _, ids in
            // Offline (or back online) the shown pages change: the current one stays if it is still shown.
            if let currentID, ids.contains(currentID) {
                return
            }
            currentID = ids.first
        }
        .onGeometryChange(for: SideInsets.self) { proxy in
            SideInsets(leading: proxy.safeAreaInsets.leading, trailing: proxy.safeAreaInsets.trailing)
        } action: { insets in
            sideInsets = insets
        }
        #if DEBUG
        // Debug harness (`featured-page:<n>`): pages as a swipe does.
        .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugFeaturedPage)) { notification in
            guard let index = notification.object as? Int, items.indices.contains(index) else {
                return
            }
            withAnimation {
                currentID = items[index].id
            }
        }
        #endif
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
                .frame(height: topInset + Self.billboardHeight(for: dynamicTypeSize))
                .accessibilityHidden(true)
        } else if items.isEmpty {
            // Nothing to feature: keep the content clear of the toolbar.
            Color.clear
                .frame(height: topInset)
        } else {
            let height = pageHeight
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    if dynamicTypeSize.prefersStackedLayout {
                        // Every page is built at once at the accessibility text sizes, so the tallest one is measured
                        // before it scrolls in and the billboard never changes height while paging.
                        HStack(spacing: 0) {
                            pages(height: height)
                        }
                        .scrollTargetLayout()
                    } else {
                        LazyHStack(spacing: 0) {
                            pages(height: height)
                        }
                        .scrollTargetLayout()
                    }
                }
                // Pages as wide as the screen: inside the side safe areas the next page would show under them.
                .ignoresSafeArea(.container, edges: .horizontal)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
                .scrollIndicators(.hidden)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.width
                } action: { _ in
                    // The pages are as wide as the pager: when it changes width (rotation, an iPad window resized),
                    // the page shown is laid out again in full. A non-lazy stack keeps its scroll offset instead,
                    // which in a right-to-left layout leaves the pager between two pages.
                    guard let currentID else {
                        return
                    }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(currentID)
                    }
                }
            }
            .frame(height: topInset + height)
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

    private func pages(height: CGFloat) -> some View {
        ForEach(items) { item in
            BillboardPage(item: item, topInset: topInset, height: height, leadingInset: sideInsets.leading, trailingInset: sideInsets.trailing) { contentHeight in
                if contentHeights[item.id] != contentHeight {
                    contentHeights[item.id] = contentHeight
                }
            }
            .containerRelativeFrame(.horizontal)
            .id(item.id)
        }
    }

    /// The height of the billboard's pages below the top inset: the design's, or more when a page's content needs
    /// it (its natural height, the room above it under the navigation bar and below it over the page indicator).
    private var pageHeight: CGFloat {
        let design = Self.billboardHeight(for: dynamicTypeSize)
        guard let tallest = items.compactMap({ contentHeights[$0.id] }).max() else {
            return design
        }
        return max(design, (tallest + Self.billboardContentMargins).rounded(.up))
    }

    /// Room around a billboard page's content: 16 points under the navigation bar, 30 over the page indicator.
    private static let billboardContentMargins: CGFloat = billboardTopMargin + 30
    /// Room between the navigation bar and the content of a billboard page.
    static let billboardTopMargin: CGFloat = 16

    /// The pages of the current rotation for the playlists of `importIDs` (`FeaturedLoader`). Also the pages of
    /// the Apple TV Home's hero (`TVHero`).
    static func loadPicks(importIDs: [UUID], container: ModelContainer) async -> [ChannelItem] {
        await FeaturedLoader.load(
            importIDs: importIDs,
            seed: FeaturedRotation.shared.currentSeed,
            hidesAdultContent: MatureContent.hidesAdultContent,
            container: container
        )
    }
}

/// One full-bleed billboard page: the artwork, the title and glass actions (the blurred backdrop is shared by
/// the pages, see `FeaturedCarousel.billboard`).
private struct BillboardPage: View {

    static let posterSize = CGSize(width: 112, height: 166)
    static let logoSize = CGSize(width: 132, height: 92)

    let item: ChannelItem
    let topInset: CGFloat
    /// The height of every page below the top inset (`FeaturedCarousel.pageHeight`).
    let height: CGFloat
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    /// Reports the natural height of the page's title, artwork and buttons.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    @Environment(\.playChannel) private var playChannel
    @Environment(ChannelLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext
    /// The player zooms out of this page's artwork.
    @State private var sourceID = UUID().uuidString
    /// A series: the episode Play plays (where the viewer left off).
    @State private var nextUp: SeriesNextUp?

    var body: some View {
        // A series is featured as a whole: its title, Play continues it, and the artwork and title open its page.
        let series = item.seriesItem
        let isFavorite = series.map(library.series.isFavorite) ?? library.isFavorite(item)
        let isLarge = dynamicTypeSize.prefersStackedLayout
        // The category without the kind the badge already says ("Film | Azione" under "Featured Movie").
        let category = item.kind.category(fromGroupName: item.groupName)
        // At the accessibility text sizes every page is as tall as the tallest one, which can be taller than the
        // screen: the content starts at the top, so a shorter page's title and Play are in view first, with the room
        // left below them rather than above.
        ZStack(alignment: isLarge ? .topLeading : .bottomLeading) {
            Color.clear

            VStack(alignment: .leading, spacing: 16) {
                // At the accessibility text sizes the title goes under the artwork, with the whole width.
                AdaptiveStack(verticalAlignment: .bottom, spacing: 16) {
                    seriesLink(series) {
                        artwork
                    }
                    .playerTransitionSource(id: sourceID)
                    .contextMenu {
                        if let series {
                            SeriesContextMenu(series: series)
                        } else {
                            ChannelContextMenu(item: item, isFavorite: isFavorite)
                        }
                    }

                    seriesLink(series) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kindLabel)
                                .font(.caption.weight(.bold))
                                .textCase(.uppercase)
                                .foregroundStyle(.tint)
                            Text(series?.title ?? item.displayName)
                                .font(Theme.Typography.heroTitle)
                                .lineLimit(isLarge ? 6 : 3)
                                .minimumScaleFactor(0.85)
                                .multilineTextAlignment(.leading)
                            if !category.isEmpty {
                                Text(TextParts.keepingSeparatorsAttached(category))
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(isLarge ? 3 : 1)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                    }
                }

                // Glass belongs to the controls, not to the artwork.
                HeroActions(title: playTitle(series), systemImage: "play.fill") {
                    play(series)
                } secondary: {
                    if item.url != nil {
                        Button {
                            if let series {
                                library.series.toggleFavorite(series)
                            } else {
                                library.toggleFavorite(item)
                            }
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
            // Its natural height, measured: the carousel makes every page as tall as the tallest one needs (large
            // text, long titles), so nothing is compressed or cut.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onContentHeight(height)
            }
            .padding(.leading, HomeLayout.horizontalMargin + leadingInset)
            .padding(.trailing, HomeLayout.horizontalMargin + trailingInset)
            .padding(.top, isLarge ? topInset + FeaturedCarousel.billboardTopMargin : 0)
            .padding(.bottom, 30)
        }
        .frame(height: topInset + height)
        .contentShape(.rect)
        .onTapGesture {
            // A series opens from its artwork and title; elsewhere a tap does nothing rather than start an
            // episode the viewer did not pick.
            if series == nil {
                playChannel(item, from: sourceID)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(playTitle(series))) {
            play(series)
        }
        .modifier(BillboardAccessibilityActions(item: item, series: series, isFavorite: isFavorite))
        .task(id: series.map { SeriesTaskKey(series: $0, state: library.series.state(for: $0)) }) {
            guard let series else {
                return
            }
            nextUp = await SeriesPlayback.nextUp(for: series, library: library, container: modelContext.container)
        }
    }

    private struct SeriesTaskKey: Hashable {
        let series: SeriesItem
        let state: SeriesWatchState?
    }

    private func playTitle(_ series: SeriesItem?) -> String {
        guard series != nil else {
            return item.kind == .live
                ? String(localized: "Watch Live", comment: "Button of a featured live channel on the Home page.")
                : String(localized: "Play", comment: "Button of a featured movie on the Home page.")
        }
        return SeriesPlayback.buttonTitle(for: nextUp)
    }

    private func play(_ series: SeriesItem?) {
        if let series {
            if let nextUp {
                playChannel(nextUp.episode, from: sourceID)
            } else {
                let container = modelContext.container
                Task {
                    await SeriesPlayback.play(series, library: library, container: container, playChannel: playChannel, from: sourceID)
                }
            }
        } else {
            playChannel(item, from: sourceID)
        }
    }

    /// The artwork and the title of a series open its page.
    @ViewBuilder
    private func seriesLink<Content: View>(_ series: SeriesItem?, @ViewBuilder content: () -> Content) -> some View {
        if let series {
            NavigationLink(value: series.route) {
                content()
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows the episodes"))
        } else {
            content()
        }
    }

    private var kindLabel: String {
        Self.kindLabel(for: item.kind)
    }

    /// The badge of a featured item.
    static func kindLabel(for kind: ChannelContentKind) -> String {
        switch kind {
        case .live:
            return String(localized: "Live Now", comment: "Badge of a featured live channel on the Home page.")
        case .movie:
            return String(localized: "Featured Movie", comment: "Badge of a featured movie on the Home page.")
        case .series:
            return String(localized: "Featured Series", comment: "Badge of a featured series on the Home page.")
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let isPoster = item.kind.usesPosterArtwork
        let size = isPoster ? Self.posterSize : Self.logoSize
        LogoImage(source: item.logo, size: isPoster ? size : CGSize(width: size.width - 20, height: size.height - 20), contentMode: isPoster ? .fill : .fit, accessibilityLabel: item.series?.seriesTitle ?? item.displayName) { phase in
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
        .artworkIgnoresInvertColors()
    }
}

/// The custom actions of a billboard page: a series' or a channel's.
private struct BillboardAccessibilityActions: ViewModifier {
    let item: ChannelItem
    let series: SeriesItem?
    let isFavorite: Bool

    func body(content: Content) -> some View {
        if let series {
            content.seriesAccessibilityActions(series)
        } else {
            content.channelAccessibilityActions(item, isFavorite: isFavorite)
        }
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
        if let series = item.seriesItem {
            // A series opens its page (where Play continues it).
            NavigationLink(value: series.route) {
                label(isFavorite: library.series.isFavorite(series), title: series.title, action: String(localized: "Episodes", comment: "Call to action of a featured series card (macOS): opens the series page."))
            }
            .buttonStyle(CardButtonStyle())
            .contextMenu {
                SeriesContextMenu(series: series)
            }
            .seriesAccessibilityActions(series)
        } else {
            let isFavorite = library.isFavorite(item)
            Button {
                playChannel(item, from: sourceID)
            } label: {
                label(isFavorite: isFavorite, title: item.displayName, action: item.kind == .live ? String(localized: "Watch Live") : String(localized: "Play"))
            }
            .buttonStyle(CardButtonStyle())
            .contextMenu {
                ChannelContextMenu(item: item, isFavorite: isFavorite)
            }
        }
    }

    private func label(isFavorite: Bool, title: String, action: String) -> some View {
            HStack(alignment: .bottom, spacing: 18) {
                artwork

                VStack(alignment: .leading, spacing: 8) {
                    Label(BillboardPage.kindLabel(for: item.kind), systemImage: item.kind.systemImage)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)

                    Text(title)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    if !item.groupName.isEmpty {
                        Text(item.groupName)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }

                    Label(action, systemImage: item.seriesItem == nil ? "play.fill" : "square.stack")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .glassEffect(.regular.tint(Theme.accentFill).interactive(), in: .capsule)
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
                        .accessibilityLabel(ChannelAccessibility.favoriteState)
                }
            }
            .contentShape(shape)
            .playerTransitionSource(id: sourceID, cornerRadius: 28)
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

#if DEBUG
extension Notification.Name {
    /// Debug harness (`featured-page:<n>`): pages the featured carousel to the page at the index that is the object.
    static let fluxoDebugFeaturedPage = Notification.Name("FluxoDebugFeaturedPage")
}
#endif
