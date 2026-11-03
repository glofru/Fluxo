//
//  OnNowRow.swift
//  Fluxo
//
//  "On Now": what the user's channels (favorites, then recently watched, then any channel with a guide) are
//  showing right now, from the TV guide, as large cards with the programme, its time and progress.
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

    static func load(candidates: [ChannelItem], epg: EPGStore, limit: Int, now: Date = .now) async -> [OnNowEntry] {
        var entries: [OnNowEntry] = []
        var seen: Set<String> = []
        for item in candidates where item.kind == .live {
            guard entries.count < limit, !Task.isCancelled else {
                break
            }
            let key = item.bookmarkKey ?? item.id.uuidString
            guard seen.insert(key).inserted else {
                continue
            }
            if let current = await epg.nowNext(for: item, at: now)?.current, current.isOnAir(at: now) {
                entries.append(OnNowEntry(item: item, programme: current))
            }
        }
        return entries
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
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .accessibilityHidden(true)
                        }
                        .font(.subheadline)
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
        .task(id: LoadKey(importIDs: scope.importIDs, revision: epg.revision)) {
            while !Task.isCancelled {
                guard epg.hasGuide else {
                    entries = []
                    return
                }
                let loaded = await OnNowLoader.load(candidates: candidates(), epg: epg, limit: Self.limit)
                var found = loaded
                if found.count < 6 {
                    // Not enough of the user's own channels on air: add channels of the scope that have a guide.
                    let more = await epg.guideChannels(importIDs: scope.importIDs).prefix(60).map(\.item)
                    found = await OnNowLoader.load(candidates: loaded.map(\.item) + more, epg: epg, limit: Self.limit)
                }
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

    private struct LoadKey: Hashable {
        let importIDs: [UUID]
        let revision: Int
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
    @State private var sourceID = UUID().uuidString

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        let item = entry.item
        let programme = entry.programme
        let height = (width * OnNowCard.size.height / OnNowCard.size.width).rounded()
        Button {
            playChannel(item, from: sourceID)
        } label: {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ChannelLogoTile(item: item, size: CGSize(width: 46, height: 30), cornerRadius: 7)
                        Text(item.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        LiveBadge(compact: true)
                    }

                    Spacer(minLength: 0)

                    Text(programme.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(GuideFormat.timeRange(programme))
                        Text("·")
                        Text(GuideFormat.remaining(programme, at: context.date))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)

                    StreamProgressBar(progress: programme.progress(at: context.date))
                }
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: width, height: height, alignment: .topLeading)
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
        .accessibilityLabel(Text("\(programme.title), on \(item.displayName), \(GuideFormat.timeRange(programme))"))
        .accessibilityHint("Plays the channel")
        .accessibilityAddTraits(.isButton)
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
