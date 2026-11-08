//
//  PausedTimeShiftPolicy.swift
//  Fluxo
//
//  A paused live channel through the remux engine keeps reading its input, so that the time-shift window covers
//  what the user missed and they can skip ahead to live. That costs the network and the battery for as long as the
//  pause lasts, and past a point it buys nothing: once the window is full, every new segment pushes out the oldest,
//  and soon the one the user paused on. So the engine stops reading (`StreamRemuxer.setInputSuspended`) when:
//
//  - the window is full behind the paused position: it lets go of its oldest media (its start moved since the pause:
//    a window that is not full yet only grows), and that start is within `windowMargin` of the paused position. The
//    paused position stays in the window, where play continues; the window then holds what came after it;
//  - the pause has lasted `meteredPause` on an expensive or constrained network (cellular, a personal hotspot, Low
//    Data Mode) or in Low Power Mode.
//
//  Never while recording (the recording needs the input). Playing again (or going live, or recording) opens the input
//  again at once: the playlist continues after a discontinuity, and the media that played meanwhile on the channel
//  are not in the window.
//
//  The player's item does not survive a suspension. AVPlayer gives up on a live playlist that stays unchanged for long
//  (CoreMedia -12888 "Playlist File unchanged for longer than 1.5 * target duration", seven times in about 40 s): on
//  macOS it then waits forever at the end of what it had after the resume, on iOS it fails the item (-11866 "Playback
//  Stopped"). So the engine marks the playlist as ended while the input is closed (EXT-X-ENDLIST: AVPlayer does not
//  reload it, and the paused item stays playable within the window), and playing on attaches a new item once the
//  engine wrote the first segment after the resume, at the same media. The engine's dates (EXT-X-PROGRAM-DATE-TIME)
//  follow its media timeline, so a date names the same media in every item of the session (`MediaClock`): the old
//  item's position is a date, and the new item continues at that date.
//

import Foundation

struct PausedTimeShiftPolicy: Equatable {

    /// How close the oldest media of the window may come to the paused position.
    static let windowMargin: TimeInterval = 20
    /// The longest pause that keeps reading on an expensive network or in Low Power Mode.
    static let meteredPause: TimeInterval = 120
    /// How often the player checks a pause.
    static let checkInterval: Duration = .seconds(5)

    struct Conditions: Equatable {
        /// How long the player has been paused.
        var pausedFor: TimeInterval
        /// The paused position, the start of the seekable window (item time) when the player paused, and now.
        var position: TimeInterval?
        var windowStartAtPause: TimeInterval?
        var windowStart: TimeInterval?
        var isExpensiveNetwork = false
        var isLowPowerModeEnabled = false
        var isRecording = false
    }

    enum Decision: Equatable {
        case keepReading
        /// The reason, for the log.
        case suspend(String)
    }

    /// How an item's time maps to the engine's dates. The engine dates the segments of a live playlist on its media
    /// timeline (`FluxoHLS.date_origin_ms`: the first segment's wall clock plus the durations of the segments before,
    /// across discontinuities), and AVPlayer counts an item's time over the same durations, so `currentDate()` minus
    /// `currentTime()` is the same everywhere in an item, whichever segment's date AVPlayer extrapolates from. Two
    /// items of the session show the same media at the same date, wherever each started: no playlist read at the
    /// wrong moment can shift it.
    ///
    /// Read an item's clock when it becomes ready, before it plays: its dates then come from its playlist. Once it plays,
    /// AVPlayer's dates are those of its media, a few frames later than the playlist's in each stretch between
    /// discontinuities (0.12 s, then 0.08 s after a resume, with the H.264 / AAC test channel of `run_vod.sh`), while its
    /// time stays that of the playlist.
    struct MediaClock: Equatable {
        /// The date at item time 0, as seconds since the reference date.
        var origin: TimeInterval

        /// `itemTime` and `date`: an item's `currentTime()` and `currentDate()`, read together. nil without a date.
        init?(itemTime: TimeInterval, date: Date?) {
            guard let date, itemTime.isFinite else {
                return nil
            }
            origin = date.timeIntervalSinceReferenceDate - itemTime
        }

        func date(atItemTime time: TimeInterval) -> Date {
            Date(timeIntervalSinceReferenceDate: origin + time)
        }

        func itemTime(at date: Date) -> TimeInterval {
            date.timeIntervalSinceReferenceDate - origin
        }
    }

