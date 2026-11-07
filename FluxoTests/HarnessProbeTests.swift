//
//  HarnessProbeTests.swift
//  FluxoTests
//
//  The simulator harness's playback probe (`DebugPlaybackProbe`, Debug builds): where a seek counts as landed. The
//  window moves with playback, so a probe that starts once playback is already past the target does not fail.
//

#if DEBUG
import Foundation
import Testing
@testable import Fluxo

@Suite("Harness playback probe")
struct HarnessProbeTests {

    @Test("The landing tolerance before the target is half the jump, from 1.5 s to 8 s")
    func landingTolerance() {
        #expect(DebugPlaybackProbe.landingTolerance(target: 55, from: 60) == 2.5)
        #expect(DebugPlaybackProbe.landingTolerance(target: 300, from: 301) == 1.5)
        #expect(DebugPlaybackProbe.landingTolerance(target: 600, from: 30) == 8)
    }

    @Test("A position at the target, or a little before it within the tolerance, has landed")
    func atTarget() {
        #expect(DebugPlaybackProbe.isAtTarget(300, target: 300, elapsed: 0, tolerance: 1.5))
        #expect(DebugPlaybackProbe.isAtTarget(298.6, target: 300, elapsed: 0, tolerance: 1.5))
        #expect(!DebugPlaybackProbe.isAtTarget(298, target: 300, elapsed: 0, tolerance: 1.5))
    }

    @Test("Past the target by what playback advanced while the probe waited, it has landed too")
    func playbackWentOn() {
        // The seek to 300 s landed, then the seeker settled 4 s later: playback is at 304.5 s.
        #expect(DebugPlaybackProbe.isAtTarget(304.5, target: 300, elapsed: 4, tolerance: 1.5))
        #expect(DebugPlaybackProbe.isAtTarget(301.9, target: 300, elapsed: 0, tolerance: 1.5), "the lead after the target")
        #expect(!DebugPlaybackProbe.isAtTarget(310, target: 300, elapsed: 4, tolerance: 1.5), "further than playback could have gone")
    }

    @Test("A short skip back is not taken as landed while playback is still where it was")
    func skipBackNotLandedYet() {
        // Skip 5 s back from 60 s: until it lands, playback goes on from 60 s.
        let tolerance = DebugPlaybackProbe.landingTolerance(target: 55, from: 60)
        for elapsed in stride(from: 0.0, through: 10, by: 0.5) {
            #expect(!DebugPlaybackProbe.isAtTarget(60 + elapsed, target: 55, elapsed: elapsed, tolerance: tolerance))
        }
    }
}
#endif
