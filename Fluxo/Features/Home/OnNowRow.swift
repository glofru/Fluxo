//
//  OnNowRow.swift
//  Fluxo
//
//  "On Now": what the user's channels (favorites, then recently watched, then any channel with a guide) are
//  showing right now, from the TV guide, as large cards with the programme, its time and progress. Adult channels and
//  programmes are left out (`MatureContentFilter`).
//

import SwiftData
import SwiftUI

/// A live channel and the programme it is showing.
struct OnNowEntry: Identifiable, Hashable, Sendable {
    let item: ChannelItem
    let programme: GuideProgramme

    var id: String {
        item.bookmarkKey ?? item.id.uuidString
    }
}

/// Finds the channels of `candidates` that have a programme on air. Candidates are tried in order and
/// duplicates (the same stream) are skipped; at most `limit` entries are returned.
@MainActor
enum OnNowLoader {

    /// `filter` leaves out adult channels and programmes (`MatureContentFilter`).
    static func load(candidates: [ChannelItem], epg: EPGStore, limit: Int, filter: MatureContentFilter = .inactive, now: Date = .now) async -> [OnNowEntry] {
        var entries: [OnNowEntry] = []
        var seen: Set<String> = []
        for item in candidates where item.kind == .live && filter.allows(item) {
            guard entries.count < limit, !Task.isCancelled else {
                break
            }
            let key = item.bookmarkKey ?? item.id.uuidString
            guard seen.insert(key).inserted else {
                continue
            }
            if let current = await epg.nowNext(for: item, at: now)?.current, current.isOnAir(at: now), filter.allows(programme: current, on: item) {
                entries.append(OnNowEntry(item: item, programme: current))
            }
        }
        return entries
    }

    /// The On Now shelf of Home, the Apple TV Home and the Top Shelf: what the viewer's own live channels (`own`:
    /// favorites, then the history) show, topped up with other channels of the scope that have a guide when fewer than
    /// `topUpBelow` are on air. Adult content is left out unless the scope has nothing else.
    static func loadShelf(own: [ChannelItem], importIDs: [UUID], epg: EPGStore, container: ModelContainer, limit: Int, topUpBelow: Int, now: Date = .now) async -> [OnNowEntry] {
        let filter = MatureContentFilter.forScope(importIDs: importIDs, container: container)
        let loaded = await load(candidates: own, epg: epg, limit: limit, filter: filter, now: now)
        guard loaded.count < topUpBelow, !Task.isCancelled else {
            return loaded
        }
        let more = await epg.guideChannels(importIDs: importIDs).prefix(60).map(\.item)
        return await load(candidates: loaded.map(\.item) + more, epg: epg, limit: limit, filter: filter, now: now)
    }

    /// When the list changes next: the first of the programmes to end (at most 15 minutes away).
    static func nextChange(of entries: [OnNowEntry], now: Date = .now) -> Date {
        let soonest = entries.map(\.programme.stop).min() ?? now.addingTimeInterval(900)
        return min(soonest, now.addingTimeInterval(900))
    }
}

/// The Home "On Now" row. Hidden without a guide or when nothing of the user's is on air.
struct OnNowRow: View {

    static let limit = 12

    let scope: LibraryScope

