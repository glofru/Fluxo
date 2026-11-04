//
//  IntentSnippets.swift
//  Fluxo
//
//  The views Siri and Shortcuts show with intent results. They are rendered outside the app's view hierarchy,
//  so they take plain values and use no environment objects or remote images.
//

import SwiftUI

/// What a channel shows now and next.
struct NowNextSnippetView: View {

    let channelName: String
    let kind: ChannelContentKind
    let nowNext: NowNext
    var now: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SnippetChannelHeader(name: channelName, kind: kind)
            if let current = nowNext.current {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        LiveBadge(compact: true)
                        Text(GuideFormat.remaining(current, at: now))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Text(current.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let detail = current.detailLine {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    ProgrammeProgressBar(progress: current.progress(at: now), height: 4)
                        .padding(.top, 2)
                }
            }
            if let next = nowNext.next {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(GuideFormat.time(next.start))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text(next.title)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A list of programmes: time, title, channel.
struct ProgrammeListSnippetView: View {

    struct Row: Identifiable {
        let id: String
        let programme: GuideProgramme
        let channelName: String
        var note: String?
    }

    let rows: [Row]
    var now: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows.prefix(6)) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Group {
                        if row.programme.isOnAir(at: now) {
                            LiveBadge(compact: true)
                        } else {
                            Text(GuideFormat.time(row.programme.start))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    .frame(minWidth: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.programme.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text([row.channelName, row.note].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A list of channels, each with a second line (a reason, a group or what it shows now).
struct ChannelListSnippetView: View {

    struct Row: Identifiable {
        let id: String
        let name: String
        let kind: ChannelContentKind
        let detail: String?
    }

    let rows: [Row]
    var showsSparkles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows.prefix(6)) { row in
                HStack(spacing: 10) {
                    ArtworkPlaceholder(name: row.name, kind: row.kind)
                        .frame(width: 40, height: 28)
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let detail = row.detail {
                            Label {
                                Text(detail)
                                    .lineLimit(1)
                            } icon: {
                                if showsSparkles {
                                    Image(systemName: "sparkles")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A channel's name with its generated artwork.
struct SnippetChannelHeader: View {
    let name: String
    let kind: ChannelContentKind

    var body: some View {
        HStack(spacing: 10) {
            ArtworkPlaceholder(name: name, kind: kind)
                .frame(width: 44, height: 30)
                .clipShape(.rect(cornerRadius: 7, style: .continuous))
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
    }
}

/// A one-line confirmation with a symbol (favorite, recording, reminder).
struct ConfirmationSnippetView: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Now and next") {
    let now = Date.now
    NowNextSnippetView(
        channelName: "Sky Sport F1",
        kind: .live,
        nowNext: NowNext(
            current: GuideProgramme(sourceID: UUID(), channelID: "f1", start: now.addingTimeInterval(-1_800), stop: now.addingTimeInterval(1_800), title: "Formula 1 · Qualifying", subtitle: "Monza"),
            next: GuideProgramme(sourceID: UUID(), channelID: "f1", start: now.addingTimeInterval(1_800), stop: now.addingTimeInterval(5_400), title: "Paddock Live")
        )
    )
}

#Preview("Channels") {
    ChannelListSnippetView(rows: [
        .init(id: "1", name: "Sky Sport F1", kind: .live, detail: "Qualifying is on, you follow F1"),
        .init(id: "2", name: "Rai 1", kind: .live, detail: "The evening news starts soon"),
        .init(id: "3", name: "Dune", kind: .movie, detail: "Science fiction for tonight"),
    ], showsSparkles: true)
}
