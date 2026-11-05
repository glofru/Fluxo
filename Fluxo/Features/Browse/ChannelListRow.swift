//
//  ChannelListRow.swift
//  Fluxo
//
//  Rows of the channel lists (a category in list layout, search results): channel number, logo, name,
//  LIVE and what is on now and next from the TV guide with its progress, plus swipe and context actions.
//

import SwiftUI

/// Artwork of a channel in a row or a tile: the logo fitted on a soft surface (live) or the poster filling it
/// (movies, series). Without usable artwork it shows the initials placeholder.
struct ChannelLogoTile: View {

    let item: ChannelItem
    let size: CGSize
    var cornerRadius: CGFloat = 10

    var body: some View {
        let isPoster = item.kind.usesPosterArtwork
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if item.logo == nil {
                ArtworkPlaceholder(name: item.displayName, kind: item.kind)
            } else {
                LogoImage(
                    source: item.logo,
                    size: isPoster ? size : CGSize(width: size.width * 0.78, height: size.height * 0.72),
                    contentMode: isPoster ? .fill : .fit,
                    accessibilityLabel: item.displayName
                ) { phase in
                    if phase == .unavailable {
                        ArtworkPlaceholder(name: item.displayName, kind: item.kind)
                            .frame(width: size.width, height: size.height)
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Theme.tileBackground, in: shape)
        .clipShape(shape)
        .artworkIgnoresInvertColors()
        .overlay {
            shape.strokeBorder(Theme.surfaceStroke)
        }
    }
}

/// One channel in a list. Tapping plays it; swipe right to play, left for favorite and the channel's guide.
struct ChannelListRow: View {

    static let logoSize = CGSize(width: 76, height: 50)
    static let posterSize = CGSize(width: 46, height: 69)

    let item: ChannelItem
    /// Second line (group, playlist); nil shows nothing.
    var subtitle: String?
    var showsNumber = true
    /// Extra context menu entries.
    var extraActions: [ChannelCardAction] = []
    /// An episode stands for its series (a `SeriesListRow` to the series page), as in a category's list; false
    /// shows the episode itself (the history).
    var presentsSeries = true

    @Environment(ChannelLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(EPGStore.self) private var epg: EPGStore?
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sourceID = UUID().uuidString

    var body: some View {
        if presentsSeries, let series = item.seriesItem {
            SeriesListRow(series: series, subtitle: subtitle)
        } else {
            channelRow
        }
    }

    private var channelRow: some View {
        let isFavorite = library.isFavorite(item)
        return Button {
            playChannel(item, from: sourceID)
        } label: {
            Group {
                if dynamicTypeSize.prefersStackedLayout {
                    // Accessibility sizes: the artwork on a row of its own, the text below with the whole width.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            number
                            artwork
                            Spacer(minLength: 0)
                            playGlyph
                        }
                        details(isFavorite: isFavorite)
                    }
                } else {
                    HStack(spacing: 12) {
                        number
                        artwork
                        details(isFavorite: isFavorite)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        playGlyph
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
            .animation(.snappy, value: isFavorite)
        }
        .buttonStyle(.plain)
        .rowHoverEffect()
        .contextMenu {
            ChannelContextMenu(item: item, isFavorite: isFavorite, extraActions: extraActions)
        }
        .channelDraggable(item)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Play", systemImage: "play.fill") {
                playChannel(item, from: sourceID)
            }
            .tint(Theme.accentFill)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if item.url != nil {
                Button(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "star.slash.fill" : "star.fill") {
                    library.toggleFavorite(item)
                }
                .tint(Theme.favoriteFill)
            }
            if item.kind == .live, epg?.hasGuide == true {
                Button("Guide", systemImage: "calendar.day.timeline.left") {
                    navigation.scheduleChannel = item
                }
                .tint(Theme.cyanFill)
            }
        }
        // One element: "Channel 3, Sky Sport F1, Favorite, Sport, On now: …", activated to play.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(item.kind == .live ? "Plays the channel" : "Plays the video")
        .channelAccessibilityActions(item, isFavorite: isFavorite)
    }

    @ViewBuilder
    private var number: some View {
        if showsNumber, let number = item.number {
            ChannelNumberLabel(number: number)
        }
    }

    private var artwork: some View {
        ChannelLogoTile(item: item, size: item.kind.usesPosterArtwork ? Self.posterSize : Self.logoSize, cornerRadius: 10)
            .playerTransitionSource(id: sourceID, cornerRadius: 10)
            // The name follows as text.
            .accessibilityHidden(true)
    }

    private var playGlyph: some View {
        Image(systemName: "play.circle.fill")
            .font(.title2)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
    }

    private func details(isFavorite: Bool) -> some View {
        let stacked = dynamicTypeSize.prefersStackedLayout
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // An episode: its series, then its number and title on the next line.
                Text(item.series?.seriesTitle ?? item.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(stacked ? 4 : 1)
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.favorite)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel(ChannelAccessibility.favoriteState)
                }
                if item.kind != .live {
                    DownloadInlineIndicator(item: item)
                }
            }
            if let episode = item.series {
                Text(TextParts.line([EpisodeFormat.code(episode), episode.episodeTitle]))
                    .font(.caption.weight(.medium))
                    .lineLimit(stacked ? 3 : 1)
                    .accessibilityLabel(Text(TextParts.spoken([EpisodeFormat.spokenCode(episode), episode.episodeTitle])))
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(stacked ? 3 : 1)
            }
            if item.kind == .live {
                RowProgrammeInfo(item: item)
            } else {
                WatchProgressLine(item: item)
            }
        }
    }
}

