//
//  FeaturedRotation.swift
//  Fluxo
//
//  When the featured billboard (and the Apple TV hero) shows other pages: its picks follow a seed
//  (`FeaturedPicker`), and the seed changes
//  - when the app comes to the foreground on another day, or `interval` after the seed was drawn;
//  - on pull to refresh of Home (iPhone, iPad).
//  Never while the app stays in the foreground, so a page does not change under the viewer's eyes. The seed is kept
//  in the defaults, so a relaunch shows the same pages until it is due.
//

import Foundation
import Observation

@MainActor
@Observable
final class FeaturedRotation {

    static let shared = FeaturedRotation()

    /// How long a selection stays when the app comes back to the foreground the same day.
    nonisolated static let interval: TimeInterval = 6 * 3_600

    static let seedKey = "featured.seed"
    static let drawnAtKey = "featured.seedDrawnAt"

    private(set) var seed: UInt64
    #if DEBUG
    /// Debug harness (`featured-seed:<n>`): a given selection instead of the rotation's.
    var debugForcedSeed: UInt64?
    #endif

    @ObservationIgnored
    private var drawnAt: Date

    private init() {
        let defaults = UserDefaults.fluxo
        if let stored = defaults.object(forKey: Self.seedKey) as? Int, let date = defaults.object(forKey: Self.drawnAtKey) as? Date {
            seed = UInt64(bitPattern: Int64(stored))
            drawnAt = date
        } else {
            seed = UInt64.random(in: .min ... .max)
            drawnAt = .now
            save()
        }
        refreshIfDue()
    }

    /// The seed the picks use.
    var currentSeed: UInt64 {
        #if DEBUG
        if let debugForcedSeed {
            return debugForcedSeed
        }
        #endif
        return seed
    }

    /// Draws a new seed when the current one is from another day or older than `interval`. Call when the app comes to
    /// the foreground.
    func refreshIfDue(now: Date = .now, calendar: Calendar = .current) {
        if Self.isDue(drawnAt: drawnAt, now: now, calendar: calendar) {
            advance(now: now)
        }
    }

    /// Draws a new seed now (pull to refresh).
    func advance(now: Date = .now) {
        var next = UInt64.random(in: .min ... .max)
        while next == seed {
            next = UInt64.random(in: .min ... .max)
        }
        seed = next
        drawnAt = now
        save()
    }

    nonisolated static func isDue(drawnAt: Date, now: Date, calendar: Calendar) -> Bool {
        // A clock set back also draws again.
        now.timeIntervalSince(drawnAt) >= interval || now < drawnAt || !calendar.isDate(drawnAt, inSameDayAs: now)
    }

    private func save() {
        let defaults = UserDefaults.fluxo
        defaults.set(Int(Int64(bitPattern: seed)), forKey: Self.seedKey)
        defaults.set(drawnAt, forKey: Self.drawnAtKey)
    }
}
