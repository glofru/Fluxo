//
//  ProgrammeDetailView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftUI

/// A programme: artwork, title, episode, channel, time and progress, categories and description, with Watch
/// and Remind Me, and what follows on the same channel.
struct ProgrammeDetailView: View {

    /// The tallest the artwork gets: a 16:9 banner as wide as the content, lower in a short window (iPhone
    /// landscape) so that the title stays in view.
    static let artworkMaxHeight: CGFloat = 300
    static let compactArtworkMaxHeight: CGFloat = 150
    /// The widest the content gets (readable lines on iPad and Mac).
    static let readableWidth: CGFloat = 640

    let programme: GuideProgramme
    let channel: ChannelItem
    let ref: GuideChannelRef?
    /// Closes the inspector (iPad Guide); nil when shown as a sheet, which dismisses itself.
    var onClose: (() -> Void)?

    @Environment(EPGStore.self) private var epg
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var upNext: [GuideProgramme] = []
    @State private var reminderToggles = 0

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        artwork
                        header(now: context.date)
                        actions(now: context.date)
                        if !programme.categories.isEmpty {
                            categories
                        }
                        // A short Apple Intelligence summary of a long description (nothing otherwise).
                        ProgrammeSummaryView(programme: programme)
                        if !programme.summary.isEmpty {
                            Text(programme.summary)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !upNext.isEmpty {
                            upNextSection(now: context.date)
                        }
                    }
                    .padding()
                    .frame(maxWidth: Self.readableWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            // The title is the first thing in the content: the bar names the channel.
            .navigationTitle(channel.displayName)
            .inlineNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        close()
                    }
                }
            }
            .glassSheetContentBackground()
        }
        .mediumAndLargeDetentsAdaptingToTextSize()
        .task(id: ref) {
            guard let ref else {
                return
            }
            upNext = await epg.upcoming(for: ref, from: programme.stop, limit: 4).filter { $0.start >= programme.stop }
        }
        .alert("Notifications Are Off", isPresented: permissionHint) {
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    openURL(url)
                }
            }
            #endif
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow notifications for Fluxo in Settings to get a reminder before a programme starts.")
        }
        .sensoryFeedback(.success, trigger: reminderToggles)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var permissionHint: Binding<Bool> {
        Binding(get: { epg.reminders.isShowingPermissionHint }, set: { epg.reminders.isShowingPermissionHint = $0 })
    }

    // MARK: - Sections

    /// The programme's image, whatever its size and shape: the banner takes the width of the content and never
    /// more (a huge or very wide image used to widen the whole sheet, pushing the text off both edges).
    @ViewBuilder
    private var artwork: some View {
        if let icon = programme.icon {
            ArtworkBanner(source: icon, aspectRatio: 16 / 9, maxHeight: artworkMaxHeight) { phase in
                if phase == .loading {
                    Color.artworkPlaceholder.opacity(0.2)
                } else {
                    ArtworkPlaceholder(name: programme.title, kind: .live)
                }
            }
            .clipShape(.rect(cornerRadius: 18, style: .continuous))
            .artworkIgnoresInvertColors()
            .accessibilityHidden(true)
        }
    }

    private var artworkMaxHeight: CGFloat {
        #if os(iOS)
        verticalSizeClass == .compact ? Self.compactArtworkMaxHeight : Self.artworkMaxHeight
        #else
        Self.artworkMaxHeight
        #endif
    }

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(programme.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            if let detail = programme.detailLine {
                Text(detail)
                    .font(.headline)
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 10) {
                LogoImage(source: channel.logo, size: CGSize(width: 40, height: 26)) { _ in
                    Image(systemName: "tv")
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(TextParts.line([GuideFormat.dayAndTime(programme), GuideFormat.duration(programme)]))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            if programme.isOnAir(at: now) {
                HStack(spacing: 10) {
                    ProgrammeProgressBar(progress: programme.progress(at: now), height: 5)
                    Text(GuideFormat.remaining(programme, at: now))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("On now, \(GuideFormat.remaining(programme, at: now))")
            }
        }
    }

    private func actions(now: Date) -> some View {
        let isReminded = epg.reminders.isScheduled(programme)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                watchButton(now: now)
                if ReminderCenter.canRemind(programme, now: now) {
                    reminderButton(isReminded: isReminded)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                watchButton(now: now)
                if ReminderCenter.canRemind(programme, now: now) {
                    reminderButton(isReminded: isReminded)
                }
            }
        }
        .controlSize(.large)
    }

    private func watchButton(now: Date) -> some View {
        Button {
            close()
            playChannel(channel)
        } label: {
            Label(programme.isOnAir(at: now) ? "Watch Now" : "Watch \(channel.displayName)", systemImage: "play.fill")
                .lineLimit(1)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accentFill)
        .disabled(channel.url == nil)
    }

    private func reminderButton(isReminded: Bool) -> some View {
        Button {
            Task {
                await epg.reminders.toggle(programme, on: channel)
                reminderToggles += 1
            }
        } label: {
            Label(isReminded ? "Reminder Set" : "Remind Me", systemImage: isReminded ? "bell.fill" : "bell")
                .contentTransition(.symbolEffect(.replace))
                .lineLimit(1)
        }
        .buttonStyle(.glass)
        .accessibilityHint(isReminded ? "Cancels the reminder" : "Sends a notification \(ReminderCenter.leadMinutes) minutes before it starts")
    }

    private var categories: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(programme.categories, id: \.self) { category in
                    Text(category)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.fill.tertiary, in: .capsule)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Categories: \(TextParts.spoken(programme.categories))")
    }

    private func upNextSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Later on \(channel.displayName)")
                .font(.headline)
            ForEach(upNext) { next in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    // The time above the title at the accessibility text sizes; the bell stays on the side.
                    AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: 12) {
                        GuideTimeColumnText(date: next.start)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.title)
                                .font(.subheadline.weight(.medium))
                            if let detail = next.detailLine {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    if ReminderCenter.canRemind(next, now: now) {
                        let isReminded = epg.reminders.isScheduled(next)
                        Button {
                            Task {
                                await epg.reminders.toggle(next, on: channel)
                                reminderToggles += 1
                            }
                        } label: {
                            Image(systemName: isReminded ? "bell.fill" : "bell")
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 32, height: 32)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel(isReminded ? "Cancel reminder for \(next.title)" : "Remind me of \(next.title)")
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .background(.fill.quinary, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    let channel = PreviewSampleData.sampleItems[0]
    let programme = GuideProgramme(
        sourceID: UUID(),
        channelID: "news",
        start: .now.addingTimeInterval(-900),
        stop: .now.addingTimeInterval(2_700),
        title: "Evening News",
        subtitle: "Headlines",
        summary: "The day's stories from home and abroad, with the weather at the end of the programme.",
        categories: ["News", "Current affairs"],
        icon: nil,
        episode: "S12 E140"
    )
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ProgrammeDetailView(programme: programme, channel: channel, ref: nil)
        }
        .fluxoPreviewEnvironment()
}
