//
//  ForYouRow.swift
//  Fluxo
//
//  The "For You" row of Home: channels suggested from the viewer's history, favorites and the TV guide, chosen
//  and explained by Apple Intelligence on the device when it is available (`RecommendationCenter`).
//

import SwiftData
import SwiftUI

/// The row itself. It only reads the center's state; `forYouRecommendations(scope:)` on the enclosing screen
/// loads it (a task on a row that has nothing to show would never run).
struct ForYouRow: View {

    let scope: LibraryScope

    @Environment(FluxoIntelligence.self) private var intelligence: FluxoIntelligence?

    var body: some View {
        if let intelligence, let list = intelligence.recommendations.channelLists[RecommendationScope(scope)], !list.items.isEmpty {
            let isPersonalizing = intelligence.recommendations.personalizingChannels.contains(RecommendationScope(scope))
            VStack(alignment: .leading, spacing: 10) {
                HomeSectionHeader(title: String(localized: "For You"), subtitle: subtitle(list: list, intelligence: intelligence), systemImage: "sparkles") {
                    if isPersonalizing {
                        PersonalizingIndicator()
                    } else if intelligence.isAvailable {
                        Button {
                            Task {
                                await intelligence.recommendations.loadChannels(for: RecommendationScope(scope), force: true)
                            }
                        } label: {
                            Label("New Suggestions", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                                .font(.subheadline.weight(.semibold))
                                .frame(minWidth: 32, minHeight: 32)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help("New Suggestions")
                    }
                }
                CardRow {
                    ForEach(list.items) { recommendation in
                        ChannelPreview(item: recommendation.item, subtitle: recommendation.reason)
                    }
                }
                .animation(.smooth(duration: 0.35), value: list.items.map(\.id))
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func subtitle(list: RecommendationList<ChannelRecommendation>, intelligence: FluxoIntelligence) -> String {
        if list.isPersonalized {
            return String(localized: "Picked on this device by Apple Intelligence")
        }
        if intelligence.status == .appleIntelligenceOff {
            return String(localized: "Turn on Apple Intelligence for personal picks")
        }
        return String(localized: "Based on what you watch")
    }
}

/// "Personalizing…" with a pulsing sparkle, while the model works.
struct PersonalizingIndicator: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text("Personalizing…")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Loads the "For You" suggestions of `scope`, again when the scope, the model availability or the guide
    /// changes, and when the app comes back to the foreground (the time of day and the history may have changed;
    /// a cached list is reused when nothing did).
    func forYouRecommendations(scope: LibraryScope) -> some View {
        modifier(ForYouLoader(scope: RecommendationScope(scope)))
    }
}

private struct ForYouLoader: ViewModifier {

    let scope: RecommendationScope

    @Environment(FluxoIntelligence.self) private var intelligence: FluxoIntelligence?
    @Environment(EPGStore.self) private var epg: EPGStore?
    @Environment(\.scenePhase) private var scenePhase

    private struct Key: Equatable {
        let scope: RecommendationScope
        let status: IntelligenceStatus?
        let hasGuide: Bool
        let isActive: Bool
    }

    func body(content: Content) -> some View {
        content
            .task(id: Key(scope: scope, status: intelligence?.status, hasGuide: epg?.hasGuide ?? false, isActive: scenePhase == .active)) {
                guard let intelligence, !scope.importIDs.isEmpty, scenePhase == .active else {
                    return
                }
                await intelligence.recommendations.loadChannels(for: scope)
            }
    }
}

#Preview("For You") {
    let container = PreviewSampleData.makeContainer(withSamples: true)
    NavigationStack {
        ScrollView {
            ForYouPreviewHost()
        }
    }
    .fluxoPreviewEnvironment(container)
}

private struct ForYouPreviewHost: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        let playlists = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        let scope = LibraryScope(playlists: playlists, selection: .all)
        ForYouRow(scope: scope)
            .forYouRecommendations(scope: scope)
    }
}
