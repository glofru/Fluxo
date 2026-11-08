//
//  PlayerChannelGuide.swift
//  Fluxo
//
//  The guide of the playing channel, from the player: a tap on what is on now (the top bar) or Channel Guide in
//  the player's menu shows the channel's schedule without leaving the video: in the side panel of a wide player
//  (iPad in landscape, the Mac), in the other pane of an open foldable, or in a sheet over the video (iPhone,
//  iPad in portrait, narrow windows). The schedule opens at the programme on now; Full Guide closes the player
//  (playback continues) and shows the whole TV guide at that channel.
//

// The touch and pointer player screen (iPhone, iPad, Mac). Apple TV plays in the system's player, whose transport bar the Siri Remote drives (Fluxo/TV).
#if !os(tvOS)
import SwiftUI

// MARK: - Full guide

/// Shows the app's TV guide at a channel (`AppNavigation.showInGuide(_:)`), closing the player first; set by the
/// main window for the player it hosts. Not available in a player window of its own (iPad): its guide is in another
/// window.
struct OpenChannelGuideAction {
    private let handler: (@MainActor (ChannelItem) -> Void)?

    init() {
        handler = nil
    }

    init(_ handler: @escaping @MainActor (ChannelItem) -> Void) {
        self.handler = handler
    }

    var isAvailable: Bool {
        handler != nil
    }

    @MainActor
    func callAsFunction(_ item: ChannelItem) {
        handler?(item)
    }
}

extension EnvironmentValues {
    @Entry var openChannelGuide = OpenChannelGuideAction()
}

/// "Full Guide": the whole TV guide, at this channel.
struct PlayerFullGuideButton: View {
    let item: ChannelItem
    /// Icon only, for the tight header of another channel's schedule in the side panel.
    var iconOnly = false

    static let systemImage = "square.grid.3x3.topleft.filled"

    @Environment(\.openChannelGuide) private var openChannelGuide

    var body: some View {
        if openChannelGuide.isAvailable {
            Button {
                openChannelGuide(item)
            } label: {
                Group {
                    if iconOnly {
                        Image(systemName: Self.systemImage)
                            .frame(width: 32, height: 32)
                    } else {
                        Label("Full Guide", systemImage: Self.systemImage)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel("Full Guide")
            .accessibilityHint("Closes the player and shows this channel in the TV guide")
            .accessibilityIdentifier("player.guide.fullGuide")
            .help("Show this channel in the full TV guide")
        }
    }
}

// MARK: - Sheet

/// The playing channel's schedule over the video, where the player has no room for a panel next to it: iPhone,
/// iPad in portrait, narrow Mac windows. Full Guide (in the toolbar) leaves the player for the app's TV guide.
struct PlayerChannelGuideSheet: View {
    let item: ChannelItem
    /// Full Guide was chosen: the player closes once the sheet is gone.
    let openFullGuide: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannelGuide) private var openChannelGuide
    @State private var detail: PlayerScheduleSelection?

    var body: some View {
        NavigationStack {
            PlayerChannelSchedule(item: item) { selection in
                detail = selection
            }
            .navigationTitle(item.displayName)
            #if os(iOS)
            .navigationSubtitle(Text("TV Guide"))
            #endif
            .inlineNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        dismiss()
                    }
                    .accessibilityIdentifier("player.guide.close")
                }
                if let openFullGuide, openChannelGuide.isAvailable {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: openFullGuide) {
                            Text("Full Guide")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accentFill)
                        .accessibilityHint("Closes the player and shows this channel in the TV guide")
                        .accessibilityIdentifier("player.guide.fullGuide")
                        .help("Show this channel in the full TV guide")
                    }
                }
            }
        }
        .sheet(item: $detail) { selection in
            ProgrammeDetailView(programme: selection.programme, channel: item, ref: selection.ref)
        }
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 460, idealHeight: 620)
        #endif
    }
}

extension View {
    /// iPhone: medium (the video stays in view above it) and large; iPad: a form sheet the height of the window.
    /// The sheet's backdrop is dimmed so its rows stay legible over a bright picture (`playerSheetBackdrop`).
    func playerChannelGuideSheetPresentation() -> some View {
        modifier(PlayerChannelGuideSheetPresentation())
            .playerSheetBackdrop()
    }
}

