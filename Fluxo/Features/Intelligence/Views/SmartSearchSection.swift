//
//  SmartSearchSection.swift
//  Fluxo
//
//  The "Smart Results" of Search for natural-language queries: how the query was understood, then matching
//  programmes on the guide, groups and channels (`SmartSearch`).
//

import SwiftUI

/// List sections for a smart search. `results` is nil while the query is being planned and run.
struct SmartSearchSections: View {

    static let programmeRows = 8
    static let channelRows = 10

    let results: SmartSearchResults?
    let isLoading: Bool
    let libraryScope: LibraryScope
    let onSelectProgramme: (GuideSearchResult) -> Void

    var body: some View {
        if isLoading && results == nil {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Understanding your search…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } header: {
                header(isFromModel: false)
            }
        } else if let results, !results.isEmpty {
            Section {
                interpretation(results.plan)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)

                ForEach(results.programmes.prefix(Self.programmeRows)) { result in
                    SmartProgrammeRow(result: result, playlistName: libraryScope.showsPlaylistNames ? libraryScope.playlistNames[result.channel.playlistID] : nil) {
                        onSelectProgramme(result)
                    }
                }

                if !results.groups.isEmpty {
                    groupChips(results.groups)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }

                ForEach(results.channels.prefix(Self.channelRows)) { item in
                    ChannelListRow(item: item, subtitle: subtitle(for: item), showsNumber: false)
                }
            } header: {
                header(isFromModel: results.plan.isFromModel)
            }
        }
    }

    /// Kind, group and (with several playlists) playlist name, as in the regular channel results.
    private func subtitle(for item: ChannelItem) -> String {
        let playlistName = libraryScope.showsPlaylistNames ? libraryScope.playlistNames[item.playlistID] : nil
        return [item.kind.title, item.groupName.isEmpty ? nil : item.groupName, playlistName].compactMap { $0 }.joined(separator: " · ")
    }

    private func header(isFromModel: Bool) -> some View {
        HStack(spacing: 6) {
            Label("Smart Results", systemImage: "sparkles")
            if isFromModel {
                Text("· Apple Intelligence")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The understood query, as chips ("Football", "Tonight").
    @ViewBuilder
    private func interpretation(_ plan: SmartSearchPlan) -> some View {
        let chips = plan.summaryChips
        if !chips.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.accent.opacity(0.14), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, HomeLayout.horizontalMargin)
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Searching for \(chips.joined(separator: ", "))")
        }
    }

    private func groupChips(_ groups: [GroupItem]) -> some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(groups) { group in
                        NavigationLink(value: group.route) {
                            Label("\(group.displayName) · \(group.channelCount.formatted())", systemImage: group.kind.systemImage)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
                .padding(.horizontal, HomeLayout.horizontalMargin)
                .padding(.vertical, 4)
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// A programme found by smart search: time, title, channel; opens the programme.
private struct SmartProgrammeRow: View {

    let result: GuideSearchResult
    let playlistName: String?
    let action: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            let programme = result.programme
            let isOnAir = programme.isOnAir(at: context.date)
            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if isOnAir {
                            LiveBadge(compact: true)
                        } else {
                            GuideTimeColumnText(date: programme.start)
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            if !Calendar.current.isDateInToday(programme.start) {
                                Text(GuideFormat.day(programme.start))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(programme.title)
                            .font(.body.weight(.medium))
                            .lineLimit(2)
                        Text([result.channel.displayName, playlistName].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if isOnAir {
                            ProgrammeProgressBar(progress: programme.progress(at: context.date))
                                .frame(maxWidth: 160)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([
                programme.title,
                result.channel.displayName,
                isOnAir ? String(localized: "On now") : GuideFormat.dayAndTime(programme),
            ].joined(separator: ", "))
            .accessibilityHint("Shows the programme")
            .accessibilityAddTraits(.isButton)
        }
    }
}

#Preview {
    let channel = ChannelItem(id: UUID(), playlistID: UUID(), name: "Sky Sport Calcio", logo: nil, url: URL(string: "http://example.invalid/1"), groupName: "Sport", kind: .live)
    let programme = GuideProgramme(sourceID: UUID(), channelID: "calcio", start: .now.addingTimeInterval(3_600), stop: .now.addingTimeInterval(9_000), title: "Serie A: Inter – Milan")
    var plan = SmartSearchPlan()
    plan.keywords = ["football", "calcio"]
    plan.time = .tonight
    plan.isFromModel = true
    let results = SmartSearchResults(
        query: "football tonight",
        plan: plan,
        channels: [channel],
        groups: [],
        programmes: [GuideSearchResult(programme: programme, channel: channel, ref: GuideChannelRef(sourceID: programme.sourceID, importID: UUID(), channelID: "calcio"))]
    )
    return NavigationStack {
        List {
            SmartSearchSections(results: results, isLoading: false, libraryScope: LibraryScope(playlists: [], selection: .all)) { _ in }
        }
    }
    .fluxoPreviewEnvironment()
}
