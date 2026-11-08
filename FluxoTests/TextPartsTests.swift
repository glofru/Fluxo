//
//  TextPartsTests.swift
//  FluxoTests
//
//  The pieces a line of parts is shown in at the accessibility text sizes (`TextParts.flowPieces`, `PartsLine`):
//  each part whole, with the separator at its end, and the same text as the line of one `Text`.
//

import Foundation
import Testing
@testable import Fluxo

@Suite("Lines of parts")
struct TextPartsTests {

    private let isolateStart = "\u{2068}"
    private let isolateEnd = "\u{2069}"
    private let noBreakSpace = "\u{00A0}"

    @Test("Each part is a piece with the separator at its end, the last one without")
    func piecesCarryTheSeparator() {
        let pieces = TextParts.flowPieces(["2021", "2 seasons", "10 episodes", "Drama"])
        #expect(pieces == [
            "\(isolateStart)2021\(isolateEnd)\(noBreakSpace)·",
            "\(isolateStart)2 seasons\(isolateEnd)\(noBreakSpace)·",
            "\(isolateStart)10 episodes\(isolateEnd)\(noBreakSpace)·",
            "\(isolateStart)Drama\(isolateEnd)",
        ])
    }

    @Test("Nil and empty parts are left out; a single part has no separator and no isolate")
    func emptyPartsAreLeftOut() {
        #expect(TextParts.flowPieces([nil, "2021", "", nil]) == ["2021"])
        #expect(TextParts.flowPieces([nil, ""]).isEmpty)
    }

    @Test("A piece wraps between its own words: the no-break spaces that kept a count together become spaces")
    func noBreakSpacesInsideAPartBecomeSpaces() {
        let pieces = TextParts.flowPieces(["2021", TextParts.keepingWordsTogether("2 seasons")])
        #expect(pieces.last == "\(isolateStart)2 seasons\(isolateEnd)")
    }

    @Test("A separator inside a provider's name stays at the end of its line")
    func innerSeparatorsStayAttached() {
        let pieces = TextParts.flowPieces(["Serie TV | Drama", "Sky"])
        #expect(pieces.first == "\(isolateStart)Serie TV\(noBreakSpace)| Drama\(isolateEnd)\(noBreakSpace)·")
    }

    @Test("The pieces read as the line of one Text", arguments: [
        ["2021", "3 seasons", "30 episodes", "Sci-Fi"],
        ["Live TV", "Serie TV | Drama", "Freeview"],
        ["Sport", "Sky Italia"],
    ])
    func piecesMatchTheLine(_ parts: [String]) {
        #expect(TextParts.flowPieces(parts).joined(separator: " ") == TextParts.line(parts))
    }
}
