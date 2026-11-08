//
//  EngineMessageTests.swift
//  FluxoTests
//
//  The remux engine's messages are English ("<what failed>: <FFmpeg's reason>"). `EngineMessage` translates both
//  parts: what failed, and the reasons the network and servers commonly cause, from FFmpeg's error code (the event's
//  `error_code`) or, without a code, from FFmpeg's text. Any other reason stays as FFmpeg says it. The tests run in
//  English, so they check which sentence is chosen; the String Catalog has the translations.
//

import Darwin
import Foundation
import Testing
@testable import Fluxo

@Suite("Engine messages")
struct EngineMessageTests {

    /// FFERRTAG(a, b, c, d) of libavutil/error.h.
    private static func tag(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int32 {
        -Int32(bitPattern: UInt32(a) | UInt32(b) << 8 | UInt32(c) << 16 | UInt32(d) << 24)
    }

    private static let http404 = tag(0xF8, UInt8(ascii: "4"), UInt8(ascii: "0"), UInt8(ascii: "4"))
    private static let http403 = tag(0xF8, UInt8(ascii: "4"), UInt8(ascii: "0"), UInt8(ascii: "3"))
    private static let http5xx = tag(0xF8, UInt8(ascii: "5"), UInt8(ascii: "X"), UInt8(ascii: "X"))
    private static let invalidData = tag(UInt8(ascii: "I"), UInt8(ascii: "N"), UInt8(ascii: "D"), UInt8(ascii: "A"))
    private static let endOfFile = tag(UInt8(ascii: "E"), UInt8(ascii: "O"), UInt8(ascii: "F"), UInt8(ascii: " "))

    @Test("FFmpeg's error codes map to the common reasons")
    func reasonsFromCodes() {
        #expect(EngineMessage.reason(code: -ECONNREFUSED) == .connectionRefused)
        #expect(EngineMessage.reason(code: -ETIMEDOUT) == .timedOut)
        #expect(EngineMessage.reason(code: -ECONNRESET) == .connectionReset)
        #expect(EngineMessage.reason(code: -EPIPE) == .connectionReset)
        #expect(EngineMessage.reason(code: -ENETUNREACH) == .networkUnreachable)
        #expect(EngineMessage.reason(code: -EHOSTUNREACH) == .networkUnreachable)
        #expect(EngineMessage.reason(code: -ENOSPC) == .noSpace)
        #expect(EngineMessage.reason(code: Self.http404) == .notFound)
        #expect(EngineMessage.reason(code: Self.http403) == .forbidden)
        #expect(EngineMessage.reason(code: Self.http5xx) == .serverError)
        #expect(EngineMessage.reason(code: Self.invalidData) == .invalidData)
        #expect(EngineMessage.reason(code: Self.endOfFile) == .endOfStream)
        #expect(EngineMessage.reason(code: -EINVAL) == nil)
    }

    @Test("An input/output error means the server could not be found or reached only while the input opens")
    func inputOutputError() {
        #expect(EngineMessage.reason(code: -EIO, stage: "Unable to open the stream") == .serverNotFound)
        #expect(EngineMessage.reason(code: -EIO, stage: "Stream interrupted") == nil)
        #expect(EngineMessage.localized("Unable to open the stream: Input/output error")
                == "Unable to open the stream: The server couldn't be found or reached")
        #expect(EngineMessage.localized("Stream interrupted: Input/output error") == "Stream interrupted: Input/output error")
    }

    @Test("Both parts of a message are translated, by code or by FFmpeg's text, and other reasons stay as they are")
    func localizedMessages() {
        #expect(EngineMessage.localized("Unable to open the stream: Connection refused", code: -ECONNREFUSED)
                == "Unable to open the stream: The server refused the connection")
        // Without a code (file conversions), from FFmpeg's text.
        #expect(EngineMessage.localized("Unable to open the stream: Server returned 404 Not Found")
                == "Unable to open the stream: The server doesn't have this stream (404)")
        #expect(EngineMessage.localized("Connection lost: Operation timed out", code: -ETIMEDOUT)
                == "Connection lost: The server didn't respond in time")
        #expect(EngineMessage.localized("Unable to write the stream: No space left on device")
                == "Unable to write the stream: There isn't enough storage space")
        // HTTP answers by their code (FFmpeg's tags start with the byte 0xF8), as the Apple TV failure screen reads them.
        #expect(EngineMessage.localized("Unable to open the stream: anything", code: Self.http404)
                == "Unable to open the stream: The server doesn't have this stream (404)")
        #expect(EngineMessage.reason(of: EngineMessage.error(code: Self.http403, message: "Unable to open the stream: x")) == .forbidden)
        // The code wins over the text.
        #expect(EngineMessage.localized("Stream interrupted: something", code: -ECONNRESET)
                == "Stream interrupted: The server closed the connection")
        // A reason with no translation stays in FFmpeg's words.
        #expect(EngineMessage.localized("Stream interrupted: Protocol not found", code: -EPROTONOSUPPORT)
                == "Stream interrupted: Protocol not found")
        // A message the engine does not compose this way is shown as it is.
        #expect(EngineMessage.localized("Something else: Connection refused") == "Something else: Connection refused")
    }

    @Test("An engine error carries its code and stage, so a screen can tell what happened without reading the text")
    func engineErrors() {
        let error = EngineMessage.error(code: -ECONNREFUSED, message: "Unable to open the stream: Connection refused")
        #expect(error.domain == EngineMessage.errorDomain)
        #expect(error.code == Int(-ECONNREFUSED))
        #expect(EngineMessage.reason(of: error) == .connectionRefused)
        let lookup = EngineMessage.error(code: -EIO, message: "Unable to open the stream: Input/output error")
        #expect(EngineMessage.reason(of: lookup) == .serverNotFound)
        #expect(EngineMessage.reason(of: EngineMessage.error(code: -EIO, message: "Connection lost: Input/output error")) == nil)
        #expect(EngineMessage.reason(of: NSError(domain: NSURLErrorDomain, code: Int(-ECONNREFUSED))) == nil)
    }

    @Test("Every common reason has its own sentence")
    func sentences() {
        let reasons: [EngineMessage.Reason] = [
            .connectionRefused, .timedOut, .connectionReset, .networkUnreachable, .badRequest, .unauthorized, .forbidden,
            .notFound, .tooManyRequests, .otherClientError, .serverError, .invalidData, .endOfStream, .noSpace, .serverNotFound,
        ]
        let sentences = Set(reasons.map(\.localizedDescription))
        #expect(sentences.count == reasons.count)
        #expect(!sentences.contains(""))
    }
}