/// The channel number in a fixed-width column, so names line up.
struct ChannelNumberLabel: View {
    let number: Int

    var body: some View {
        Text(number, format: .number.grouping(.never))
            .font(.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(minWidth: 30, alignment: .trailing)
            .accessibilityLabel(Text("Channel \(number.formatted(.number.grouping(.never)))", comment: "VoiceOver: the channel number of the playlist, as in 'Channel 12'."))
    }
}

/// LIVE, the programme on air with its progress and time left, and what comes next. Empty without a guide.
struct RowProgrammeInfo: View {
    let item: ChannelItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NowNextReader(item: item) { nowNext in
            if let nowNext {
                TimelineView(.everyMinute) { context in
                    content(nowNext, now: context.date)
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func content(_ nowNext: NowNext, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let current = nowNext.current, current.isOnAir(at: now) {
                HStack(spacing: 6) {
                    LiveBadge(compact: true)
                    Text(current.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 1)
                }
                HStack(spacing: 8) {
                    ProgrammeProgressBar(progress: current.progress(at: now), tint: Theme.live, height: 3)
                        .frame(maxWidth: 140)
                    Text(GuideFormat.remaining(current, at: now))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            if let next = nowNext.next {
                Text(TextParts.line([GuideFormat.next(at: next.start), next.title]))
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(nowNext, now: now))
    }

    private func accessibilityLabel(_ nowNext: NowNext, now: Date) -> String {
        var parts: [String] = []
        if let current = nowNext.current, current.isOnAir(at: now) {
            parts.append(String(localized: "On now: \(current.title), \(GuideFormat.remaining(current, at: now))"))
        }
        if let next = nowNext.next {
            parts.append(String(localized: "Next at \(GuideFormat.time(next.start)): \(next.title)"))
        }
        return TextParts.sentences(parts)
    }
}

/// How far a movie or episode was watched: a progress bar and the time left. Empty when never started.
struct WatchProgressLine: View {
    let item: ChannelItem

    @Environment(ChannelLibrary.self) private var library

    var body: some View {
        if let progress = library.watchProgress(for: item) {
            HStack(spacing: 8) {
                ProgrammeProgressBar(progress: progress.fraction, tint: Theme.accent, height: 3)
                    .frame(maxWidth: 120)
                Text(WatchProgressFormat.remaining(progress))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WatchProgressFormat.remaining(progress))
        }
    }
}

enum WatchProgressFormat {
    /// "1 hr, 12 min left".
    static func remaining(_ progress: WatchProgress) -> String {
        let value = Duration.seconds(max(60, progress.remaining)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return String(localized: "\(value) left")
    }
}

#Preview("Rows") {
    NavigationStack {
        List {
            ForEach(PreviewSampleData.sampleItems) { item in
                ChannelListRow(item: item, subtitle: item.groupName)
            }
        }
    }
    .fluxoPreviewEnvironment(GuidePreviewData.container)
}
