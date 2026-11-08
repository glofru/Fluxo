//
//  PausedTimeShiftPolicyTests.swift
//  FluxoTests
//
//  When a paused live channel stops reading its input (`PausedTimeShiftPolicy.decide`), and how playing on finds the
//  paused media in the new player item by its date (`MediaClock`, `dateRange(ofPlaylist:)`, `resumeDate`,
//  `resumeItemTime`). Tools/EngineSmokeTest/run_probe.sh (suspend) and run_vod.sh (live-pause) check the engine and
//  AVPlayer around it.
//

import Foundation
import Testing
@testable import Fluxo

@Suite("Paused time shift")
struct PausedTimeShiftPolicyTests {

    private typealias Policy = PausedTimeShiftPolicy

    @Test("A window that is still filling, or holds the paused position well, keeps reading")
    func keepsReading() {
        // The window has not moved since the pause: it only grows.
        #expect(Policy.decide(.init(pausedFor: 600, position: 10, windowStartAtPause: 0, windowStart: 0)) == .keepReading)
        // It moved, but the paused position is far from its start.
        #expect(Policy.decide(.init(pausedFor: 600, position: 100, windowStartAtPause: 0, windowStart: 30)) == .keepReading)
        // A short pause on cellular.
        #expect(Policy.decide(.init(pausedFor: 60, position: 10, windowStartAtPause: 0, windowStart: 0, isExpensiveNetwork: true)) == .keepReading)
        // Unknown positions.
        #expect(Policy.decide(.init(pausedFor: 60, position: nil, windowStartAtPause: nil, windowStart: nil)) == .keepReading)
    }

    @Test("A full window that is about to push out the paused position closes the input")
    func fullWindow() {
        let decision = Policy.decide(.init(pausedFor: 1800, position: 100, windowStartAtPause: 0, windowStart: 85))
        #expect(decision != .keepReading)
    }

    @Test("After 2 minutes on an expensive network or in Low Power Mode, the input closes")
    func meteredPause() {
        #expect(Policy.decide(.init(pausedFor: 120, position: 10, windowStartAtPause: 0, windowStart: 0, isExpensiveNetwork: true)) != .keepReading)
        #expect(Policy.decide(.init(pausedFor: 125, position: 10, windowStartAtPause: 0, windowStart: 0, isLowPowerModeEnabled: true)) != .keepReading)
        #expect(Policy.decide(.init(pausedFor: 125, position: 10, windowStartAtPause: 0, windowStart: 0)) == .keepReading)
    }

    @Test("Never while recording")
    func recording() {
        #expect(Policy.decide(.init(pausedFor: 1800, position: 100, windowStartAtPause: 0, windowStart: 95,
                                    isExpensiveNetwork: true, isLowPowerModeEnabled: true, isRecording: true)) == .keepReading)
    }

    @Test("The dates of a playlist span its first segment's date plus the durations of its segments")
    func playlistDates() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-PROGRAM-DATE-TIME:2026-11-08T10:00:00.000Z
        #EXTINF:4.000,
        live-000001.ts
        #EXT-X-PROGRAM-DATE-TIME:2026-11-08T10:00:04.000Z
        #EXTINF:3.500,
        live-000002.ts
        #EXT-X-DISCONTINUITY
        #EXT-X-PROGRAM-DATE-TIME:2026-11-08T10:00:07.500Z
        #EXTINF:4.000,
        live-000003.ts
        #EXT-X-ENDLIST
        """
        let range = try #require(Policy.dateRange(ofPlaylist: playlist))
        let start = try Date.ISO8601FormatStyle().parse("2026-11-08T10:00:00Z")
        #expect(abs(range.lowerBound.timeIntervalSince(start)) < 0.001)
        #expect(abs(range.upperBound.timeIntervalSince(range.lowerBound) - 11.5) < 0.001)
        #expect(Policy.dateRange(ofPlaylist: "#EXTM3U\n#EXTINF:4.0,\nlive-1.ts\n") == nil)
        #expect(Policy.dateRange(ofPlaylist: "#EXTM3U\n") == nil)
    }

    @Test("A date names the same media in two items of the session, wherever each starts")
    func mediaClock() throws {
        let origin = Date(timeIntervalSinceReferenceDate: 1_000_000)
        // The old item started at the first segment, the new one 26 s later.
        let old = try #require(Policy.MediaClock(itemTime: 12, date: origin.addingTimeInterval(12)))
        let new = try #require(Policy.MediaClock(itemTime: 3, date: origin.addingTimeInterval(29)))
        let paused = old.date(atItemTime: 14.6)
        #expect(abs(new.itemTime(at: paused) - (14.6 - 26)) < 0.000_1)
        #expect(Policy.MediaClock(itemTime: 3, date: nil) == nil)
        #expect(Policy.MediaClock(itemTime: .nan, date: origin) == nil)
    }

    @Test("Playing on continues where the old item was, or where its seek within the frozen media goes")
    func resumeDate() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let clock = try #require(Policy.MediaClock(itemTime: 0, date: start))
        let frozen = start..<start.addingTimeInterval(26)
        #expect(Policy.resumeDate(position: 14, seekTarget: nil, clock: clock, frozen: frozen) == start.addingTimeInterval(14))
        #expect(Policy.resumeDate(position: 14, seekTarget: 20, clock: clock, frozen: frozen) == start.addingTimeInterval(20))
        // A seek past the frozen media is not taken; a position past them is kept inside.
        #expect(Policy.resumeDate(position: 14, seekTarget: 40, clock: clock, frozen: frozen) == start.addingTimeInterval(14))
        #expect(Policy.resumeDate(position: 30, seekTarget: nil, clock: clock, frozen: frozen) == start.addingTimeInterval(25.5))
    }

    @Test("The new item continues within its window")
    func resumeItemTime() throws {
        let clock = try #require(Policy.MediaClock(itemTime: 0, date: Date(timeIntervalSinceReferenceDate: 100)))
        let date = Date(timeIntervalSinceReferenceDate: 110)
        #expect(Policy.resumeItemTime(at: date, clock: clock, window: (0, 30)) == 10)
        // The media left the window meanwhile: 2 s into it.
        #expect(Policy.resumeItemTime(at: date, clock: clock, window: (20, 60)) == 22)
        // Past the end: the end.
        #expect(Policy.resumeItemTime(at: date, clock: clock, window: (0, 5)) == 5)
        #expect(Policy.resumeItemTime(at: date, clock: clock, window: nil) == 10)
    }

    @Test("Play continues from the oldest media only when the paused position left the window, never while suspended")
    func oldestMedia() {
        #expect(Policy.continuesFromOldestMedia(position: 10, windowStart: 10, isSuspended: false))
        #expect(!Policy.continuesFromOldestMedia(position: 30, windowStart: 10, isSuspended: false))
        #expect(!Policy.continuesFromOldestMedia(position: 10, windowStart: 10, isSuspended: true))
        #expect(!Policy.continuesFromOldestMedia(position: 10, windowStart: nil, isSuspended: false))
    }
}
