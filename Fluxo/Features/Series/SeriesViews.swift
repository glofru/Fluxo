//
//  SeriesViews.swift
//  Fluxo
//
//  A series as a card (rows, grids, the billboard's neighbours), as a list row (search, list layouts), its
//  context menu, and "Continue": where the viewer left off. Cards and rows open the series page.
//

import SwiftData
import SwiftUI

extension SeriesItem {
    /// The series page.
    var route: ChannelRoute {
        .series(playlistID: playlistID, key: key, title: title)
    }
}

/// Resolves what "Continue" / "Play" plays for a series.
@MainActor
enum SeriesPlayback {

    /// The episode to play (resume, next or first) from the episodes in the store and what the viewer watched.
    static func nextUp(for series: SeriesItem, library: ChannelLibrary, container: ModelContainer) async -> SeriesNextUp? {
        let state = library.series.state(for: series)
        let progressKeys = Set(library.watchProgressByKey.keys)
        return await Task.detached(priority: .userInitiated) {
            guard let episodes = SeriesLookup.episodes(of: series, in: container) else {
                return nil
            }
            return SeriesLookup.nextUp(in: episodes, state: state, progressKeys: progressKeys)
        }.value
    }

    /// Plays where the viewer left off; says so when the series has no playable episode any more.
    static func play(_ series: SeriesItem, library: ChannelLibrary, container: ModelContainer, playChannel: PlayChannelAction, from sourceID: String? = nil) async {
        guard let nextUp = await nextUp(for: series, library: library, container: container) else {
            AccessibilityAnnouncer.announce(String(localized: "\(series.title) has no episodes to play", comment: "VoiceOver: a series could not be played because its playlist no longer lists episodes of it."), priority: .high)
            return
        }
        playChannel(nextUp.episode, from: sourceID)
    }

    /// "Resume S1 E3", "Play S1 E4", "Play" (never watched), "Watch Again".
    static func buttonTitle(for nextUp: SeriesNextUp?) -> String {
        guard let nextUp, let code = nextUp.episode.episodeLabel else {
            return String(localized: "Play", comment: "Button: plays a series from its first episode.")
        }
        switch nextUp.reason {
        case .start:
            return String(localized: "Play \(code)", comment: "Button: plays the first episode of a series; the placeholder is the short episode label, such as S1 E1.")
        case .resume:
            return String(localized: "Resume \(code)", comment: "Button: resumes an episode of a series; the placeholder is the short episode label, such as S1 E3.")
        case .next, .restart:
            return String(localized: "Play \(code)", comment: "Button: plays the next episode of a series; the placeholder is the short episode label, such as S1 E4.")
        case .rewatch:
            return String(localized: "Watch Again", comment: "Button: plays a series that was watched to the end from its first episode again.")
        }
    }
}

/// A series in a row or a grid: its poster on a small stack of sheets (a series is many videos), its title and
/// a second line (the episode counts, or the last episode watched). Opens the series page.
struct SeriesCard: View {

    /// The sheets behind the poster take this much of the card's height.
    static let stackInset: CGFloat = 8

    /// As the card was given it; `series` adds the counts once they are loaded (a card built from an episode).
    private let givenSeries: SeriesItem
    var subtitle: String?
    /// Width of the card (grids); nil for the standard poster size.
    var width: CGFloat?

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var scale = CardScale()

    private let borderShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    init(series: SeriesItem, subtitle: String? = nil, width: CGFloat? = nil) {
        givenSeries = series
        self.subtitle = subtitle
        self.width = width
    }

    private var series: SeriesItem {
        library.series.summary(of: givenSeries)
    }

    private var size: CGSize {
        let standard = ChannelPreview.posterSize
        guard let width else {
            return scale.scaled(standard)
        }
        return CGSize(width: width, height: (width * standard.height / standard.width).rounded())
    }

