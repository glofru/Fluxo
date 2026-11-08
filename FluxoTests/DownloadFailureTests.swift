//
//  DownloadFailureTests.swift
//  FluxoTests
//
//  A failed download keeps why it failed, not a message in the language of the moment: an error of a known kind is a
//  code, any other keeps its domain and code, and its description only with the language it is in.
//

import Foundation
import Testing
@testable import Fluxo

@Suite("Download failures")
struct DownloadFailureTests {

    private struct ServerSaid: LocalizedError {
        var errorDescription: String? { "The server is busy." }
    }

    @Test("An error without a known kind keeps its domain, code and the app's language")
    func keepsDomainAndCode() throws {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSLocalizedDescriptionKey: "Cannot Open"])
        let reason = DownloadFailure.Reason(classifying: error)
        #expect(reason == .system(domain: "AVFoundationErrorDomain", code: -11800, text: "Cannot Open", language: DownloadFailure.Reason.appLanguage))
        #expect(reason.message == "Cannot Open")
    }

    @Test("In another language, the description gives way to a sentence of this one, with the domain and code")
    func otherLanguage() {
        let reason = DownloadFailure.Reason.system(domain: "AVFoundationErrorDomain", code: -11800, text: "Impossibile aprire", language: "xx")
        #expect(reason.message.hasPrefix(DownloadFailure.Reason.unexpectedMessage))
        #expect(reason.message.contains("\u{2068}AVFoundationErrorDomain -11800\u{2069}"))
        #expect(!reason.message.contains("Impossibile"))
    }

    @Test("A Swift error with a description of its own is kept the same way")
    func swiftError() {
        let reason = DownloadFailure.Reason(classifying: ServerSaid())
        guard case .system(_, _, let text, let language) = reason else {
            Issue.record("expected a system reason, got \(reason)")
            return
        }
        #expect(text == "The server is busy.")
        #expect(language == DownloadFailure.Reason.appLanguage)
    }

    @Test("A description that says nothing is an unexpected stop")
    func uninformative() {
        #expect(DownloadFailure.Reason(classifying: NSError(domain: "Fluxo.Test", code: 3)) == .unexpected)
    }

    @Test("The stored form keeps the domain, code, text and language")
    func roundTrip() throws {
        let reason = DownloadFailure.Reason.system(domain: NSURLErrorDomain, code: -1013, text: "Authentication needed", language: "it")
        let decoded = try JSONDecoder().decode(DownloadFailure.Reason.self, from: JSONEncoder().encode(reason))
        #expect(decoded == reason)
    }

    @Test("A description an earlier build stored still reads as it did")
    func earlierBuildText() throws {
        let decoded = try JSONDecoder().decode(DownloadFailure.Reason.self, from: Data(#"{"other":{"_0":"The server is busy."}}"#.utf8))
        #expect(decoded.message == "The server is busy.")
    }
}