private struct PlayerChannelGuideSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if DeviceIdiom.isPad {
            content
                .presentationDetents([.large])
                .presentationSizing(.form)
        } else {
            content
                .mediumAndLargeDetentsAdaptingToTextSize()
        }
        #else
        content
        #endif
    }
}

// MARK: - Schedule

/// A programme of a schedule the user opened, with the guide channel it is on.
struct PlayerScheduleSelection: Identifiable, Hashable {
    let programme: GuideProgramme
    let ref: GuideChannelRef?

    var id: String {
        programme.id
    }
}

/// A channel's schedule in the player: the last programmes of today (dimmed), the one on now (highlighted, with
/// its progress and the time left) and what follows, by day. It opens scrolled to now; once now is out of view, a
/// Now button brings it back.
struct PlayerChannelSchedule: View {

    /// How far back the earlier programmes go (never before the start of today).
    static let earlierWindow: TimeInterval = 4 * 3_600
    static let upcomingLimit = 40

    let item: ChannelItem
    /// Bumped to scroll back to the programme on now (the player's guide control, used again).
    var scrollToNowRequest = 0
    /// A tap on a programme (its details).
    var onSelect: ((PlayerScheduleSelection) -> Void)?

    @Environment(EPGStore.self) private var epg
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var schedule: Schedule?
    /// The programme on now (or the next one, between two) is on screen.
    @State private var isNowVisible = true

    private struct Schedule: Equatable {
        let ref: GuideChannelRef?
        let programmes: [GuideProgramme]
    }

    private struct LoadKey: Equatable {
        let item: ChannelItem
        let revision: Int
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .task(id: LoadKey(item: item, revision: epg.revision)) {
            schedule = await load()
        }
    }