    var body: some View {
        let isFavorite = library.series.isFavorite(series)
        let state = library.series.state(for: series)
        let posterSize = CGSize(width: size.width, height: size.height - Self.stackInset)
        NavigationLink(value: series.route) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    // The stack: two sheets peeking out above the poster.
                    borderShape
                        .fill(Color.artworkPlaceholder.opacity(0.25))
                        .frame(width: size.width - 20, height: posterSize.height)
                        .offset(y: -Self.stackInset)
                    borderShape
                        .fill(Color.artworkPlaceholder.opacity(0.45))
                        .frame(width: size.width - 10, height: posterSize.height)
                        .offset(y: -Self.stackInset / 2)
                    ChannelArtwork(logo: series.artwork, name: series.title, kind: .series, size: posterSize)
                        .frame(width: posterSize.width, height: posterSize.height)
                        .background(Color.artworkPlaceholder.opacity(0.4))
                        .clipShape(borderShape)
                        .overlay(alignment: .topTrailing) {
                            if isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(Theme.favorite)
                                    .padding(6)
                                    .background(.thinMaterial, in: .circle)
                                    .padding(8)
                                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            badge(state: state)
                                .padding(8)
                        }
                        .overlay {
                            borderShape.strokeBorder(Theme.surfaceStroke)
                        }
                        .routeTransitionSource(series.route, cornerRadius: 16)
                }
                .frame(width: size.width, height: size.height, alignment: .bottom)
                .accessibilityHidden(true)

                Text(series.title)
                    .font(Theme.Typography.cardTitle)
                    .lineLimit(CardTextMetrics.titleLineLimit(secondLine == nil ? 2 : 1, at: dynamicTypeSize), reservesSpace: !dynamicTypeSize.prefersStackedLayout)
                    .multilineTextAlignment(.leading)

                if let secondLine {
                    // Narrow cards (grids on small phones): the episode count alone rather than a cut line.
                    ViewThatFits(in: .horizontal) {
                        Text(secondLine)
                            .lineLimit(1)
                        Text(shortSecondLine ?? secondLine)
                            .lineLimit(CardTextMetrics.titleLineLimit(1, at: dynamicTypeSize))
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: size.width, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(CardButtonStyle())
        .cardHoverEffect()
        .contextMenuPreviewShape(borderShape)
        .contextMenu {
            SeriesContextMenu(series: series)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4), value: isFavorite)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(SeriesAccessibility.label(for: series, isFavorite: isFavorite, state: state, extra: [subtitle])))
        .accessibilityHint(Text("Shows the episodes"))
        .accessibilityAddTraits(.isButton)
        .seriesAccessibilityActions(series)
        .loadsSeriesSummary(givenSeries)
        .help(series.title)
    }

    /// The counts, unless the card was given its own line (a recommendation's reason).
    private var secondLine: String? {
        subtitle ?? series.countsLine
    }

    private var shortSecondLine: String? {
        subtitle == nil ? series.episodesLine : nil
    }

    /// The series symbol, with the episode watched last ("S1 E4") once the viewer started it.
    private func badge(state: SeriesWatchState?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ChannelContentKind.series.systemImage)
            if let last = state?.lastEpisode {
                Text(EpisodeFormat.code(season: last.season, episode: last.episode))
                    .monospacedDigit()
            }
        }
        .font(.caption2.bold())
        .padding(.horizontal, state?.lastEpisode == nil ? 5 : 7)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: .capsule)
    }
}

/// A series in a list: poster, title, counts, and a chevron to its page.
struct SeriesListRow: View {

    /// As the row was given it; `series` adds the counts once they are loaded (a row built from an episode).
    private let givenSeries: SeriesItem
    var subtitle: String?

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(series: SeriesItem, subtitle: String? = nil) {
        givenSeries = series
        self.subtitle = subtitle
    }

    private var series: SeriesItem {
        library.series.summary(of: givenSeries)
    }

    var body: some View {
        let isFavorite = library.series.isFavorite(series)
        let state = library.series.state(for: series)
        NavigationLink(value: series.route) {
            HStack(spacing: 12) {
                ChannelLogoTile(
                    item: ChannelItem(id: UUID(), playlistID: series.playlistID, name: series.title, logo: series.artwork, url: nil, groupName: series.groupName, kind: .series),
                    size: ChannelListRow.posterSize,
                    cornerRadius: 8
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(series.title)
                            .font(.body.weight(.semibold))
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 4 : 2)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.favorite)
                                .accessibilityHidden(true)
                        }
                    }
                    if let line = TextParts.line([subtitle, series.countsLine].compactMap { $0 }).nilIfEmpty {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                    }
                    if let last = state?.lastEpisode {
                        Label(String(localized: "Last watched \(EpisodeFormat.code(season: last.season, episode: last.episode))", comment: "Series row: the episode watched last, as in 'Last watched S1 E4'."), systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .rowHoverEffect()
        .contextMenu {
            SeriesContextMenu(series: series)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "star.slash.fill" : "star.fill") {
                library.series.toggleFavorite(series)
            }
            .tint(Theme.favoriteFill)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(SeriesAccessibility.label(for: series, isFavorite: isFavorite, state: state, extra: [subtitle])))
        .accessibilityHint(Text("Shows the episodes"))
        .seriesAccessibilityActions(series)
        .loadsSeriesSummary(givenSeries)
    }
}

