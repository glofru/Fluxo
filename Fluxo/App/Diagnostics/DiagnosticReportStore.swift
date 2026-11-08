//
//  DiagnosticReportStore.swift
//  Fluxo
//
//  The diagnostic reports the system gives the app through MetricKit (`DiagnosticsCollector`): crashes, hangs, CPU,
//  disk-write and memory exceptions, slow launches, and the daily performance metrics. They are kept on this device
//  only, in a small ring buffer (Application Support/Diagnostics, outside the backups): at most `maximumCount` reports
//  and `maximumBytes`, none older than `maximumAge`, the oldest dropped first. Nothing is ever uploaded: Fluxo has no
//  analytics or crash service, and an export (`makeExport`) goes only where the user sends it from Settings › About ›
//  Diagnostic Reports.
//
//  Each report is one file, `<received, Unix ms, 13 digits>-<kind>-<8 hex>.json`, holding the report as MetricKit
//  encodes it: the name gives the order and the kind without reading the file, and no file timestamp is ever read.
//

import Foundation

/// One stored report.
struct DiagnosticReportEntry: Identifiable, Hashable, Sendable {

    enum Kind: String, CaseIterable, Sendable {
        case crash
        case hang
        case cpuException = "cpu"
        case diskWriteException = "disk-writes"
        case launch
        case memoryException = "memory"
        /// The daily performance metrics (launch and hang times, CPU, memory, disk and network use).
        case metrics
        /// A kind of report a later system adds.
        case other
    }

    /// The file name.
    let id: String
    let kind: Kind
    let receivedOn: Date
    let fileURL: URL
    let bytes: Int64
}

struct DiagnosticReportStore: Sendable {

    let directory: URL
    var maximumCount = 40
    var maximumBytes: Int64 = 8 * 1_024 * 1_024
    var maximumAge: TimeInterval = 90 * 86_400

    /// The app's reports (an isolated folder in a debug harness run).
    static var standard: DiagnosticReportStore {
        #if DEBUG
        if let root = DebugEnvironment.shared?.rootDirectory {
            return DiagnosticReportStore(directory: root.appendingPathComponent("Diagnostics", isDirectory: true))
        }
        #endif
        return DiagnosticReportStore(directory: URL.applicationSupportDirectory.appendingPathComponent("Diagnostics", isDirectory: true))
    }

    // MARK: - Writing

    /// Stores a report (its JSON as MetricKit encodes it), then drops what the limits leave out.
    @discardableResult
    func save(_ report: Data, kind: DiagnosticReportEntry.Kind, receivedOn: Date = .now) throws -> DiagnosticReportEntry {
        try prepareDirectory()
        let milliseconds = max(0, Int64((receivedOn.timeIntervalSince1970 * 1_000).rounded()))
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let name = String(format: "%013lld", milliseconds) + "-\(kind.rawValue)-\(suffix).json"
        let url = directory.appendingPathComponent(name)
        try report.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prune(now: receivedOn)
        return DiagnosticReportEntry(id: name, kind: kind, receivedOn: Date(timeIntervalSince1970: Double(milliseconds) / 1_000), fileURL: url, bytes: Int64(report.count))
    }

    /// Drops reports older than `maximumAge`, then the oldest until at most `maximumCount` and `maximumBytes` remain.
    func prune(now: Date = .now) {
        var kept: [DiagnosticReportEntry] = []
        var bytes: Int64 = 0
        for entry in entries() {
            let isTooOld = now.timeIntervalSince(entry.receivedOn) > maximumAge
            if isTooOld || kept.count >= maximumCount || bytes + entry.bytes > maximumBytes {
                try? FileManager.default.removeItem(at: entry.fileURL)
            } else {
                kept.append(entry)
                bytes += entry.bytes
            }
        }
    }

    func delete(_ entry: DiagnosticReportEntry) {
        try? FileManager.default.removeItem(at: entry.fileURL)
    }

    func deleteAll() {
        for entry in entries() {
            delete(entry)
        }
    }

    // MARK: - Reading

    /// The stored reports, newest first. Files of other names are left out (and left alone).
    func entries() -> [DiagnosticReportEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return files.compactMap(Self.entry(at:)).sorted { lhs, rhs in
            lhs.receivedOn != rhs.receivedOn ? lhs.receivedOn > rhs.receivedOn : lhs.id > rhs.id
        }
    }

    static func entry(at url: URL) -> DiagnosticReportEntry? {
        let name = url.lastPathComponent
        guard url.pathExtension == "json" else {
            return nil
        }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 13, let milliseconds = Int64(parts[0]) else {
            return nil
        }
        // The kind is everything before the last "-" (kinds may have one: "disk-writes").
        guard let lastDash = parts[1].lastIndex(of: "-") else {
            return nil
        }
        let kind = DiagnosticReportEntry.Kind(rawValue: String(parts[1][..<lastDash])) ?? .other
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return DiagnosticReportEntry(id: name, kind: kind, receivedOn: Date(timeIntervalSince1970: Double(milliseconds) / 1_000), fileURL: url, bytes: bytes)
    }

    // MARK: - Export

    /// One JSON file with every stored report, for the share sheet: the app's version and, per report, its kind, when
    /// it arrived and the report itself, unchanged. In a folder of its own in tmp (replaced at each export).
    func makeExport(appVersion: String, now: Date = .now) throws -> URL? {
        let entries = entries()
        guard !entries.isEmpty else {
            return nil
        }
        let dates = ISO8601DateFormatter()
        var json = Data()
        json.append(contentsOf: "{\"app\":".utf8)
        json.append(try JSONEncoder().encode("Fluxo \(appVersion)"))
        json.append(contentsOf: ",\"exportedOn\":\"\(dates.string(from: now))\",\"reports\":[".utf8)
        var isFirst = true
        for entry in entries.reversed() {
            guard let report = try? Data(contentsOf: entry.fileURL), (try? JSONSerialization.jsonObject(with: report, options: [.fragmentsAllowed])) != nil else {
                continue
            }
            if !isFirst {
                json.append(contentsOf: ",".utf8)
            }
            isFirst = false
            json.append(contentsOf: "{\"kind\":\"\(entry.kind.rawValue)\",\"receivedOn\":\"\(dates.string(from: entry.receivedOn))\",\"report\":".utf8)
            json.append(report)
            json.append(contentsOf: "}".utf8)
        }
        json.append(contentsOf: "]}".utf8)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Diagnostics Export", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let day = now.formatted(.iso8601.year().month().day())
        let name = TextParts.fileName(
            String(localized: "DiagnosticsExport.fileName", defaultValue: "Fluxo Diagnostics \(day)", comment: "Settings › About › Diagnostic Reports: file name of the shared reports (a JSON file), shown in the share sheet. The placeholder is a date such as 2026-11-08. Keep Fluxo as it is. Don't use / or : characters."),
            fallback: "Fluxo \(day)"
        )
        let url = folder.appendingPathComponent(name).appendingPathExtension("json")
        try json.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Folder

    private func prepareDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Diagnostics are not the user's data: never in a backup.
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
}
