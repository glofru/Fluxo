//
//  TVHero.swift
//  Fluxo
//
//  The full-bleed hero at the top of the Apple TV Home: featured movies, series and live channels, all different and
//  chosen again every few hours and every day (the picks of the iPhone billboard, `FeaturedCarousel.loadPicks`,
//  `FeaturedRotation`), one page each, under the tab bar and to the edges
//  of the picture. Each page has a blurred backdrop of its artwork, the artwork itself, the title, what it is, and
//  Liquid Glass actions: Play (Resume S1 E3, Watch Live), Episodes for a series, and the favorite.
//
//  The pages sit side by side in a paging scroll view: moving the focus right from the last button of a page goes
//  to the first button of the next one, which scrolls into place, so a swipe pages through the hero as in the TV
//  app. While the focus is elsewhere the hero moves on to the next page every few seconds (not with Reduce Motion).
//

#if os(tvOS)
import SwiftData
import SwiftUI

struct TVHero: View {

    /// Height of the hero: the title of the first shelf and the top of its cards show under it.
    static let height: CGFloat = 820
    static let autoAdvanceInterval: Duration = .seconds(9)

    let importIDs: [UUID]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MatureContent.hidesAdultContentKey) private var hidesAdultContent = MatureContent.hidesAdultContentByDefault
    @State private var items: [ChannelItem] = []
    @State private var currentID: ChannelItem.ID?
    @FocusState private var focus: TVHeroFocus?

    var body: some View {
        Group {
            if items.isEmpty {
                // Room for the tab bar while the picks load (or when nothing has artwork).
                Color.clear
                    .frame(height: TVLayout.tabBarClearance)
            } else {
                pager
            }
        }
        .task(id: LoadKey(importIDs: importIDs, seed: FeaturedRotation.shared.currentSeed, hidesAdultContent: hidesAdultContent)) {
            let picks = await FeaturedCarousel.loadPicks(importIDs: importIDs, container: modelContext.container)
            guard !Task.isCancelled else {
                return
            }
            items = picks
            if currentID == nil || !picks.contains(where: { $0.id == currentID }) {
                currentID = picks.first?.id
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Other pages when the app comes back after a while (never while it stays on screen).
            if phase == .active {
                FeaturedRotation.shared.refreshIfDue()
            }
        }
        #if DEBUG
        // Debug harness (`featured-page:<n>`): shows a page, for screenshots.
        .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugFeaturedPage)) { notification in
            if let index = notification.object as? Int, items.indices.contains(index) {
                currentID = items[index].id
            }
        }
        #endif
        .task(id: AdvanceKey(ids: items.map(\.id), isFocused: focus != nil, reduceMotion: reduceMotion)) {
            // The pages move on by themselves only while nobody is reading them.
            guard items.count > 1, focus == nil, !reduceMotion else {
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoAdvanceInterval)
                guard !Task.isCancelled else {
                    return
                }
                let index = items.firstIndex { $0.id == currentID } ?? 0
                withAnimation(.smooth(duration: 0.8)) {
                    currentID = items[(index + 1) % items.count].id
                }
            }
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    TVHeroPage(item: item, index: index, count: items.count, focus: $focus)
                        .containerRelativeFrame(.horizontal)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        // Pages as wide as the screen, from its very edge (no safe-area margins: they would offset the pages).
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .ignoresSafeArea(edges: .horizontal)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .frame(height: Self.height)
        .focusSection()
        .onChange(of: focus) { _, focus in
            // The page of the focused button settles in place.
            if let id = focus?.itemID, id != currentID {
                withAnimation(.smooth(duration: 0.45)) {
                    currentID = id
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "TV.hero.label", defaultValue: "Featured", comment: "VoiceOver: the name of the featured items at the top of the Apple TV Home.")))
    }

    private struct LoadKey: Hashable {
        let importIDs: [UUID]
        let seed: UInt64
        let hidesAdultContent: Bool
    }

    private struct AdvanceKey: Hashable {
        let ids: [ChannelItem.ID]
        let isFocused: Bool
        let reduceMotion: Bool
    }
}

/// The focusable buttons of the hero's pages.
enum TVHeroFocus: Hashable {
    case play(ChannelItem.ID)
    case episodes(ChannelItem.ID)
    case favorite(ChannelItem.ID)

    var itemID: ChannelItem.ID {
        switch self {
        case .play(let id), .episodes(let id), .favorite(let id):
            return id
        }
    }
}

/// One page of the hero.
private struct TVHeroPage: View {
    let item: ChannelItem
    let index: Int
    let count: Int
    let focus: FocusState<TVHeroFocus?>.Binding

    @Environment(\.playChannel) private var playChannel
    @Environment(ChannelLibrary.self) private var library
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var nextUp: SeriesNextUp?
    #if DEBUG
    @Environment(AppNavigation.self) private var navigation
    #endif

