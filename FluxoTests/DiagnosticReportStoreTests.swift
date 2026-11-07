//
//  DiagnosticReportStoreTests.swift
//  FluxoTests
//
//  The on-device ring buffer of MetricKit reports (`DiagnosticReportStore`): order, kinds, the count, size and age
//  limits, deletion, and the export the user shares.
//

import Foundation
import Testing
@testable import Fluxo

@Suite("Diagnostic reports kept on the device")
struct DiagnosticReportStoreTests {

    /// A store in a new folder of its own.
    private final class Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fluxo-tests-diagnostics-\(UUID().uuidString)", isDirectory: true)
        var store: DiagnosticReportStore

        init(maximumCount: Int = 40, maximumBytes: Int64 = 8 * 1_024 * 1_024) {
            store = DiagnosticReportStore(directory: folder)
            store.maximumCount = maximumCount
            store.maximumBytes = maximumBytes
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private let start = Date(timeIntervalSince1970: 1_794_000_000)

    private func report(_ text: String) -> Data {
        Data("{\"text\":\"\(text)\"}".utf8)
    }

    @Test("Reports are listed newest first, with their kind and the time they arrived")
    func order() throws {
        let fixture = Fixture()
        try fixture.store.save(report("a"), kind: .metrics, receivedOn: start)
        try fixture.store.save(report("b"), kind: .crash, receivedOn: start.addingTimeInterval(60))
        try fixture.store.save(report("c"), kind: .diskWriteException, receivedOn: start.addingTimeInterval(120))
        let entries = fixture.store.entries()
        #expect(entries.map(\.kind) == [.diskWriteException, .crash, .metrics])
        #expect(entries.first?.receivedOn == start.addingTimeInterval(120))
        #expect(entries.allSatisfy { $0.bytes > 0 })
    }

    @Test("Every kind survives its file name", arguments: DiagnosticReportEntry.Kind.allCases)
    func kinds(_ kind: DiagnosticReportEntry.Kind) throws {
        let fixture = Fixture()
        let saved = try fixture.store.save(report(kind.rawValue), kind: kind, receivedOn: start)
        #expect(DiagnosticReportStore.entry(at: saved.fileURL)?.kind == kind)
    }

    @Test("Other files in the folder are left out and left alone")
    func otherFiles() throws {
        let fixture = Fixture()
        try fixture.store.save(report("a"), kind: .hang, receivedOn: start)
        let stray = fixture.folder.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: stray)
        try Data("{}".utf8).write(to: fixture.folder.appendingPathComponent("12-crash-x.json"))
        #expect(fixture.store.entries().map(\.kind) == [.hang])
        fixture.store.deleteAll()
        #expect(fixture.store.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test("At most the maximum count is kept, the oldest dropped first")
    func countLimit() throws {
        let fixture = Fixture(maximumCount: 3)
        for index in 0..<5 {
            try fixture.store.save(report("\(index)"), kind: .metrics, receivedOn: start.addingTimeInterval(Double(index) * 60))
        }
        let entries = fixture.store.entries()
        #expect(entries.count == 3)
        #expect(entries.last?.receivedOn == start.addingTimeInterval(120))
    }

    @Test("At most the maximum size is kept")
    func sizeLimit() throws {
        let fixture = Fixture(maximumBytes: 2_500)
        let big = Data(repeating: UInt8(ascii: " "), count: 1_000)
        for index in 0..<5 {
            try fixture.store.save(big, kind: .hang, receivedOn: start.addingTimeInterval(Double(index)))
        }
        let entries = fixture.store.entries()
        #expect(entries.count == 2)
        #expect(entries.reduce(0) { $0 + $1.bytes } <= 2_500)
    }

    @Test("Reports older than the maximum age are dropped")
    func ageLimit() throws {
        let fixture = Fixture()
        try fixture.store.save(report("old"), kind: .crash, receivedOn: start)
        try fixture.store.save(report("new"), kind: .hang, receivedOn: start.addingTimeInterval(fixture.store.maximumAge + 60))
        #expect(fixture.store.entries().map(\.kind) == [.hang])
    }

    @Test("The export holds every report unchanged, oldest first, in one JSON document")
    func export() throws {
        let fixture = Fixture()
        #expect(try fixture.store.makeExport(appVersion: "1.0 (1)") == nil, "nothing to export")
        try fixture.store.save(report("first"), kind: .crash, receivedOn: start)
        try fixture.store.save(report("second"), kind: .metrics, receivedOn: start.addingTimeInterval(60))
        let url = try #require(try fixture.store.makeExport(appVersion: "1.0 (1)", now: start.addingTimeInterval(120)))
        defer {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(document["app"] as? String == "Fluxo 1.0 (1)")
        let reports = try #require(document["reports"] as? [[String: Any]])
        #expect(reports.map { $0["kind"] as? String } == ["crash", "metrics"])
        #expect(reports.map { ($0["report"] as? [String: Any])?["text"] as? String } == ["first", "second"])
        #expect(url.pathExtension == "json")
    }
}