    private func load() async -> Schedule {
        guard let ref = await epg.guideRef(for: item) else {
            return Schedule(ref: nil, programmes: [])
        }
        let now = Date.now
        let earliest = max(Calendar.current.startOfDay(for: now), now.addingTimeInterval(-Self.earlierWindow))
        let earlier = await epg.programmes(for: ref, in: DateInterval(start: earliest, end: now))
            .filter { $0.stop <= now }
        let upcoming = await epg.upcoming(for: ref, from: now, limit: Self.upcomingLimit)
        var seen = Set<String>()
        let programmes = (earlier + upcoming)
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.id).inserted }
        return Schedule(ref: ref, programmes: programmes)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let schedule {
            if schedule.programmes.isEmpty {
                ContentUnavailableView(
                    wrapping: "No Programmes",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("The TV guide has nothing scheduled for this channel.")
                )
            } else {
                list(schedule, now: now)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ schedule: Schedule, now: Date) -> some View {
        let nowID = schedule.programmes.first { $0.stop > now }?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(days(of: schedule.programmes), id: \.day) { day in
                        Text(GuideFormat.day(day.day))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(day.programmes) { programme in
                            PlayerScheduleRow(programme: programme, item: item, now: now) {
                                onSelect?(PlayerScheduleSelection(programme: programme, ref: schedule.ref))
                            }
                            .id(programme.id)
                            .onScrollVisibilityChange(threshold: 0.3) { isVisible in
                                if programme.id == nowID {
                                    isNowVisible = isVisible
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 64)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottom) {
                if !isNowVisible, let nowID {
                    Button {
                        scrollToNow(nowID, proxy: proxy, animated: true)
                    } label: {
                        Label("Now", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Theme.accentFill).interactive(), in: .capsule)
                    .padding(.bottom, 14)
                    .accessibilityLabel("Back to Now")
                    .accessibilityHint("Scrolls to the programme on now")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isNowVisible)
            .onAppear {
                guard let nowID else {
                    return
                }
                // After the first layout, so the lazy rows above it are measured.
                DispatchQueue.main.async {
                    scrollToNow(nowID, proxy: proxy, animated: false)
                }
            }
            .onChange(of: scrollToNowRequest) {
                if let nowID {
                    scrollToNow(nowID, proxy: proxy, animated: true)
                }
            }
        }
    }

    /// Now near the top, with the end of the previous programme above it: the earlier ones are a scroll away.
    private func scrollToNow(_ id: String, proxy: ScrollViewProxy, animated: Bool) {
        let anchor = UnitPoint(x: 0.5, y: 0.15)
        if animated && !reduceMotion {
            withAnimation(.smooth) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    private struct Day {
        let day: Date
        let programmes: [GuideProgramme]
    }

    private func days(of programmes: [GuideProgramme]) -> [Day] {
        let calendar = Calendar.current
        var result: [Day] = []
        for programme in programmes {
            let day = calendar.startOfDay(for: programme.start)
            if let last = result.last, last.day == day {
                result[result.count - 1] = Day(day: day, programmes: last.programmes + [programme])
            } else {
                result.append(Day(day: day, programmes: [programme]))
            }
        }
        return result
    }
}

/// One programme of `PlayerChannelSchedule`: over ones are dimmed, the one on now is highlighted with LIVE, its
/// progress and the time left. A tap shows its details; the context menu (and VoiceOver) has Remind Me.
private struct PlayerScheduleRow: View {
    let programme: GuideProgramme
    let item: ChannelItem
    let now: Date
    let select: () -> Void

    @Environment(EPGStore.self) private var epg
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        let isOnAir = programme.isOnAir(at: now)
        let isOver = programme.stop <= now
        let isReminded = epg.reminders.isScheduled(programme)
        let canRemind = !isOnAir && !isOver && ReminderCenter.canRemind(programme, now: now)
        Button(action: select) {
            // At the accessibility text sizes the time goes above the title, which then has the whole width.
            AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: 12) {
                GuideTimeColumnText(date: programme.start)
                    .font(.subheadline.monospacedDigit().weight(isOnAir ? .semibold : .regular))
                    .foregroundStyle(isOnAir ? AnyShapeStyle(Theme.live) : AnyShapeStyle(Theme.secondaryText))

                VStack(alignment: .leading, spacing: 4) {
                    AdaptiveStack(spacing: 6) {
                        if isOnAir {
                            LiveBadge(compact: true)
                        }
                        Text(programme.title)
                            .font(.subheadline.weight(isOnAir ? .semibold : .regular))
                            .foregroundStyle(isOver ? AnyShapeStyle(Theme.secondaryText) : AnyShapeStyle(.primary))
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 5 : 2)
                    }
                    if let detail = programme.detailLine {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 1)
                    }
                    if isOnAir {
                        HStack(spacing: 8) {
                            ProgrammeProgressBar(progress: programme.progress(at: now), tint: Theme.live, height: 3)
                            Text(GuideFormat.remaining(programme, at: now))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.secondaryText)
                                .fixedSize()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isReminded {
                    Image(systemName: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.lilac)
                        .accessibilityLabel("Reminder set")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if isOnAir {
                    shape
                        .fill(Theme.accent.opacity(0.28))
                        .overlay {
                            shape.strokeBorder(Theme.lilac.opacity(contrast == .increased ? 0.9 : 0.45))
                        }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .rowHoverEffect()
        .contextMenu {
            Button("Details", systemImage: "info.circle", action: select)
            if canRemind {
                reminderButton(isReminded: isReminded)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOver ? Text("Ended") : Text(verbatim: ""))
        .accessibilityAddTraits(isOnAir ? .isSelected : [])
        .accessibilityHint("Shows the details")
        .accessibilityActions {
            if canRemind {
                reminderButton(isReminded: isReminded)
            }
        }
        .accessibilityIdentifier(isOnAir ? "player.guide.onNow" : "player.guide.programme")
    }

    private func reminderButton(isReminded: Bool) -> some View {
        Button(isReminded ? "Cancel Reminder" : "Remind Me", systemImage: isReminded ? "bell.slash" : "bell") {
            Task {
                await epg.reminders.toggle(programme, on: item)
            }
        }
    }
}
#endif