/// Continue / Play, the favorite, and Copy Episode Link of a series.
struct SeriesContextMenu: View {

    let series: SeriesItem

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.linkCopyFeedback) private var linkCopyFeedback

    var body: some View {
        let isFavorite = library.series.isFavorite(series)
        Text(series.title)

        Button(library.series.state(for: series) == nil ? "Play" : "Continue", systemImage: "play.fill") {
            let container = modelContext.container
            Task {
                await SeriesPlayback.play(series, library: library, container: container, playChannel: playChannel)
            }
        }

        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star") {
            library.series.toggleFavorite(series)
        }

        // The link of the episode Continue would play, in its own group as in every channel menu. (No Share: the
        // episode is only known once it is looked up, after the menu closed.)
        Divider()
        Button(SeriesLinkCopy.title, systemImage: "link") {
            let container = modelContext.container
            let feedback = linkCopyFeedback
            Task {
                await SeriesLinkCopy.copy(series, library: library, container: container, feedback: feedback)
            }
        }
    }
}

enum SeriesAccessibility {
    /// "Breaking Bad, Series, Favorite, 5 seasons, 62 episodes, Last watched S1 E4".
    static func label(for series: SeriesItem, isFavorite: Bool, state: SeriesWatchState?, extra: [String?] = []) -> String {
        var parts: [String?] = [series.title, ChannelContentKind.series.title]
        if isFavorite {
            parts.append(ChannelAccessibility.favoriteState)
        }
        parts.append(series.countsLine)
        if let last = state?.lastEpisode {
            parts.append(String(localized: "Last watched \(EpisodeFormat.code(season: last.season, episode: last.episode))"))
        }
        parts.append(contentsOf: extra)
        return TextParts.spoken(parts.compactMap { $0 }.filter { !$0.isEmpty })
    }
}

extension View {
    /// Loads the counts (and the poster) of a series shown without them (`SeriesLibrary.summary(of:)`).
    func loadsSeriesSummary(_ series: SeriesItem) -> some View {
        modifier(SeriesSummaryLoader(series: series))
    }

    /// Continue, favorite and Copy Episode Link as custom actions (the VoiceOver Actions rotor), and the title for Voice Control.
    func seriesAccessibilityActions(_ series: SeriesItem) -> some View {
        modifier(SeriesAccessibilityActions(series: series))
    }
}

private struct SeriesSummaryLoader: ViewModifier {
    let series: SeriesItem

    @Environment(ChannelLibrary.self) private var library

    private struct Request: Hashable {
        let key: String
        let revision: Int
    }

    func body(content: Content) -> some View {
        if series.episodeCount == nil {
            content.task(id: Request(key: series.bookmarkKey, revision: library.series.summaryRevision)) {
                library.series.loadSummary(of: series)
            }
        } else {
            content
        }
    }
}

private struct SeriesAccessibilityActions: ViewModifier {
    let series: SeriesItem

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.linkCopyFeedback) private var linkCopyFeedback

    func body(content: Content) -> some View {
        let isFavorite = library.series.isFavorite(series)
        content
            .accessibilityInputLabels([Text(series.title)])
            .accessibilityActions {
                Button(library.series.state(for: series) == nil ? "Play" : "Continue") {
                    let container = modelContext.container
                    Task {
                        await SeriesPlayback.play(series, library: library, container: container, playChannel: playChannel)
                    }
                }
                Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    library.series.toggleFavorite(series)
                    AccessibilityAnnouncer.announce(
                        isFavorite
                            ? String(localized: "Removed \(series.title) from Favorites")
                            : String(localized: "Added \(series.title) to Favorites")
                    )
                }
                // Announces "Link to season 1, episode 4 copied" (and the credentials warning) itself.
                Button(SeriesLinkCopy.title) {
                    let container = modelContext.container
                    let feedback = linkCopyFeedback
                    Task {
                        await SeriesLinkCopy.copy(series, library: library, container: container, feedback: feedback)
                    }
                }
            }
    }
}

extension String {
    /// nil for an empty string.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
