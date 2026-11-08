//
//  TVGuideModel.swift
//  Fluxo
//
//  The model of Apple TV's guide grid (TVGuideScreen): its two-hour window and the programmes of the rows that
//  were shown, for a day around the window.
//

import SwiftData
import SwiftUI

#if os(tvOS)
// MARK: - Model

/// The two-hour window of the grid and the programmes of the rows that were shown, for a day around the window.
@MainActor
@Observable
final class TVGuideModel {
    nonisolated static let windowDuration: TimeInterval = 2 * 3_600
    /// How far Earlier / Later and the cells at the ends of a row move the window.
    static let step: TimeInterval = 3_600
    /// Rows read their programmes for this long around the window.
    static let loadSpan: TimeInterval = 30 * 3_600
    static let dayCount = 7

    var windowStart: Date

    struct Row {
        let range: DateInterval
        let programmes: [GuideProgramme]
    }

    private(set) var rows: [UUID: Row] = [:]
    /// Bumped when rows load (pending focus moves wait for them).
    private(set) var loadCount = 0
    @ObservationIgnored
    private var revision = -1

    init(now: Date = .now) {
        windowStart = Self.aligned(now.addingTimeInterval(-Self.leadIn))
    }

    /// The window starts this much before now (on the half hour before that), so what is on air shows with some
    /// of what came before.
    static let leadIn: TimeInterval = 15 * 60

    func showNow() {
        show(Date.now.addingTimeInterval(-Self.leadIn))
    }

    var windowEnd: Date {
        windowStart.addingTimeInterval(Self.windowDuration)
    }

    var window: DateInterval {
        DateInterval(start: windowStart, duration: Self.windowDuration)
    }

    /// Today's first half hour; the guide keeps the programmes of the week ahead.
    var earliestStart: Date {
        Calendar.current.startOfDay(for: .now)
    }

    var latestStart: Date {
        let end = Calendar.current.date(byAdding: .day, value: Self.dayCount, to: earliestStart) ?? earliestStart.addingTimeInterval(7 * 86_400)
        return end.addingTimeInterval(-Self.windowDuration)
    }

    var canGoEarlier: Bool {
        windowStart > earliestStart
    }

    var canGoLater: Bool {
        windowStart < latestStart
    }

    /// Starts the window on the half hour at or before `date`, within the days the guide keeps.
    func show(_ date: Date) {
        windowStart = min(latestStart, max(earliestStart, Self.aligned(date)))
    }

    func move(by interval: TimeInterval) {
        show(windowStart.addingTimeInterval(interval))
    }

    /// The half hour at or before `date`.
    static func aligned(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var aligned = components
        aligned.minute = (components.minute ?? 0) < 30 ? 0 : 30
        return calendar.date(from: aligned) ?? date
    }

    /// The load key of the window: rows read again only when it leaves the span read for the last one.
    var loadBucket: Date {
        let start = earliestStart
        let index = (windowStart.timeIntervalSince(start) / (12 * 3_600)).rounded(.down)
        return start.addingTimeInterval(index * 12 * 3_600)
    }

    func programmes(for channelID: UUID) -> [GuideProgramme]? {
        guard let row = rows[channelID], row.range.contains(windowStart), row.range.contains(windowEnd) else {
            return nil
        }
        let window = window
        return row.programmes.filter { $0.stop > window.start && $0.start < window.end && $0.stop > $0.start }
    }

    /// Reads the programmes of a row for the span around the window, unless they are read already.
    func load(_ channel: GuideChannel, epg: EPGStore) async {
        if revision != epg.revision {
            revision = epg.revision
            rows = [:]
        }
        if programmes(for: channel.id) != nil {
            return
        }
        let range = DateInterval(start: loadBucket.addingTimeInterval(-6 * 3_600), duration: Self.loadSpan)
        let loaded = await epg.programmes(for: channel.ref, in: range)
        guard !Task.isCancelled else {
            return
        }
        rows[channel.id] = Row(range: range, programmes: loaded.sorted { $0.start < $1.start })
        loadCount &+= 1
    }

    /// The programme of a row on air at `date`, or the first one after it in the window.
    func programme(in channelID: UUID, at date: Date, forward: Bool) -> GuideProgramme? {
        guard let programmes = programmes(for: channelID) else {
            return nil
        }
        if let covering = programmes.first(where: { $0.start <= date && date < $0.stop }) {
            return covering
        }
        return forward ? programmes.first { $0.start >= date } : programmes.last { $0.stop <= date }
    }
}
#endif