    /// The dates the media of a playlist of the engine span: from its first segment's EXT-X-PROGRAM-DATE-TIME to the
    /// end of its last segment. nil when it lists no segment or has no date.
    static func dateRange(ofPlaylist playlist: String) -> Range<Date>? {
        var first: Date?
        var duration: TimeInterval = 0
        var segmentDuration: TimeInterval?
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        for rawLine in playlist.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                if first == nil {
                    let value = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
                    guard let date = (try? format.parse(value)) ?? (try? Date.ISO8601FormatStyle().parse(value)) else {
                        return nil
                    }
                    first = date
                }
            } else if line.hasPrefix("#EXTINF:") {
                // "#EXTINF:<duration>,[<title>]"
                segmentDuration = TimeInterval(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
            } else if !line.isEmpty, !line.hasPrefix("#") {
                // A segment's URI.
                guard let value = segmentDuration, value.isFinite, value >= 0, first != nil else {
                    return nil
                }
                duration += value
                segmentDuration = nil
            }
        }
        guard let first, duration > 0 else {
            return nil
        }
        return first..<first.addingTimeInterval(duration)
    }

    /// The range of an item's time that holds the media of `dates` (`dateRange(ofPlaylist:)`).
    static func itemRange(of dates: Range<Date>, clock: MediaClock) -> (start: TimeInterval, end: TimeInterval) {
        (clock.itemTime(at: dates.lowerBound), clock.itemTime(at: dates.upperBound))
    }

    /// Whether playing on continues from the oldest media of the window, because the paused position left it (paused
    /// for longer than the window, while the input kept being read). Not while the input is suspended: the window does
    /// not move then, and the new item that continues after it starts within its own window
    /// (`resumeItemTime(at:clock:window:)`). (The item whose playlist is marked as ended reports a seekable range of no
    /// length past its media on macOS, which must not be sought to.)
    static func continuesFromOldestMedia(position: TimeInterval, windowStart: TimeInterval?, isSuspended: Bool) -> Bool {
        guard !isSuspended, let windowStart, position.isFinite, windowStart.isFinite else {
            return false
        }
        return position < windowStart + 1
    }

    /// The date of the media where the old item is, when playing on after a suspension: where its seek goes, when one
    /// is under way within its media (`frozen`: the dates of the playlist the input closed at), or where it is; kept
    /// within its media.
    static func resumeDate(position: TimeInterval, seekTarget: TimeInterval?, clock: MediaClock, frozen: Range<Date>?) -> Date {
        var date = clock.date(atItemTime: position)
        if let seekTarget, seekTarget.isFinite {
            let target = clock.date(atItemTime: seekTarget)
            if frozen.map({ $0.contains(target) }) ?? true {
                date = target
            }
        }
        if let frozen, !frozen.contains(date) {
            date = min(max(date, frozen.lowerBound), frozen.upperBound.addingTimeInterval(-0.5))
        }
        return date
    }

    /// Where a new item after a suspension continues, in its time: at `date` (`resumeDate`, or the end of the frozen
    /// media for Go Live: the media written after the resume follow it without a gap), through its clock (`clock`). Kept
    /// within its seekable range (`window`): 2 s into it when the media of `date` left the window meanwhile (as `play()`
    /// continues after a long pause), its end when the date is past it.
    static func resumeItemTime(at date: Date, clock: MediaClock, window: (start: TimeInterval, end: TimeInterval)?) -> TimeInterval {
        let time = clock.itemTime(at: date)
        guard let window, window.end > window.start else {
            return time
        }
        if time < window.start {
            return min(window.start + 2, window.end)
        }
        return min(time, window.end)
    }

    static func decide(_ conditions: Conditions) -> Decision {
        guard !conditions.isRecording else {
            return .keepReading
        }
        if let position = conditions.position, let windowStart = conditions.windowStart, let windowStartAtPause = conditions.windowStartAtPause,
           position.isFinite, windowStart.isFinite, windowStartAtPause.isFinite,
           windowStart > windowStartAtPause + 1, position - windowStart <= windowMargin {
            return .suspend("the time-shift window is full behind the paused position")
        }
        if conditions.pausedFor >= meteredPause && (conditions.isExpensiveNetwork || conditions.isLowPowerModeEnabled) {
            return .suspend(conditions.isLowPowerModeEnabled ? "Low Power Mode" : "an expensive network")
        }
        return .keepReading
    }
}
