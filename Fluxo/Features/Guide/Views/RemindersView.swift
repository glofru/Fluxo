//
//  RemindersView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// The programmes the user asked to be reminded of, soonest first: watch the channel, or delete the reminder.
struct RemindersView: View {

    @Query(EPGQueries.reminders()) private var reminders: [ProgrammeReminder]
    @Environment(EPGStore.self) private var epg
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmsDeleteAll = false

    var body: some View {
        content
            .navigationTitle("Reminders")
            .inlineNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
                if !reminders.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete All", systemImage: "trash", role: .destructive) {
                            confirmsDeleteAll = true
                        }
                    }
                }
            }
            .confirmationDialog("Delete all reminders?", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
                Button("Delete All Reminders", role: .destructive) {
                    epg.reminders.cancelAll()
                }
            }
            .task {
                await epg.reminders.refreshAuthorization()
            }
    }

    @ViewBuilder
    private var content: some View {
        // Reminders of programmes that ended stay in the store for a while (see `ReminderCenter`), not here.
        if !reminders.contains(where: { $0.stop > .now }) {
            ContentUnavailableView(
                "No Reminders",
                systemImage: "bell",
                description: Text("Open a programme in the guide and choose Remind Me to get a notification before it starts.")
            )
        } else {
            TimelineView(.everyMinute) { context in
                let upcoming = reminders.filter { $0.stop > context.date }
                List {
                    if epg.reminders.authorization == .denied {
                        notificationsOffBanner
                    }
                    Section {
                        ForEach(upcoming) { reminder in
                            ReminderRow(reminder: reminder, now: context.date) {
                                dismiss()
                                playChannel(reminder.channel)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                epg.reminders.cancel(key: upcoming[index].key)
                            }
                        }
                    } footer: {
                        Text(leadDescription)
                    }
                }
                .glassSheetContentBackground()
            }
        }
    }

    private var notificationsOffBanner: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications are off")
                        .font(.headline)
                    Text("Reminders cannot alert you until you allow notifications for Fluxo.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
            } icon: {
                Image(systemName: "bell.slash.fill")
                    .foregroundStyle(Theme.warning)
            }
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    openURL(url)
                }
            }
            #endif
        }
    }

    private var leadDescription: String {
        let minutes = ReminderCenter.leadMinutes
        return minutes == 0
            ? String(localized: "You get a notification when the programme starts. Tap it to watch.")
            : String(localized: "You get a notification \(minutes) minutes before the programme starts. Tap it to watch.")
    }
}

private struct ReminderRow: View {
    let reminder: ProgrammeReminder
    let now: Date
    let onWatch: () -> Void

    @Environment(EPGStore.self) private var epg

    var body: some View {
        let isOnAir = reminder.start <= now && now < reminder.stop
        HStack(spacing: 12) {
            LogoImage(source: reminder.channelLogo, size: CGSize(width: 48, height: 32)) { _ in
                Image(systemName: "tv")
                    .foregroundStyle(Theme.secondaryText)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(TextParts.line([
                    reminder.channelName ?? String(localized: "Channel", comment: "Stands in for the name of a reminder's channel when it is unknown."),
                    GuideFormat.dayAndTime(at: reminder.start),
                ]))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                if isOnAir {
                    Text("On now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.guideNow)
                } else if reminder.start > now {
                    Text(reminder.start, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 8)
            Button(action: onWatch) {
                Image(systemName: "play.fill")
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel(reminder.channelName.map { Text("Watch \($0)", comment: "VoiceOver label of the button that plays a reminder's channel; the placeholder is the channel name.") } ?? Text("Watch the channel", comment: "VoiceOver label of the button that plays a reminder's channel when its name is unknown."))
        }
        .accessibilityElement(children: .combine)
        .rowSwipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                epg.reminders.cancel(key: reminder.key)
            }
        }
    }
}

#Preview {
    NavigationStack {
        RemindersView()
    }
    .fluxoPreviewEnvironment(GuidePreviewData.container)
}
