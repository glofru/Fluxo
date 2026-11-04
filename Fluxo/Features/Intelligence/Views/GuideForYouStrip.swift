//
//  GuideForYouStrip.swift
//  Fluxo
//
//  "For You Tonight" ("For You Today" before the evening) above the guide grid: programmes of the next hours suggested from the viewer's channels,
//  picked and explained by Apple Intelligence on the device when it is available. It can be collapsed to one line.
//

import SwiftUI

struct GuideForYouStrip: View {

    let importIDs: [UUID]
    let onSelect: (GuideSelection) -> Void

    @Environment(FluxoIntelligence.self) private var intelligence: FluxoIntelligence?
    @Environment(EPGStore.self) private var epg
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("guide.forYou.isCollapsed") private var isCollapsed = false

    private var scope: RecommendationScope {
        RecommendationScope(importIDs: importIDs)
    }

    private struct LoadKey: Equatable {
        let scope: RecommendationScope
        let status: IntelligenceStatus?
        let revision: Int
        let isActive: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            if let intelligence, let list = intelligence.recommendations.programmeLists[scope], !list.items.isEmpty {
                content(list: list, isPersonalizing: intelligence.recommendations.personalizingProgrammes.contains(scope))
            } else {
                // Keeps the loading task alive while there is nothing to show.
                Color.clear
                    .frame(height: 0)
                    .accessibilityHidden(true)
            }
        }
        .task(id: LoadKey(scope: scope, status: intelligence?.status, revision: epg.revision, isActive: scenePhase == .active)) {
            guard let intelligence, scenePhase == .active, !importIDs.isEmpty else {
                return
            }
            // Guide refreshes bump the revision in bursts: wait for them to settle.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else {
                return
            }
            await intelligence.recommendations.loadProgrammes(for: scope)
        }
    }

    /// "For You Tonight" from the evening on, "For You Today" before (the suggestions cover the next six hours).
    static func title(at date: Date) -> LocalizedStringKey {
        switch ViewingMoment.part(of: date) {
        case .evening, .night:
            return "For You Tonight"
        case .morning, .afternoon:
            return "For You Today"
        }
    }

    private func content(list: RecommendationList<ProgrammeRecommendation>, isPersonalizing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                    isCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(Self.title(at: .now))
                        .font(.subheadline.weight(.semibold))
                    if isPersonalizing {
                        PersonalizingIndicator()
                    } else if list.isPersonalized {
                        Text("Apple Intelligence")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, HomeLayout.horizontalMargin)
            .accessibilityValue(isCollapsed ? Text("Collapsed") : Text("Expanded"))
            .accessibilityHint(isCollapsed ? "Shows the suggestions" : "Hides the suggestions")

            if !isCollapsed {
                ScrollView(.horizontal) {
                    // At most `ProgrammeRecommender.listSize` cards: no need for a lazy stack. Its ideal height is the
                    // tallest card's, which every card then fills (`maxHeight: .infinity`), so the cards line up
                    // without reserving lines that most titles do not use.
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(list.items) { recommendation in
                            ProgrammeRecommendationCard(recommendation: recommendation, isPersonalized: list.isPersonalized, isCompact: horizontalSizeClass == .compact) {
                                onSelect(GuideSelection(programme: recommendation.programme, channel: recommendation.channel))
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, HomeLayout.horizontalMargin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, horizontalSizeClass == .compact ? 6 : 8)
        // Its natural height: the grid below takes the rest of the screen.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A suggested programme: when, what, where and why.
struct ProgrammeRecommendationCard: View {

    static let width: CGFloat = 236

    let recommendation: ProgrammeRecommendation
    var isPersonalized = false
    /// iPhone: one line of title, so the strip leaves the guide grid most of the screen.
    var isCompact = false
    /// The space a reason may take: two lines, as a card is narrow ("Football on a favorite channel").
    static let reasonLines = 2
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        TimelineView(.everyMinute) { context in
            Button(action: action) {
                card(now: context.date)
            }
            .buttonStyle(CardButtonStyle())
        }
    }

    private func card(now: Date) -> some View {
        let programme = recommendation.programme
        let isOnAir = programme.isOnAir(at: now)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isOnAir {
                    LiveBadge(compact: true)
                    Text(GuideFormat.remaining(programme, at: now))
                } else {
                    Text(GuideFormat.timeRange(programme))
                }
                Spacer(minLength: 4)
                LogoImage(source: recommendation.channel.item.logo, size: CGSize(width: 34, height: 20)) { _ in
                    Color.clear
                }
                .accessibilityHidden(true)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .monospacedDigit()

            Text(programme.title)
                .font(Theme.Typography.cardTitle)
                .lineLimit(isCompact ? 1 : 2)
                .multilineTextAlignment(.leading)
            Text(recommendation.channel.item.displayName)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            // Secondary text (readable on the card in dark mode too), with a tinted icon.
            Label {
                Text(recommendation.reason)
                    .lineLimit(Self.reasonLines)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Theme.secondaryText)
            } icon: {
                Image(systemName: isPersonalized ? "sparkles" : "star")
                    .foregroundStyle(.tint)
            }
            .font(.caption.weight(.medium))

            // Cards of a row share the tallest one's height: the progress bars line up at the bottom.
            Spacer(minLength: 0)
            if isOnAir {
                ProgrammeProgressBar(progress: programme.progress(at: now), height: 3)
                    .padding(.top, 2)
            }
        }
        .padding(isCompact ? 10 : 12)
        .frame(width: Self.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface, in: shape)
        .overlay {
            shape.strokeBorder(Theme.surfaceStroke)
        }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(now: now))
        .accessibilityHint("Shows the programme")
        .accessibilityAddTraits(.isButton)
    }

    private func accessibilityLabel(now: Date) -> String {
        let programme = recommendation.programme
        let time = programme.isOnAir(at: now) ? String(localized: "On now, \(GuideFormat.remaining(programme, at: now))") : GuideFormat.timeRange(programme)
        return [programme.title, recommendation.channel.item.displayName, time, recommendation.reason].joined(separator: ", ")
    }
}

#Preview("Card") {
    let now = Date.now
    let channel = GuideChannel(
        item: ChannelItem(id: UUID(), playlistID: UUID(), name: "Sky Sport F1", logo: nil, url: URL(string: "http://example.invalid/1"), groupName: "Sport", kind: .live),
        ref: GuideChannelRef(sourceID: UUID(), importID: UUID(), channelID: "SkySportF1.it")
    )
    let programme = GuideProgramme(sourceID: channel.ref.sourceID, channelID: "SkySportF1.it", start: now.addingTimeInterval(-1_200), stop: now.addingTimeInterval(3_000), title: "Formula 1 · Qualifying", categories: ["Sport"])
    HStack {
        ProgrammeRecommendationCard(recommendation: ProgrammeRecommendation(programme: programme, channel: channel, reason: "Qualifying is on, you follow F1"), isPersonalized: true) {}
        ProgrammeRecommendationCard(recommendation: ProgrammeRecommendation(programme: programme, channel: channel, reason: "On your favorite channel")) {}
    }
    .padding()
}
