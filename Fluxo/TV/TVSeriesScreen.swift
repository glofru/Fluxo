//
//  TVSeriesScreen.swift
//  Fluxo
//
//  The page of a series on Apple TV: a full-bleed backdrop of its poster, the poster, the title and counts, and the
//  actions (Continue: resume the episode watched last or play the next one; the favorite; mark the season as
//  watched), then the seasons as a row of tabs (moving the focus onto one shows its episodes, as in the TV app) and
//  the season's episodes as a shelf: number, title, watched state, progress, Up Next. Continue has the focus when
//  the page opens; coming back from the player, the focus returns to the episode that was played.
//
//  Focus between the rows is predictable rather than geometric: down from the actions or up from the episodes
//  lands on the selected season's tab, and down from the tabs (or Select on one) enters the season at its Up Next
//  episode, or its first.
//

#if os(tvOS)
import SwiftData
import SwiftUI

struct TVSeriesScreen: View {

    let playlistID: UUID
    let seriesKey: String
    let title: String

    @Environment(\.modelContext) private var modelContext
    @Environment(ChannelLibrary.self) private var library
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(\.playChannel) private var playChannel
    @Environment(\.colorScheme) private var colorScheme

    /// nil while loading.
    @State private var episodes: SeriesEpisodes?
    @State private var isLoaded = false
    @State private var selectedSeason: Int?
    @FocusState private var focus: TVSeriesFocus?

    private struct LoadKey: Hashable {
        let playlistID: UUID
        let key: String
        let isImporting: Bool
        let seriesRevision: Int
    }

    var body: some View {
        let series = episodes?.series ?? SeriesItem(playlistID: playlistID, key: seriesKey, title: title, artwork: nil, groupName: "")
        let state = library.series.state(for: series)
        let nextUp = episodes.flatMap { SeriesLookup.nextUp(in: $0, state: state, progressKeys: Set(library.watchProgressByKey.keys)) }
        let seasons = episodes?.seasons ?? []
        let season = selectedSeason.flatMap { seasons.contains($0) ? $0 : nil } ?? nextUp?.episode.series?.code.season ?? seasons.first
        ZStack(alignment: .top) {
            backdrop(series: series)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 40) {
                    header(series: series, nextUp: nextUp, season: season, state: state)
                        .padding(.top, 120)
                    if let episodes {
                        if seasons.count > 1 {
                            seasonTabs(seasons: seasons, selection: season, episodes: episodes, upNext: nextUp?.episode, state: state)
                        }
                        if let season {
                            episodeShelf(episodes.episodes(inSeason: season), title: seasons.count > 1 ? nil : EpisodeFormat.seasonTitle(season), upNext: nextUp?.episode, state: state)
                                .id(season)
                        }
                    } else if isLoaded {
                        TVEmptyState(title: String(localized: "Series Not Found"), message: String(localized: "The playlist no longer lists this series. Refresh the playlist or search for it."), systemImage: "square.stack")
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                .padding(.bottom, TVLayout.verticalMargin)
            }
            .scrollClipDisabled()
        }
        .ignoresSafeArea()
        .defaultFocus($focus, .play)
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
        #if DEBUG
        .onChange(of: navigation.debugFocusName, initial: true) { _, name in
            debugFocus(name)
        }
        .onChange(of: isLoaded) {
            debugFocus(navigation.debugFocusName)
        }
        #endif
    }

    #if DEBUG
    @Environment(AppNavigation.self) private var navigation

