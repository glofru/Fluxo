//
//  DownloadManifestTests.swift
//  FluxoTests
//
//  The list of offline downloads (`DownloadManifest`) is read record by record: records of earlier and later builds
//  are read with defaults, the ones this build cannot read are kept as they are (so a save never loses them), and
//  a file that is not a list at all is reported. Tools/LibraryCheck checks the files on disk around it.
//

import Foundation
import Testing
@testable import Fluxo

@Suite("Downloads list")
struct DownloadManifestTests {

    private let known = UUID()
    private let olderBuild = UUID()
    private let newerBuild = UUID()
    private let broken = UUID()
    private let playlistID = UUID()

    /// A record as this build writes it, one of an earlier build (fewer fields), one of a later build (values and a
    /// field this build does not know), one this build cannot read (no link), and a value that is not a record.
    private var manifest: Data {
        Data("""
        [
          {"id":"\(known)","item":{"id":"\(UUID())","playlistID":"\(playlistID)","name":"Known","url":"http://example.com/a.mp4","groupName":"Movies","kindRawValue":1},
           "status":"completed","method":"file","addedOn":"2026-11-01T10:00:00Z","fraction":1,"bytesWritten":10,"bytesOnDisk":10,
           "failureIsPermanent":false,"allowsCellular":false,"automaticRetries":0,"isMissing":false},
          {"id":"\(olderBuild)","item":{"id":"\(UUID())","playlistID":"\(playlistID)","url":"http://example.com/b.mp4"},
           "status":"failed","addedOn":"2026-10-01T10:00:00Z","failureReason":{"other":{"_0":"unknown error"}}},
          {"id":"\(newerBuild)","item":{"id":"\(UUID())","playlistID":"\(playlistID)","name":"Later","url":"http://example.com/c.mp4","kindRawValue":2},
           "status":"uploading","method":"teleport","addedOn":"2026-12-01T10:00:00Z","failureReason":{"quantum":{}},"futureField":42},
          {"id":"\(broken)","item":{"id":"\(UUID())","playlistID":"\(playlistID)"},"status":"completed"},
          17
        ]
        """.utf8)
    }

    @Test("Readable records are kept in order; the others are counted, with the id that could be read")
    func lenientReading() throws {
        let read = DownloadManifest.decode(manifest)
        #expect(read.records.map(\.id) == [known, olderBuild, newerBuild])
        #expect(read.unreadableCount == 2)
        #expect(read.unreadableIDs == [broken])
        #expect(read.unreadableWithoutID == 1)
        #expect(!read.isUnreadableFile)
        #expect(!read.knowsEveryRecord, "no orphan sweep while a record's id is unknown")
    }

    @Test("Fields an earlier build did not write take their defaults; its failure text reads as a sentence")
    func earlierBuild() throws {
        let older = try #require(DownloadManifest.decode(manifest).records.first { $0.id == olderBuild })
        #expect(older.fraction == 0)
        #expect(older.automaticRetries == 0)
        #expect(older.item.groupName == "")
        #expect(older.item.kind == .movie)
        #expect(older.failureMessage == DownloadFailure.Reason.unexpectedMessage)
    }

    @Test("Values of a later build: failed, to probe again, an unexpected stop")
    func laterBuild() throws {
        let newer = try #require(DownloadManifest.decode(manifest).records.first { $0.id == newerBuild })
        #expect(newer.status == .failed)
        #expect(newer.method == nil)
        #expect(newer.failureReason == .unexpected)
    }

    @Test("A file that is not a list is unreadable as a whole", arguments: ["", "{}", "not json", "\"text\""])
    func unreadableFile(_ content: String) {
        let read = DownloadManifest.decode(Data(content.utf8))
        #expect(read.isUnreadableFile)
        #expect(read.records.isEmpty)
    }

    @Test("Writing keeps the records this build cannot read, unchanged")
    func writeKeepsUnreadableRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fluxo-tests-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        try manifest.write(to: DownloadManifest.url(in: folder))
        var read = DownloadManifest.read(in: folder)
        try DownloadManifest.write(Array(read.records.prefix(1)), keeping: &read, in: folder)

        let again = DownloadManifest.read(in: folder)
        #expect(again.records.map(\.id) == [known])
        #expect(again.unreadableIDs == [broken])
        #expect(again.unreadableCount == 2)
    }
}