    @Environment(EPGStore.self) private var epg
    @Environment(\.modelContext) private var modelContext
    @State private var entries: [OnNowEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !entries.isEmpty {
                HomeSectionHeader(title: String(localized: "On Now"), subtitle: String(localized: "From the TV guide"), systemImage: "dot.radiowaves.left.and.right") {
                    Button {
                        navigation.show(.guide)
                    } label: {
                        HStack(spacing: 4) {
                            Text("TV Guide")
                            Image(systemName: "chevron.forward")
                                .font(.caption.bold())
                                .accessibilityHidden(true)
                        }
                        .font(.subheadline)
                        .accessibilityButtonShape()
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                CardRow {
                    ForEach(entries) { entry in
                        OnNowCard(entry: entry)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth, value: entries.map(\.id))
        .task(id: LoadKey(importIDs: scope.importIDs, revision: epg.revision, hidesAdultContent: hidesAdultContent)) {
            while !Task.isCancelled {
                guard epg.hasGuide else {
                    entries = []
                    return
                }
                // Not enough of the user's own channels on air: channels of the scope that have a guide are added.
                let found = await OnNowLoader.loadShelf(own: candidates(), importIDs: scope.importIDs, epg: epg, container: modelContext.container, limit: Self.limit, topUpBelow: 6)
                guard !Task.isCancelled else {
                    return
                }
                if found != entries {
                    entries = found
                }
                let wake = OnNowLoader.nextChange(of: found)
                try? await Task.sleep(for: .seconds(max(30, wake.timeIntervalSinceNow + 1)))
            }
        }
    }

    @Environment(AppNavigation.self) private var navigation
    @AppStorage(MatureContent.hidesAdultContentKey) private var hidesAdultContent = MatureContent.hidesAdultContentByDefault

    private struct LoadKey: Hashable {
        let importIDs: [UUID]
        let revision: Int
        let hidesAdultContent: Bool
    }

    /// Favorites first, then the watch history, of the scope.
    private func candidates() -> [ChannelItem] {
        let filter = scope.bookmarkFilter
        let favorites = (try? modelContext.fetch(HomeQueries.favorites(playlistIDs: filter, limit: 40))) ?? []
        let recents = (try? modelContext.fetch(HomeQueries.recents(playlistIDs: filter, limit: 40))) ?? []
        return (favorites + recents).map(ChannelItem.init).filter { $0.kind == .live }
    }
}

/// A large card of a programme on air: its artwork (or the channel's blurred logo), the channel, the title,
/// the time and the progress. Tapping it plays the channel.
struct OnNowCard: View {

    static let size = CGSize(width: 288, height: 168)
    static let backdropDecodeSize = CGSize(width: 24, height: 24)

    let entry: OnNowEntry
    var width: CGFloat = OnNowCard.size.width

    @Environment(\.playChannel) private var playChannel
    @Environment(ChannelLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sourceID = UUID().uuidString
    private var scale = CardScale(maximum: 1.15)

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        let item = entry.item
        let programme = entry.programme
        let isFavorite = library.isFavorite(item)
        // Standard cards grow a little with the text size (grids pass their own width); the height then follows
        // the text.
        let cardWidth = width == OnNowCard.size.width ? scale.scaled(width) : width
        let height = (cardWidth * OnNowCard.size.height / OnNowCard.size.width).rounded()
        let lines = { (standard: Int) in CardTextMetrics.titleLineLimit(standard, at: dynamicTypeSize) }
        Button {
            playChannel(item, from: sourceID)
        } label: {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 6) {
                    if dynamicTypeSize.prefersStackedLayout {
                        // The channel name under its logo and LIVE, with the card's whole width.
                        HStack(spacing: 8) {
                            ChannelLogoTile(item: item, size: CGSize(width: 46, height: 30), cornerRadius: 7)
                            Spacer(minLength: 4)
                            LiveBadge(compact: true)
                        }
                        Text(item.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(lines(1))
                    } else {
                        HStack(spacing: 8) {
                            ChannelLogoTile(item: item, size: CGSize(width: 46, height: 30), cornerRadius: 7)
                            Text(item.displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            LiveBadge(compact: true)
                        }
                    }

                    Spacer(minLength: 0)

                    Text(programme.title)
                        .font(.headline)
                        .lineLimit(lines(2))
                        .multilineTextAlignment(.leading)
                    AdaptiveStack(spacing: 6) {
                        Text(GuideFormat.timeRange(programme))
                        if !dynamicTypeSize.prefersStackedLayout {
                            Text("·")
                        }
                        Text(GuideFormat.remaining(programme, at: context.date))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(lines(1))

                    StreamProgressBar(progress: programme.progress(at: context.date))
                }
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: cardWidth, alignment: .topLeading)
            .frame(minHeight: height, alignment: .topLeading)
            .background {
                backdrop
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.1))
            }
            .contentShape(shape)
            .playerTransitionSource(id: sourceID, cornerRadius: 22)
        }
        .buttonStyle(CardButtonStyle())
        .cardHoverEffect()
        .contextMenu {
            ChannelContextMenu(item: item, isFavorite: library.isFavorite(item))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel(isFavorite: isFavorite)))
        .accessibilityHint("Plays the channel")
        .accessibilityAddTraits(.isButton)
        .channelAccessibilityActions(item, isFavorite: isFavorite)
    }

    private func accessibilityLabel(isFavorite: Bool) -> String {
        let programme = entry.programme
        var parts = [
            String(localized: "\(programme.title), on \(entry.item.displayName)"),
            GuideFormat.timeRange(programme),
            GuideFormat.remaining(programme, at: .now),
        ]
        if isFavorite {
            parts.append(ChannelAccessibility.favoriteState)
        }
        return TextParts.spoken(parts)
    }

    /// The programme's own image when the guide has one, otherwise the channel logo decoded tiny and blurred,
    /// under a scrim that keeps the white text readable.
    private var backdrop: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.brandGradient
                if let icon = entry.programme.icon {
                    LogoImage(source: icon, size: proxy.size, contentMode: .fill) { _ in
                        blurredLogo(in: proxy.size)
                    }
                    .artworkIgnoresInvertColors()
                } else {
                    blurredLogo(in: proxy.size)
                }
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.15), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
        }
        .accessibilityHidden(true)
    }

    private func blurredLogo(in size: CGSize) -> some View {
        LogoImage(source: entry.item.logo, size: Self.backdropDecodeSize, contentMode: .fill) { _ in
            Color.clear
        }
        .scaleEffect(max(size.width, size.height) / Self.backdropDecodeSize.width * 1.4)
        .blur(radius: 22)
        .frame(width: size.width, height: size.height)
        .opacity(0.9)
    }
}

/// The progress of a programme on air, in the colors of the three streams of the icon.
struct StreamProgressBar: View {
    let progress: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                Capsule()
                    .fill(Theme.streamGradient)
                    .frame(width: max(height, proxy.size.width * progress))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

#Preview("On now") {
    let item = PreviewSampleData.sampleItems[0]
    let programme = GuideProgramme(sourceID: UUID(), channelID: "a", start: .now.addingTimeInterval(-1_200), stop: .now.addingTimeInterval(2_400), title: "Evening News with a long title")
    ScrollView(.horizontal) {
        HStack {
            OnNowCard(entry: OnNowEntry(item: item, programme: programme))
            OnNowCard(entry: OnNowEntry(item: PreviewSampleData.sampleItems[1], programme: programme))
        }
        .padding()
    }
    .fluxoPreviewEnvironment(GuidePreviewData.container)
}