    var body: some View {
        let series = item.seriesItem.map(library.series.summary(of:))
        ZStack(alignment: .bottomLeading) {
            backdrop
            HStack(alignment: .bottom, spacing: 60) {
                details(series: series)
                    .frame(maxWidth: 1_000, alignment: .leading)
                Spacer(minLength: 0)
                artwork
            }
            .padding(.horizontal, TVLayout.margin)
            .padding(.bottom, 70)
        }
        .frame(height: TVHero.height)
        .clipped()
        .task(id: series.map { SeriesTaskKey(series: $0, state: library.series.state(for: $0), progress: library.watchProgressByKey.count) }) {
            guard let series else {
                nextUp = nil
                return
            }
            nextUp = await SeriesPlayback.nextUp(for: series, library: library, container: modelContext.container)
        }
        #if DEBUG
        .onChange(of: navigation.debugFocusName, initial: true) { _, name in
            // `focus:hero` focuses the Play button of the first page.
            if index == 0, name?.lowercased() == "hero" {
                focus.wrappedValue = .play(item.id)
            }
        }
        #endif
    }

    // MARK: - Layers

    private var backdrop: some View {
        ZStack {
            TVBackdrop(logo: item.logo, name: item.displayName, kind: item.kind)
            // The text side and the bottom go dark (or light) for legibility; the bottom fades into the page.
            LinearGradient(
                stops: [
                    .init(color: scrim.opacity(0.85), location: 0),
                    .init(color: scrim.opacity(0.55), location: 0.45),
                    .init(color: scrim.opacity(0.05), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: pageBackground, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .accessibilityHidden(true)
    }

    /// Dark in dark mode, light in light mode: the text stays readable on any artwork.
    private var scrim: Color {
        colorScheme == .dark ? .black : .white
    }

    private var pageBackground: Color {
        .tvPageBackground(colorScheme)
    }

    @ViewBuilder
    private var artwork: some View {
        if item.kind.usesPosterArtwork {
            TVPosterArtwork(logo: item.logo, name: item.displayName, kind: item.kind, size: CGSize(width: 340, height: 510))
                .clipShape(.rect(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .accessibilityHidden(true)
        } else {
            TVLandscapeArtworkView(logo: item.logo, name: item.displayName, kind: item.kind, size: CGSize(width: 560, height: 315))
                .clipShape(.rect(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .accessibilityHidden(true)
        }
    }

    private func details(series: SeriesItem?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(BillboardText.kindLabel(for: item.kind))
                .font(.caption.weight(.heavy))
                .textCase(.uppercase)
                .foregroundStyle(.tint)
            Text(series?.title ?? item.displayName)
                .font(.system(size: 76, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            meta(series: series)
            buttons(series: series)
                .padding(.top, 12)
            TVPageDots(index: index, count: count)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func meta(series: SeriesItem?) -> some View {
        if item.kind == .live {
            NowNextReader(item: item) { nowNext in
                if let current = nowNext?.current {
                    HStack(spacing: 12) {
                        LiveBadge()
                        Text(TextParts.line([current.title, GuideFormat.timeRange(current)]))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    groupLine
                }
            }
        } else if let series {
            Text(TextParts.line([ChannelCandidate.displayGroup(series.groupName), series.year.map { EpisodeFormat.number($0) }, series.countsLine]))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            groupLine
        }
    }

    private var groupLine: some View {
        Text(ChannelCandidate.displayGroup(item.groupName))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func buttons(series: SeriesItem?) -> some View {
        let isFavorite = series.map(library.series.isFavorite) ?? library.isFavorite(item)
        return GlassEffectContainer(spacing: 24) {
            HStack(spacing: 24) {
                Button {
                    play(series)
                } label: {
                    Label(playTitle(series), systemImage: nextUp?.reason == .rewatch ? "arrow.counterclockwise" : "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 12)
                }
                .tvActionButton(prominent: true)
                .focused(focus, equals: .play(item.id))
                .accessibilityLabel(Text(TextParts.spoken([playTitle(series), series?.title ?? item.displayName])))

                if let series {
                    NavigationLink(value: series.route) {
                        Label(String(localized: "TV.hero.episodes", defaultValue: "Episodes", comment: "Apple TV Home, featured series: opens the page of the series with its seasons and episodes."), systemImage: "list.bullet")
                            .font(.headline)
                            .padding(.horizontal, 8)
                    }
                    .tvActionButton()
                    .focused(focus, equals: .episodes(item.id))
                }

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
                }
                .tvActionButton()
                .focused(focus, equals: .favorite(item.id))
                .accessibilityLabel(isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
            }
        }
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
        guard let series else {
            playChannel(item)
            return
        }
        if let nextUp {
            playChannel(nextUp.episode)
        } else {
            let container = modelContext.container
            Task {
                await SeriesPlayback.play(series, library: library, container: container, playChannel: playChannel)
            }
        }
    }

    private struct SeriesTaskKey: Hashable {
        let series: SeriesItem
        let state: SeriesWatchState?
        let progress: Int
    }
}

/// Which page of the hero shows, as dots (not focusable: the buttons page through it).
private struct TVPageDots: View {
    let index: Int
    let count: Int

    var body: some View {
        if count > 1 {
            HStack(spacing: 10) {
                ForEach(0..<count, id: \.self) { dot in
                    Capsule()
                        .fill(dot == index ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.3)))
                        .frame(width: dot == index ? 28 : 10, height: 10)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(String(localized: "TV.hero.page", defaultValue: "\(index + 1) of \(count)", comment: "VoiceOver: which featured item of the Apple TV Home hero shows, as in '2 of 8'.")))
        }
    }
}

/// The badge of a featured item (shared with the iPhone billboard's wording).
enum BillboardText {
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
}
#endif
