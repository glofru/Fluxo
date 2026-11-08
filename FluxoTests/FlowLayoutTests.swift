//
//  FlowLayoutTests.swift
//  FluxoTests
//
//  The lines `FlowLayout` breaks its subviews into (`PartsLine` at the accessibility text sizes): as many as fit,
//  and a subview wider than the line alone on its line, so that it starts at the leading edge.
//

import CoreGraphics
import Testing
@testable import Fluxo

@Suite("Flow layout lines")
struct FlowLayoutTests {

    @Test("Subviews share a line while they fit, spacing included")
    func subviewsShareALine() {
        #expect(FlowLayout.lines(widths: [40, 40, 40], maxWidth: 100, spacing: 10) == [[0, 1], [2]])
        // 40 + 10 + 50 is exactly the width: it fits.
        #expect(FlowLayout.lines(widths: [40, 50, 30], maxWidth: 100, spacing: 10) == [[0, 1], [2]])
    }

    @Test("A subview wider than the line is alone on it, never after a short one")
    func oversizedSubviewIsALineOfItsOwn() {
        // The programme sheet's "Today ·", a time range too wide for the line, the length.
        #expect(FlowLayout.lines(widths: [30, 150, 20], maxWidth: 100, spacing: 4) == [[0], [1], [2]])
        #expect(FlowLayout.lines(widths: [150, 20, 20], maxWidth: 100, spacing: 4) == [[0], [1, 2]])
        #expect(FlowLayout.lines(widths: [20, 20, 150], maxWidth: 100, spacing: 4) == [[0, 1], [2]])
        #expect(FlowLayout.lines(widths: [150, 150], maxWidth: 100, spacing: 4) == [[0], [1]])
    }

    @Test("A subview exactly as wide as the line is not oversized")
    func subviewAsWideAsTheLine() {
        #expect(FlowLayout.lines(widths: [100, 20], maxWidth: 100, spacing: 4) == [[0], [1]])
        #expect(FlowLayout.lines(widths: [20, 100], maxWidth: 100, spacing: 4) == [[0], [1]])
    }

    @Test("Without a width every subview is on one line; nothing gives no line")
    func unboundedAndEmpty() {
        #expect(FlowLayout.lines(widths: [500, 500, 500], maxWidth: .infinity, spacing: 4) == [[0, 1, 2]])
        #expect(FlowLayout.lines(widths: [], maxWidth: 100, spacing: 4).isEmpty)
    }
}
