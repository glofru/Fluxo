//
//  TVProgrammeScreen.swift
//  Fluxo
//
//  A programme of Apple TV's guide (TVGuideScreen): Watch, Record, Remind Me, and what follows on the channel.
//

import SwiftData
import SwiftUI

#if os(tvOS)
// MARK: - Programme

/// A programme that follows on the channel: its time and title. Selecting it sets a reminder (or removes it).
private struct TVUpNextRow: View {
    let programme: GuideProgramme
    let channel: ChannelItem
    let now: Date
    /// Plays the channel: what selecting the programme on air does.
    let onWatch: () -> Void

    @Environment(EPGStore.self) private var epg

    var body: some View {
        let isScheduled = epg.reminders.isScheduled(programme)
        let canRemind = ReminderCenter.canRemind(programme, now: now)
        let isOnAir = programme.isOnAir(at: now)
        let isPast = programme.stop <= now
        Button {
            if isOnAir {
                onWatch()
            } else {
                Task {
                    await epg.reminders.toggle(programme, on: channel)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(GuideFormat.time(programme.start))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(programme.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if isOnAir {
                    LiveBadge()
                } else if isScheduled || canRemind {
                    Image(systemName: isScheduled ? "bell.fill" : "bell")
                        .font(.callout)
                        .foregroundStyle(isScheduled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(width: 640, alignment: .leading)
        }
        .buttonStyle(TVGuideCellStyle(kind: .programme(isOnAir: isOnAir, isPast: isPast)))
        // A programme on air plays the channel; one still to come sets or removes its reminder; one that ended (while
        // the page was open) does nothing.
        .disabled(!isOnAir && !canRemind && !isScheduled)
        .accessibilityLabel(Text(TextParts.spoken([GuideFormat.time(programme.start), programme.title, isOnAir ? String(localized: "On Now") : nil, isScheduled ? String(localized: "TV.programme.reminderSet", defaultValue: "Reminder Set", comment: "Apple TV, a programme: the reminder is set (selecting it removes it).") : nil])))
        .accessibilityHint(Text(isOnAir ? String(localized: TVText.playsHint(for: channel)) : isScheduled ? String(localized: "TV.programme.removeReminderHint", defaultValue: "Removes the reminder", comment: "VoiceOver hint of a programme that follows, on Apple TV, when a reminder is set for it.") : String(localized: "TV.programme.remindHint", defaultValue: "Reminds you before it starts", comment: "VoiceOver hint of a programme that follows, on Apple TV: selecting it sets a reminder.")))
    }
}

/// The recording red of a symbol; when inactive, the symbol keeps the style the button gives its label.
private struct TVRecordingTint: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.foregroundStyle(Theme.recording)
        } else {
            content
        }
    }
}

/// A programme, full screen: its image (or the channel's), the channel, the title, when it airs and how far it is,
/// the categories and the description, with Watch, Record (on air, on a channel the engine plays) or Remind Me, and
/// what follows on the channel. Record plays the channel and starts recording it as soon as the stream is open (the
/// player shows REC); while the channel records (in Picture in Picture), the sheet shows REC and Stop Recording.
struct TVProgrammeScreen: View {
    let programme: GuideProgramme
    let channel: ChannelItem
    let ref: GuideChannelRef?

    @Environment(EPGStore.self) private var epg
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var upNext: [GuideProgramme] = []
    @FocusState private var isWatchFocused: Bool
    @FocusState private var isRecordFocused: Bool
    /// What Watch or Record does once the sheet has gone (`afterDismissal(_:)`).
    @State private var pending = PendingAction()

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let isOnAir = programme.isOnAir(at: now)
            let isRecording = isOnAir && playChannel.isRecording(channel)
            HStack(alignment: .top, spacing: 70) {
                VStack(alignment: .leading, spacing: 30) {
                    artwork
                    if !upNext.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            // After a programme that ended, what the channel shows from now on (the one on air first).
                            Group {
                                if programme.stop <= now {
                                    Text("Later on \(channel.displayName)", comment: "Text — TV programme details. The placeholder is the channel name.")
                                } else {
                                    Text("Up Next on \(channel.displayName)", comment: "Apple TV, a programme of the TV guide shown full screen: header of the programmes that follow on the channel; the placeholder is the channel name.")
                                }
                            }
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(upNext) { next in
                                TVUpNextRow(programme: next, channel: channel, now: now) {
                                    afterDismissal {
                                        playChannel(channel)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: 640, alignment: .leading)

                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        if isOnAir {
                            LiveBadge()
                        }
                        if isRecording {
                            RecordingBadge(duration: playChannel.recordingDuration)
                        }
                        Text(TextParts.line([channel.displayName, channel.number.map { String(localized: "Channel \($0.formatted(.number.grouping(.never)))", comment: "The channel number of the playlist, as in 'Channel 12'.") }]))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    Text(programme.title)
                        .font(.title.bold())
                        .lineLimit(3)
                        .accessibilityAddTraits(.isHeader)
                    if let detail = programme.detailLine {
                        Text(detail)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Text(TextParts.line([GuideFormat.dayAndTime(programme), GuideFormat.duration(programme)]))
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                    if isOnAir {
                        HStack(spacing: 20) {
                            ProgrammeProgressBar(progress: programme.progress(at: now), tint: Theme.live, height: 8)
                                .frame(width: 420)
                            Text(GuideFormat.remaining(programme, at: now))
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if !programme.categories.isEmpty {
                        Text(TextParts.line(programme.categories))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                    }
                    if !programme.summary.isEmpty {
                        Text(programme.summary)
                            .font(.body)
                            .lineLimit(8)
                            .frame(maxWidth: 1_000, alignment: .leading)
                    }
                    actions(now: now, isOnAir: isOnAir, isRecording: isRecording)
                        .padding(.top, 16)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TVLayout.margin + 20)
            .padding(.vertical, TVLayout.verticalMargin + 30)
        }
        .defaultFocus($isWatchFocused, true)
        .onDisappear {
            pending.run()
        }
        .task(id: ref) {
            guard let ref else {
                return
            }
            // What follows the programme; for one that ended, what has not ended yet (from the one on air).
            let from = max(programme.stop, .now)
            upNext = await epg.upcoming(for: ref, from: from, limit: 4).filter { $0.start >= programme.stop && $0.stop > from }
        }
    }

    /// Closes the sheet, then plays: the player's cover opens once the focus is back on the programme in the guide
    /// (or the result in Search), so Menu from the player returns there. Presented while the sheet still went away,
    /// the cover would give the focus back to the sheet's button, which is gone, and tvOS would fall back to the
    /// tab bar (Home).
    private func afterDismissal(_ action: @escaping @MainActor () -> Void) {
        pending.action = action
        dismiss()
    }

    @MainActor
    private final class PendingAction {
        var action: (@MainActor () -> Void)?

        func run() {
            let action = action
            self.action = nil
            action?()
        }
    }

    private var artwork: some View {
        let size = CGSize(width: 640, height: 360)
        return ZStack {
            if let icon = programme.icon {
                // The programme's image on an opaque ground (one with transparent parts would show the channel's logo
                // through it); the channel's artwork while it loads or when it cannot be loaded.
                LogoImage(source: icon, size: size, contentMode: .fill) { _ in
                    TVLandscapeArtwork(item: channel, size: size)
                }
                .background(Color.tvPageBackground(colorScheme))
            } else {
                TVLandscapeArtwork(item: channel, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .accessibilityHidden(true)
    }

    private func actions(now: Date, isOnAir: Bool, isRecording: Bool) -> some View {
        let reminders = epg.reminders
        let canRemind = ReminderCenter.canRemind(programme, now: now)
        let isScheduled = reminders.isScheduled(programme)
        return GlassEffectContainer(spacing: 24) {
            HStack(spacing: 24) {
                Button {
                    afterDismissal {
                        playChannel(channel)
                    }
                } label: {
                    Label(isOnAir ? String(localized: "Watch Now") : String(localized: "TV.programme.watchChannel", defaultValue: "Watch Channel", comment: "Apple TV, a programme that is not on air: plays its channel."), systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 12)
                }
                .tvActionButton(prominent: true)
                .focused($isWatchFocused)
                .tvDebugFocus("programme-watch", focus: $isWatchFocused)

                if isRecording || (isOnAir && channel.isRecordable) {
                    // One button for both states, so the focus stays on it when the recording stops.
                    Button {
                        if isRecording {
                            playChannel.stopRecording()
                        } else {
                            afterDismissal {
                                playChannel.playAndRecord(channel)
                            }
                        }
                    } label: {
                        Label {
                            Text(isRecording ? String(localized: "Stop Recording") : String(localized: "Record"))
                        } icon: {
                            // Red on the glass; focused, the color of the label (red would not read on the focused
                            // button's fill, violet in light mode).
                            Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                                .modifier(TVRecordingTint(isActive: !isRecordFocused))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .font(.headline)
                        .padding(.horizontal, 8)
                    }
                    .tvActionButton()
                    .focused($isRecordFocused)
                    .tvDebugFocus("programme-record", focus: $isRecordFocused)
                    .accessibilityHint(Text(isRecording
                        ? String(localized: "TV.programme.stopRecordingHint", defaultValue: "Stops recording the channel and saves the recording in Library", comment: "VoiceOver hint of Stop Recording on a programme on Apple TV, while its channel is being recorded.")
                        : String(localized: "TV.programme.recordHint", defaultValue: "Plays the channel and records it. The recording is saved in Library", comment: "VoiceOver hint of Record on a programme on air, on Apple TV.")))
                }

                if canRemind || isScheduled {
                    Button {
                        Task {
                            await reminders.toggle(programme, on: channel)
                        }
                    } label: {
                        Label(isScheduled ? String(localized: "TV.programme.reminderSet", defaultValue: "Reminder Set", comment: "Apple TV, a programme: the reminder is set (selecting it removes it).") : String(localized: "Remind Me"), systemImage: isScheduled ? "bell.fill" : "bell")
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .tvActionButton()
                }
            }
        }
    }
}
#endif
