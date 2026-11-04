//
//  SeriesDetailView.swift
//  Fluxo
//
//  The page of a series: a hero with the poster, the title, the counts and "Continue" (resume the episode
//  watched last, or play the next one), the favorite and the watched actions; a season picker; and the episodes
//  of the season with their number, title, watched state and progress. Opened from every series card and row.
//

import SwiftData
import SwiftUI

struct SeriesDetailView: View {

    /// The hero's text, the season chips and the episodes share one centered column this wide at most, so a
    /// wide window (iPad, Mac) reads as one page instead of a list stuck to the leading edge.
    static let columnWidth: CGFloat = 900

    let playlistID: UUID
    let seriesKey: String
    let title: String

    @Environment(\.modelContext) private var modelContext
    @Environment(ChannelLibrary.self) private var library
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// nil while loading.
    @State private var episodes: SeriesEpisodes?
    @State private var isLoaded = false
    @State private var selectedSeason: Int?
    @State private var heroSourceID = UUID().uuidString

    private struct LoadKey: Hashable {
        let playlistID: UUID
        let key: String
        /// A refresh of the playlist writes new rows.
        let isImporting: Bool
        let seriesRevision: Int
    }

    var body: some View {
        let series = episodes?.series ?? SeriesItem(playlistID: playlistID, key: seriesKey, title: title, artwork: nil, groupName: "")
        let state = library.series.state(for: series)
        let nextUp = episodes.flatMap { SeriesLookup.nextUp(in: $0, state: state, progressKeys: Set(library.watchProgressByKey.keys)) }
        let seasons = episodes?.seasons ?? []
        let season = selectedSeason.flatMap { seasons.contains($0) ? $0 : nil } ?? nextUp?.episode.series?.code.season ?? seasons.first
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SeriesHero(series: series, nextUp: nextUp, sourceID: heroSourceID, episodes: episodes?.episodes ?? [])

                if let episodes {
                    if seasons.count > 1, let season {
                        SeasonPicker(seasons: seasons, selection: season, isWatched: { isSeasonWatched($0, in: episodes, state: state) }) { picked in
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                                selectedSeason = picked
                            }
                        }
                        .frame(maxWidth: Self.columnWidth)
                        .frame(maxWidth: .infinity)
                    }

                    if let season {
                        EpisodeList(
                            title: seasons.count > 1 ? nil : EpisodeFormat.seasonTitle(season),
                            episodes: episodes.episodes(inSeason: season),
                            allEpisodes: episodes.episodes,
                            upNext: nextUp?.episode
                        )
                        .id(season)
                        .transition(.opacity)
                    }
                } else if isLoaded {
                    ContentUnavailableView(
                        "Series Not Found",
                        systemImage: "square.stack",
                        description: Text("The playlist no longer lists this series. Refresh the playlist or search for it.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .softScrollEdge()
        .navigationTitle(series.title)
        .inlineNavigationBar()
        // The favorite button is the hero's (one place for it).
        .sensoryFeedback(.selection, trigger: library.series.favoriteToggleCount)
        .task(id: LoadKey(playlistID: playlistID, key: seriesKey, isImporting: importCenter.progress[playlistID] != nil, seriesRevision: importCenter.seriesIndexRevision)) {
            let container = modelContext.container
            let playlistID = playlistID
            let key = seriesKey
            let loaded = await Task.detached(priority: .userInitiated) {
                SeriesLookup.episodes(playlistID: playlistID, key: key, in: container)
            }.value
            guard !Task.isCancelled else {
                return
            }
            episodes = loaded
            isLoaded = true
        }
    }

    private func isSeasonWatched(_ season: Int, in episodes: SeriesEpisodes, state: SeriesWatchState?) -> Bool {
        guard let watched = state?.watched, !watched.isEmpty else {
            return false
        }
        let inSeason = episodes.episodes(inSeason: season)
        return !inSeason.isEmpty && inSeason.allSatisfy { $0.series.map { watched.contains($0.code) } ?? false }
    }
}

// MARK: - Hero

/// Poster, title, counts, and the primary actions over a blurred backdrop of the poster.
private struct SeriesHero: View {

    static let posterSize = CGSize(width: 128, height: 192)

    let series: SeriesItem
    let nextUp: SeriesNextUp?
    let sourceID: String
    let episodes: [ChannelItem]

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let isFavorite = library.series.isFavorite(series)
        VStack(alignment: .leading, spacing: 16) {
            AdaptiveStack(verticalAlignment: .bottom, spacing: 18) {
                ChannelArtwork(logo: series.artwork, name: series.title, kind: .series, size: Self.posterSize)
                    .frame(width: Self.posterSize.width, height: Self.posterSize.height)
                    .background(.thinMaterial)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.surfaceStroke)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                    .playerTransitionSource(id: sourceID)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(ChannelContentKind.series.title)
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.tint)
                    Text(series.title)
                        .font(Theme.Typography.heroTitle)
                        .lineLimit(dynamicTypeSize.prefersStackedLayout ? 5 : 3)
                        .minimumScaleFactor(0.85)
                        .accessibilityAddTraits(.isHeader)
                    if let meta = metaLine {
                        Text(meta)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 4 : 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        if let nextUp {
                            playChannel(nextUp.episode, from: sourceID)
                        }
                    } label: {
                        Label(SeriesPlayback.buttonTitle(for: nextUp), systemImage: nextUp?.reason == .rewatch ? "arrow.counterclockwise" : "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentFill)
                    .disabled(nextUp == nil)

                    Button {
                        library.series.toggleFavorite(series)
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

                    Menu {
                        watchedActions
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("More Actions")
                    .disabled(episodes.isEmpty)
                }
            }
            .controlSize(.large)

            if let nextUp, let detail = upNextDetail(nextUp) {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, HomeLayout.horizontalMargin)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: SeriesDetailView.columnWidth, alignment: .leading)
        // The backdrop spans the whole width; the content stays in the page's column.
        .frame(maxWidth: .infinity)
        .background {
            SeriesBackdrop(artwork: series.artwork, reduceTransparency: reduceTransparency)
                .ignoresSafeArea(edges: [.top, .horizontal])
                .accessibilityHidden(true)
        }
    }

    /// "2008 · 5 seasons · 62 episodes · Drama".
    private var metaLine: String? {
        let year = series.year.map { $0.formatted(.number.grouping(.never)) }
        let group = series.groupName.isEmpty ? nil : series.groupName
        return TextParts.line([year, series.countsLine, group]).nilIfEmpty
    }

    /// Under the button: what it plays ("S1 E3 · Pilot · 20 min left"), when that says more than the button.
    private func upNextDetail(_ nextUp: SeriesNextUp) -> String? {
        guard let episode = nextUp.episode.series else {
            return nil
        }
        let remaining = library.watchProgress(for: nextUp.episode).map(WatchProgressFormat.remaining)
        guard episode.episodeTitle != nil || remaining != nil else {
            return nil
        }
        return TextParts.line([EpisodeFormat.code(episode), episode.episodeTitle, remaining])
    }

    @ViewBuilder
    private var watchedActions: some View {
        let watched = library.series.state(for: series)?.watched ?? []
        let allWatched = !episodes.isEmpty && episodes.allSatisfy { $0.series.map { watched.contains($0.code) } ?? false }
        if allWatched {
            Button("Mark Series as Unwatched", systemImage: "eye.slash") {
                library.setWatched(false, episodes: episodes)
            }
        } else {
            Button("Mark Series as Watched", systemImage: "checkmark.circle") {
                library.setWatched(true, episodes: episodes)
            }
            if !watched.isEmpty {
                Button("Mark Series as Unwatched", systemImage: "eye.slash") {
                    library.setWatched(false, episodes: episodes)
                }
            }
        }
    }
}

/// The poster, decoded tiny and blurred, on the brand gradient, fading into the screen background.
private struct SeriesBackdrop: View {

    static let decodeSize = CGSize(width: 24, height: 24)

    let artwork: String?
    let reduceTransparency: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.brandGradient
                if let artwork {
                    LogoImage(source: artwork, size: Self.decodeSize, contentMode: .fill) { _ in
                        Color.clear
                    }
                    .scaleEffect(max(proxy.size.width, proxy.size.height) / Self.decodeSize.width * 1.3)
                    .blur(radius: 28)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .opacity(0.95)
                }
                LinearGradient(
                    stops: [
                        .init(color: Color.appBackground.opacity(reduceTransparency ? 0.7 : 0.4), location: 0),
                        .init(color: Color.appBackground.opacity(reduceTransparency ? 0.85 : 0.55), location: 0.45),
                        .init(color: Color.appBackground, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .clipped()
    }
}

// MARK: - Seasons

/// The seasons as glass chips (they scroll when there are many), with a checkmark on fully watched seasons.
private struct SeasonPicker: View {

    let seasons: [Int]
    let selection: Int
    let isWatched: (Int) -> Bool
    let onSelect: (Int) -> Void

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.self) { season in
                            chip(season)
                                .id(season)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, HomeLayout.horizontalMargin, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Seasons"))
    }

    private func chip(_ season: Int) -> some View {
        let isSelected = season == selection
        return Button {
            onSelect(season)
        } label: {
            HStack(spacing: 6) {
                SelectionCheckmark(isSelected: isSelected)
                Text(EpisodeFormat.seasonTitle(season))
                    .lineLimit(1)
                if isWatched(season) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white : Theme.accent)
                        .accessibilityLabel(Text("Watched"))
                }
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(Theme.accentFill).interactive() : .regular.interactive(), in: .capsule)
        .glassEffectID(isSelected ? "season.selection" : "season.\(season)", in: glassNamespace)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Episodes

private struct EpisodeList: View {

    let title: String?
    let episodes: [ChannelItem]
    /// Every episode of the series, for "Mark Watched Up to Here".
    let allEpisodes: [ChannelItem]
    let upNext: ChannelItem?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(Theme.Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, HomeLayout.horizontalMargin)
                    .padding(.bottom, 8)
            }
            ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                EpisodeRow(episode: episode, isUpNext: episode.url == upNext?.url, earlier: earlierEpisodes(than: episode))
                if index < episodes.count - 1 {
                    Divider()
                        .padding(.leading, HomeLayout.horizontalMargin + EpisodeRow.numberWidth + 12)
                }
            }
        }
        .frame(maxWidth: SeriesDetailView.columnWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func earlierEpisodes(than episode: ChannelItem) -> [ChannelItem] {
        guard let index = allEpisodes.firstIndex(where: { $0.url == episode.url }) else {
            return [episode]
        }
        return Array(allEpisodes[...index])
    }
}

/// An episode: its number, title, watched state or progress. Tapping plays it.
private struct EpisodeRow: View {

    static let numberWidth: CGFloat = 40

    let episode: ChannelItem
    let isUpNext: Bool
    /// The episodes up to this one, in watching order.
    let earlier: [ChannelItem]

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.linkCopyFeedback) private var linkCopyFeedback
    @State private var sourceID = UUID().uuidString

    var body: some View {
        let ref = episode.series
        let isWatched = library.series.isWatched(episode)
        let progress = library.watchProgress(for: episode)
        let isFavorite = library.isFavorite(episode)
        Button {
            playChannel(episode, from: sourceID)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text(ref.map { $0.episode.formatted(.number.grouping(.never)) } ?? "")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(isWatched ? Theme.tertiaryText : Theme.secondaryText)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .frame(width: Self.numberWidth, alignment: .trailing)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if isUpNext {
                            Text("Up Next", comment: "Label of the episode of a series to watch next (Continue Watching, the series page, the player).")
                                .font(.caption2.weight(.heavy))
                                .textCase(.uppercase)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accentFill, in: .capsule)
                        }
                        Text(ref.map(EpisodeFormat.title) ?? episode.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isWatched ? Theme.secondaryText : Color.primary)
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 5 : 2)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.favorite)
                        }
                    }
                    // "S1 E3" under an episode's own title; without one the row already reads "3  Episode 3".
                    if let ref, ref.episodeTitle?.isEmpty == false {
                        Text(EpisodeFormat.code(ref))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if let progress {
                        HStack(spacing: 8) {
                            ProgrammeProgressBar(progress: progress.fraction, tint: Theme.accent, height: 3)
                                .frame(maxWidth: 140)
                            Text(WatchProgressFormat.remaining(progress))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isWatched ? "checkmark.circle.fill" : (progress != nil ? "play.circle.fill" : "play.circle"))
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isWatched ? Theme.secondaryText : Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, HomeLayout.horizontalMargin)
            .padding(.vertical, 12)
            .background(isUpNext ? Theme.accent.opacity(0.08) : Color.clear)
            .contentShape(.rect)
            .playerTransitionSource(id: sourceID, cornerRadius: 0)
        }
        .buttonStyle(.plain)
        .rowHoverEffect()
        .contextMenu {
            actions(isWatched: isWatched, progress: progress, isFavorite: isFavorite)
            // Copy Link and Share, in their own group, as in every channel menu.
            if StreamLink(episode.url) != nil {
                Divider()
                ChannelLinkMenuItems(item: episode)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel(isWatched: isWatched, progress: progress, isFavorite: isFavorite)))
        .accessibilityHint(Text(progress == nil ? "Plays the episode" : "Resumes the episode"))
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            actions(isWatched: isWatched, progress: progress, isFavorite: isFavorite)
            // Announces "Link copied" (and the credentials warning) itself.
            if let link = StreamLink(episode.url) {
                Button("Copy Link") {
                    LinkCopyFeedback.copy(link, feedback: linkCopyFeedback)
                }
            }
        }
    }

    @ViewBuilder
    private func actions(isWatched: Bool, progress: WatchProgress?, isFavorite: Bool) -> some View {
        Button(progress == nil ? "Play" : "Resume", systemImage: "play.fill") {
            playChannel(episode, from: sourceID)
        }
        if progress != nil {
            Button("Play from Beginning", systemImage: "arrow.counterclockwise") {
                library.saveWatchProgress(for: episode, position: 0, duration: progress?.duration ?? 1)
                playChannel(episode, from: sourceID)
            }
        }
        Button(isWatched ? "Mark as Unwatched" : "Mark as Watched", systemImage: isWatched ? "eye.slash" : "checkmark.circle") {
            library.setWatched(!isWatched, episodes: [episode])
        }
        if earlier.count > 1 {
            Button("Mark Watched Up to Here", systemImage: "text.badge.checkmark") {
                library.setWatched(true, episodes: earlier)
            }
        }
        if episode.url != nil {
            Button(isFavorite ? "Remove Episode from Favorites" : "Add Episode to Favorites", systemImage: isFavorite ? "star.slash" : "star") {
                library.toggleFavorite(episode)
            }
        }
    }

    private func accessibilityLabel(isWatched: Bool, progress: WatchProgress?, isFavorite: Bool) -> String {
        guard let ref = episode.series else {
            return episode.displayName
        }
        let state: String? = isWatched
            ? String(localized: "Watched", comment: "VoiceOver: an episode that was watched.")
            : progress.map(WatchProgressFormat.remaining)
        return TextParts.spoken([
            isUpNext ? String(localized: "Up Next", comment: "Label of the episode of a series to watch next (Continue Watching, the series page, the player).") : nil,
            EpisodeFormat.spokenCode(ref),
            EpisodeFormat.title(ref),
            state,
            isFavorite ? ChannelAccessibility.favoriteState : nil,
        ])
    }
}
