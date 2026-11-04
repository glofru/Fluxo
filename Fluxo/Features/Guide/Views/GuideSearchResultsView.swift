//
//  GuideSearchResultsView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftUI

/// Programme search: titles, episode titles and descriptions of everything not over yet, on now first, then by
/// day. Runs 250 ms after the last keystroke, off the main actor.
struct GuideSearchResultsView: View {

    let term: String
    let importIDs: [UUID]
    let showsPlaylistNames: Bool
    let playlistNames: [UUID: String]
    let onSelect: (GuideSelection) -> Void

    @Environment(EPGStore.self) private var epg
    @State private var results: [GuideSearchResult]?
    @State private var resultsTerm = ""

    var body: some View {
        Group {
            if let results {
                if results.isEmpty {
                    ContentUnavailableView.search(text: resultsTerm)
                } else {
                    TimelineView(.everyMinute) { context in
                        list(results, now: context.date)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: SearchKey(term: term, importIDs: importIDs, revision: epg.revision)) {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            let found = await epg.searchProgrammes(term, importIDs: importIDs)
            guard !Task.isCancelled else {
                return
            }
            results = found
            resultsTerm = term
        }
    }

    private struct SearchKey: Equatable {
        let term: String
        let importIDs: [UUID]
        let revision: Int
    }

    private func list(_ results: [GuideSearchResult], now: Date) -> some View {
        let onNow = results.filter { $0.programme.isOnAir(at: now) }
        let later = results.filter { !$0.programme.isOnAir(at: now) && $0.programme.stop > now }
        let calendar = Calendar.current
        let days = Dictionary(grouping: later) { calendar.startOfDay(for: $0.programme.start) }
        return List {
            if !onNow.isEmpty {
                Section("On Now") {
                    ForEach(onNow) { result in
                        row(result, now: now)
                    }
                }
            }
            ForEach(days.keys.sorted(), id: \.self) { day in
                Section(GuideFormat.day(day)) {
                    ForEach(days[day] ?? []) { result in
                        row(result, now: now)
                    }
                }
            }
            if results.count >= 150 {
                Section {
                } footer: {
                    Text("Showing the first 150 programmes. Type more to narrow the search.")
                }
            }
        }
    }

    private func row(_ result: GuideSearchResult, now: Date) -> some View {
        GuideSearchRow(result: result, now: now, playlistName: showsPlaylistNames ? playlistNames[result.channel.playlistID] : nil) {
            onSelect(GuideSelection(programme: result.programme, channel: GuideChannel(item: result.channel, ref: result.ref)))
        }
    }
}

private struct GuideSearchRow: View {
    let result: GuideSearchResult
    let now: Date
    let playlistName: String?
    let onSelect: () -> Void

    @Environment(EPGStore.self) private var epg
    @Environment(\.playChannel) private var playChannel

    var body: some View {
        let programme = result.programme
        let isOnAir = programme.isOnAir(at: now)
        let isReminded = epg.reminders.isScheduled(programme)
        Button(action: onSelect) {
            // At the accessibility text sizes the time goes above the title.
            AdaptiveStack(verticalAlignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    GuideTimeColumnText(date: programme.start)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    if isOnAir {
                        Text("LIVE")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Color.guideNow)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(programme.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    if let detail = programme.detailLine {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        LogoImage(source: result.channel.logo, size: CGSize(width: 24, height: 16)) { _ in
                            Color.clear
                        }
                        .accessibilityHidden(true)
                        Text(TextParts.line([result.channel.displayName, playlistName]))
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    if isOnAir {
                        ProgrammeProgressBar(progress: programme.progress(at: now), height: 3)
                            .frame(maxWidth: 160)
                    }
                }
                Spacer(minLength: 4)
                if isReminded {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Reminder set")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Watch \(result.channel.displayName)", systemImage: "play.fill") {
                playChannel(result.channel)
            }
            if ReminderCenter.canRemind(programme, now: now) {
                Button(isReminded ? "Cancel Reminder" : "Remind Me", systemImage: isReminded ? "bell.slash" : "bell") {
                    Task {
                        await epg.reminders.toggle(programme, on: result.channel)
                    }
                }
            }
            // The link of the channel (a programme has none of its own), named so, in its own group.
            if StreamLink(result.channel.url) != nil {
                Divider()
                StreamLinkMenuItems(url: result.channel.url, name: result.channel.displayName, target: .channel)
            }
        }
        .swipeActions(edge: .trailing) {
            if ReminderCenter.canRemind(programme, now: now) {
                Button(isReminded ? "Cancel" : "Remind", systemImage: isReminded ? "bell.slash" : "bell") {
                    Task {
                        await epg.reminders.toggle(programme, on: result.channel)
                    }
                }
                .tint(Theme.accentFill)
            } else {
                Button("Watch", systemImage: "play.fill") {
                    playChannel(result.channel)
                }
                .tint(Theme.liveFill)
            }
        }
    }
}

#Preview {
    NavigationStack {
        GuideSearchResultsView(term: "News", importIDs: [PreviewSampleData.freeviewImportID], showsPlaylistNames: false, playlistNames: [:]) { _ in }
    }
    .fluxoPreviewEnvironment(GuidePreviewData.container)
}
