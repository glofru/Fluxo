//
//  ChannelScheduleView.swift
//  Fluxo
//
//  The schedule of one live channel from the TV guide (the "Guide" swipe action of channel rows): what is on
//  now with its progress, then the next programmes by day, with reminders. Tapping a programme opens its
//  details.
//

import SwiftUI

struct ChannelScheduleView: View {

    static let programmeLimit = 60

    let item: ChannelItem
    /// Closes the inspector (iPad); nil when shown as a sheet, which dismisses itself.
    var onClose: (() -> Void)?

    @Environment(EPGStore.self) private var epg
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var ref: GuideChannelRef?
    @State private var programmes: [GuideProgramme]?
    @State private var detail: GuideProgramme?

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                content(now: context.date)
            }
            .navigationTitle(item.displayName)
            .inlineNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        close()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Watch", systemImage: "play.fill") {
                        close()
                        playChannel(item)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentFill)
                }
            }
        }
        .sheet(item: $detail) { programme in
            ProgrammeDetailView(programme: programme, channel: item, ref: ref)
        }
        .task(id: epg.revision) {
            let ref = await epg.guideRef(for: item)
            self.ref = ref
            if let ref {
                programmes = await epg.upcoming(for: ref, from: .now, limit: Self.programmeLimit)
            } else {
                programmes = []
            }
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let programmes {
            if programmes.isEmpty {
                ContentUnavailableView(
                    "No Programmes",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("The TV guide has nothing scheduled for this channel.")
                )
            } else {
                List {
                    Section {
                        header
                            .listRowBackground(Color.clear)
                    }
                    ForEach(days(of: programmes), id: \.day) { day in
                        Section(GuideFormat.day(day.day)) {
                            ForEach(day.programmes) { programme in
                                row(programme, now: now)
                            }
                        }
                    }
                }
                .glassSheetContentBackground()
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        AdaptiveStack(spacing: 14) {
            ChannelLogoTile(item: item, size: CGSize(width: 84, height: 56), cornerRadius: 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.headline)
                    .lineLimit(4)
                if !item.groupName.isEmpty {
                    Text(item.groupName)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ programme: GuideProgramme, now: Date) -> some View {
        let isOnAir = programme.isOnAir(at: now)
        let isReminded = epg.reminders.isScheduled(programme)
        return Button {
            detail = programme
        } label: {
            // At the accessibility text sizes the time goes above the title, which then has the whole width.
            AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: 12) {
                GuideTimeColumnText(date: programme.start)
                    .font(.subheadline.monospacedDigit().weight(isOnAir ? .semibold : .regular))
                    .foregroundStyle(isOnAir ? AnyShapeStyle(Theme.live) : AnyShapeStyle(Theme.secondaryText))

                VStack(alignment: .leading, spacing: 4) {
                    // LIVE above the title at the accessibility text sizes, so the title wraps at the margin.
                    AdaptiveStack(spacing: 6) {
                        if isOnAir {
                            LiveBadge(compact: true)
                        }
                        Text(programme.title)
                            .font(.body.weight(isOnAir ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 5 : 2)
                    }
                    if let detailLine = programme.detailLine {
                        Text(detailLine)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 1)
                    }
                    if isOnAir {
                        HStack(spacing: 8) {
                            ProgrammeProgressBar(progress: programme.progress(at: now), tint: Theme.live, height: 4)
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
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Reminder set")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .rowSwipeActions(edge: .trailing) {
            if !isOnAir, ReminderCenter.canRemind(programme, now: now) {
                Button(isReminded ? "Cancel Reminder" : "Remind Me", systemImage: isReminded ? "bell.slash" : "bell") {
                    Task {
                        await epg.reminders.toggle(programme, on: item)
                    }
                }
                .tint(Theme.accentFill)
            }
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

extension View {
    /// Presents the schedule of `AppNavigation.scheduleChannel` (set by the "Guide" actions of channel rows) in a
    /// sheet. Apply once, at the root of the window. In a wide window on iPad (landscape) the screens that have a
    /// `channelScheduleInspector()` show it in their inspector instead.
    func channelScheduleSheet(_ navigation: AppNavigation) -> some View {
        modifier(ChannelScheduleSheet(navigation: navigation))
    }

    /// iPad, wide window: shows the schedule of `AppNavigation.scheduleChannel` in an inspector column next to
    /// this screen, which stays usable (another channel's Guide action replaces the schedule). Apply outside the
    /// screen's navigation stack, so the inspector stays while screens are pushed.
    func channelScheduleInspector() -> some View {
        modifier(ChannelScheduleInspector())
    }
}

private struct ChannelScheduleSheet: ViewModifier {
    @Bindable var navigation: AppNavigation

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    func body(content: Content) -> some View {
        content
            .sheet(item: usesInspector ? .constant(nil) : $navigation.scheduleChannel) { item in
                ChannelScheduleView(item: item)
                    // iPad (portrait, narrow windows): a centered form sheet the height of the window; a half
                    // height sheet would sit at the bottom of the screen. iPhone: medium and large, or large only at
                    // the accessibility text sizes.
                    .if(DeviceIdiom.isPad) { sheet in
                        sheet
                            .presentationDetents([.large])
                            .presentationSizing(.form)
                    }
                    .if(!DeviceIdiom.isPad) { sheet in
                        sheet.mediumAndLargeDetentsAdaptingToTextSize()
                    }
            }
    }

    private var usesInspector: Bool {
        #if os(iOS)
        return DeviceIdiom.isPad && horizontalSizeClass == .regular && navigation.isWideWindow && navigation.tabHostsScheduleInspector
        #else
        return false
        #endif
    }
}

private struct ChannelScheduleInspector: ViewModifier {
    @Environment(AppNavigation.self) private var navigation
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .inspector(isPresented: isPresented) {
                Group {
                    if let item = navigation.scheduleChannel {
                        ChannelScheduleView(item: item) {
                            navigation.scheduleChannel = nil
                        }
                        .id(item.id)
                    }
                }
                .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
            }
        #else
        content
        #endif
    }

    #if os(iOS)
    private var isPresented: Binding<Bool> {
        Binding(
            get: { DeviceIdiom.isPad && horizontalSizeClass == .regular && navigation.isWideWindow && navigation.scheduleChannel != nil },
            set: { isPresented in
                if !isPresented {
                    navigation.scheduleChannel = nil
                }
            }
        )
    }
    #endif
}

#Preview {
    ChannelScheduleView(item: GuidePreviewData.channels.first?.item ?? PreviewSampleData.sampleItems[0])
        .fluxoPreviewEnvironment(GuidePreviewData.container)
}