    /// `focus:play`, `focus:favorite`, `focus:season:<n>`, `focus:episode:<S1 E2>`.
    private func debugFocus(_ name: String?) {
        guard let name = name?.lowercased(), let episodes else {
            return
        }
        if name == "play" {
            focus = .play
        } else if name == "favorite" {
            focus = .favorite
        } else if name.hasPrefix("season:"), let number = Int(name.dropFirst("season:".count)) {
            focus = .season(number)
        } else if name.hasPrefix("episode:") {
            let code = String(name.dropFirst("episode:".count))
            if let episode = episodes.episodes.first(where: { $0.episodeLabel?.lowercased() == code }) {
                selectedSeason = episode.series?.code.season
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    focus = .episode(episode.id)
                }
            }
        }
    }
    #endif

    // MARK: - Backdrop and header

    private func backdrop(series: SeriesItem) -> some View {
        let scrim: Color = colorScheme == .dark ? .black : .white
        return ZStack {
            TVBackdrop(logo: series.artwork, name: series.title, kind: .series)
            LinearGradient(colors: [scrim.opacity(0.9), scrim.opacity(0.55), scrim.opacity(0.2)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .tvPageBackground(colorScheme), location: 0.95)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// "Mark Season 2 as Watched", or "Mark Specials as Unwatched" for season 0: a key each, so that every language
    /// can make the words agree with the season (a season's name in the middle of a sentence cannot).
    private static func markSeasonTitle(_ season: Int, watched: Bool) -> String {
        switch (season == 0, watched) {
        case (true, true):
            String(localized: "TV.series.markSpecialsWatched", defaultValue: "Mark Specials as Watched", comment: "Apple TV, series page: marks every special of a series (its season 0, the Specials) as watched.")
        case (true, false):
            String(localized: "TV.series.markSpecialsUnwatched", defaultValue: "Mark Specials as Unwatched", comment: "Apple TV, series page: marks every special of a series (its season 0, the Specials) as not watched.")
        case (false, true):
            String(localized: "TV.series.markSeasonNumberWatched", defaultValue: "Mark Season \(EpisodeFormat.number(season)) as Watched", comment: "Apple TV, series page: marks every episode of a season as watched; the placeholder is the season number, as in 'Season 2'.")
        case (false, false):
            String(localized: "TV.series.markSeasonNumberUnwatched", defaultValue: "Mark Season \(EpisodeFormat.number(season)) as Unwatched", comment: "Apple TV, series page: marks every episode of a season as not watched; the placeholder is the season number, as in 'Season 2'.")
        }
    }

    private func header(series: SeriesItem, nextUp: SeriesNextUp?, season: Int?, state: SeriesWatchState?) -> some View {
        let isFavorite = library.series.isFavorite(series)
        let seasonEpisodes = season.flatMap { episodes?.episodes(inSeason: $0) } ?? []
        let isSeasonWatched = !seasonEpisodes.isEmpty && seasonEpisodes.allSatisfy { library.series.isWatched($0) }
        return HStack(alignment: .bottom, spacing: 60) {
            TVPosterArtwork(logo: series.artwork, name: series.title, kind: .series, size: CGSize(width: 320, height: 480))
                .clipShape(.rect(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 18) {
                Text(ChannelContentKind.series.title)
                    .font(.caption.weight(.heavy))
                    .textCase(.uppercase)
                    .foregroundStyle(.tint)
                Text(series.title)
                    .font(.system(size: 76, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                if let meta = TextParts.line([series.groupName.isEmpty ? nil : ChannelCandidate.displayGroup(series.groupName), series.year.map { EpisodeFormat.number($0) }, series.countsLine]).nilIfEmpty {
                    Text(meta)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let nextUp, let episode = nextUp.episode.series {
                    Text(TextParts.line([nextUpLabel(nextUp.reason), EpisodeFormat.code(episode), EpisodeFormat.title(episode)]))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                GlassEffectContainer(spacing: 24) {
                    HStack(spacing: 24) {
                        Button {
                            if let nextUp {
                                playChannel(nextUp.episode)
                            }
                        } label: {
                            Label(SeriesPlayback.buttonTitle(for: nextUp), systemImage: nextUp?.reason == .rewatch ? "arrow.counterclockwise" : "play.fill")
                                .font(.headline)
                                .padding(.horizontal, 12)
                        }
                        .tvActionButton(prominent: true)
                        .disabled(nextUp == nil)
                        .focused($focus, equals: .play)

                        Button {
                            library.series.toggleFavorite(series)
                        } label: {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.headline)
                                .foregroundStyle(isFavorite ? Theme.favorite : Color.primary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .tvActionButton()
                        .focused($focus, equals: .favorite)
                        .accessibilityLabel(isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))

                        if let season, !seasonEpisodes.isEmpty {
                            Button {
                                library.series.setWatched(!isSeasonWatched, for: seasonEpisodes)
                            } label: {
                                Label(Self.markSeasonTitle(season, watched: !isSeasonWatched), systemImage: isSeasonWatched ? "eye.slash" : "checkmark.circle")
                                    .font(.headline)
                                    .labelStyle(.iconOnly)
                            }
                            .tvActionButton()
                            .focused($focus, equals: .markWatched)
                        }
                    }
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: 1_100, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TVLayout.margin)
        .focusSection()
    }

    private func nextUpLabel(_ reason: SeriesNextUp.Reason) -> String {
        switch reason {
        case .resume:
            return String(localized: "TV.series.continue", defaultValue: "Continue", comment: "Apple TV, series page: before the episode watched part-way, as in 'Continue · S1 E3 · Title'.")
        case .next, .restart:
            return String(localized: "Up Next", comment: "Label of the episode of a series to watch next (Continue Watching, the series page, the player).")
        case .start:
            return String(localized: "TV.series.start", defaultValue: "Start Watching", comment: "Apple TV, series page: before the first episode of a series never watched, as in 'Start Watching · S1 E1 · Title'.")
        case .rewatch:
            return String(localized: "TV.series.watched", defaultValue: "Watched", comment: "Apple TV, series page: before the first episode when every episode was watched, as in 'Watched · S1 E1 · Title'.")
        }
    }

    // MARK: - Seasons and episodes

    private func seasonTabs(seasons: [Int], selection: Int?, episodes: SeriesEpisodes, upNext: ChannelItem?, state: SeriesWatchState?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(seasons, id: \.self) { season in
                        let isSelected = season == selection
                        let isWatched = isSeasonWatched(season, in: episodes, state: state)
                        Button {
                            // The focus already chose the season: Select goes on into its episodes.
                            selectedSeason = season
                            if let entry = Self.entryEpisode(of: episodes.episodes(inSeason: season), upNext: upNext) {
                                focus = .episode(entry.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text(EpisodeFormat.seasonTitle(season))
                                if isWatched {
                                    Image(systemName: "checkmark.circle.fill")
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        // One button style whatever the selection: switching styles as the focus selected a season
                        // replaced the focused button, and the focus fell back to the first season.
                        .buttonStyle(TVSeasonTabStyle(isSelected: isSelected))
                        .focused($focus, equals: .season(season))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityValue(isWatched ? Text("Watched") : Text(verbatim: ""))
                    }
                }
                .padding(.vertical, 24)
            }
            .contentMargins(.horizontal, TVLayout.margin, for: .scrollContent)
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .onAppear {
                // A page that opens on a later season (its Up Next) shows that season's tab.
                if let selection, selection != seasons.first {
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
        // Coming into the row from the actions or the episodes, the focus lands on the selected season, not on
        // whichever tab happens to be nearest.
        .defaultFocus($focus, selection.map { TVSeriesFocus.season($0) }, priority: .userInitiated)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Seasons", comment: "VoiceOver label of the season picker on a series page."))
        .onChange(of: focus) { _, focus in
            // As in the TV app, the season under the focus shows its episodes.
            if case .season(let season) = focus, season != selectedSeason {
                selectedSeason = season
            }
        }
    }

    /// Where the focus enters a season's episodes: its Up Next episode, or its first.
    private static func entryEpisode(of list: [ChannelItem], upNext: ChannelItem?) -> ChannelItem? {
        upNext.flatMap { upNext in list.first { $0.url == upNext.url } } ?? list.first
    }

    private func isSeasonWatched(_ season: Int, in episodes: SeriesEpisodes, state: SeriesWatchState?) -> Bool {
        guard let watched = state?.watched, !watched.isEmpty else {
            return false
        }
        let inSeason = episodes.episodes(inSeason: season)
        return !inSeason.isEmpty && inSeason.allSatisfy { $0.series.map { watched.contains($0.code) } ?? false }
    }

    private func episodeShelf(_ list: [ChannelItem], title: String?, upNext: ChannelItem?, state: SeriesWatchState?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                TVSectionTitle(title: title, subtitle: String(localized: "\(list.count) episodes", comment: "Number of episodes of a series."))
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: TVLayout.cardSpacing) {
                        ForEach(list) { episode in
                            TVEpisodeCard(episode: episode, isUpNext: episode.url == upNext?.url, focus: $focus)
                                .id(episode.id)
                        }
                    }
                    .padding(.vertical, TVLayout.focusPadding)
                }
                .contentMargins(.horizontal, TVLayout.margin, for: .scrollContent)
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .onAppear {
                    // The season opens at the episode to watch next, when it is not among the first ones.
                    if let upNext, let index = list.firstIndex(where: { $0.id == upNext.id }), index >= 3 {
                        proxy.scrollTo(upNext.id, anchor: .center)
                    }
                }
            }
        }
        // Moving down into the episodes enters them at the one to watch next (or the first), not below the tab.
        .defaultFocus($focus, Self.entryEpisode(of: list, upNext: upNext).map { TVSeriesFocus.episode($0.id) }, priority: .userInitiated)
        .focusSection()
    }
}

/// A season tab, drawn like the items of the tvOS tab bar: plain text; the selected season on a soft capsule; the
/// focused tab lifted on a bright capsule with dark text, whether it is selected or not. One style for every
/// state, so the button keeps its identity (and the focus) when its season becomes the selected one.
private struct TVSeasonTabStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVSeasonTab(configuration: configuration, isSelected: isSelected)
    }
}

private struct TVSeasonTab: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        configuration.label
            .font(.callout.weight(isFocused || isSelected ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background {
                Capsule()
                    .fill(fill)
            }
            .shadow(color: .black.opacity(isFocused ? 0.32 : 0), radius: 20, y: 12)
            .scaleEffect(configuration.isPressed ? 1.0 : isFocused ? 1.08 : 1)
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isSelected)
    }

    private var foreground: Color {
        if isFocused {
            return .black
        }
        return isSelected ? .primary : Theme.secondaryText
    }

    private var fill: Color {
        if isFocused {
            return .white
        }
        if isSelected {
            return .primary.opacity(colorScheme == .dark ? 0.2 : 0.12)
        }
        return .clear
    }
}

enum TVSeriesFocus: Hashable {
    case play
    case favorite
    case markWatched
    case season(Int)
    case episode(UUID)
}

/// An episode: its artwork with the watched mark and progress, the number and title. Plays it; the long-press
/// menu marks it as watched or not.
private struct TVEpisodeCard: View {
    let episode: ChannelItem
    let isUpNext: Bool
    let focus: FocusState<TVSeriesFocus?>.Binding

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @FocusState private var isFocused: Bool

    var body: some View {
        let ref = episode.series
        let isWatched = library.series.isWatched(episode)
        let progress = library.watchProgress(for: episode)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                playChannel(episode)
            } label: {
                TVLandscapeArtwork(item: episode)
                    .overlay(alignment: .topTrailing) {
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Theme.accentFill)
                                .padding(14)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if isUpNext {
                            Text("Up Next", comment: "Label of the episode of a series to watch next (Continue Watching, the series page, the player).")
                                .font(.caption2.weight(.heavy))
                                .textCase(.uppercase)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassEffect(.regular.tint(Theme.accentFill), in: .capsule)
                                .padding(14)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress {
                            ProgrammeProgressBar(progress: progress.fraction, tint: Theme.accent, height: 6)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 14)
                        }
                    }
                    .frame(width: TVLayout.landscapeCard.width, height: TVLayout.landscapeCard.height)
                    .clipShape(.rect(cornerRadius: TVLayout.cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.card)
            .focused(focus, equals: .episode(episode.id))
            .focused($isFocused)
            .contextMenu {
                Button {
                    library.series.setWatched(!isWatched, for: [episode])
                } label: {
                    Label(isWatched ? String(localized: "Mark as Unwatched") : String(localized: "Mark as Watched"), systemImage: isWatched ? "eye.slash" : "checkmark.circle")
                }
                Button {
                    library.toggleFavorite(episode)
                } label: {
                    Label(library.isFavorite(episode) ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"), systemImage: library.isFavorite(episode) ? "star.slash" : "star")
                }
            }
            .accessibilityLabel(Text(TextParts.spoken([
                ref.map(EpisodeFormat.spokenCode),
                // Only a title of its own: the "Episode 3" an untitled episode shows would repeat the number.
                ref?.episodeTitle?.nilIfEmpty,
                isUpNext ? String(localized: "Up Next", comment: "Label of the episode of a series to watch next (Continue Watching, the series page, the player).") : nil,
                isWatched ? String(localized: "Watched") : progress.map(WatchProgressFormat.remaining),
            ])))
            .accessibilityHint(Text(TVText.playsHint(for: episode)))

            VStack(alignment: .leading, spacing: 6) {
                Text(ref.map(EpisodeFormat.code) ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(ref.map(EpisodeFormat.title) ?? episode.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if let progress {
                    Text(WatchProgressFormat.remaining(progress))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: TVLayout.landscapeCard.width, alignment: .leading)
            .padding(.top, 14)
            .offset(y: isFocused ? 18 : 0)
            .animation(.easeOut(duration: 0.18), value: isFocused)
            .accessibilityHidden(true)
        }
    }
}

#endif
