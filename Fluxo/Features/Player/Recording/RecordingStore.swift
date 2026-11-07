//
//  RecordingStore.swift
//  Fluxo
//
//  Lists, finalizes and deletes the stream recordings stored in Documents/Recordings.
//
//  The engine records to an MPEG-TS file, which stays usable even if the app is killed while
//  recording. When a recording is closed it is converted to MP4 (a fast stream copy) so that
//  AVPlayer can play it and seek in it directly. If the conversion fails the .ts file is kept and
//  played through the remux engine instead.
//

import Foundation
import Observation

struct Recording: Identifiable, Hashable {
    let url: URL
    let title: String
    /// The logo of the recorded channel (from its playlist entry); nil for recordings made before it was kept.
    var logo: String?
    let createdOn: Date
    let duration: TimeInterval?
    let bytes: Int64
    /// True while the recording is still being written or converted.
    let isFinalizing: Bool
    /// True while the engine still writes it (a recording in progress); false once it is being converted.
    var isRecording = false

    var id: URL {
        url
    }
}

@MainActor
@Observable
final class RecordingStore {

    private(set) var recordings: [Recording] = []
    private(set) var lastError: String?

    let directory: URL

    // Process-wide, so that no store ever finalizes, converts or deletes a file that the engine
    // (or another store of this process) still writes.
    /// Recordings currently written by the engine.
    private static var activeURLs: Set<URL> = []
    /// Recordings being converted to MP4.
    private static var finalizingURLs: Set<URL> = []
    private static var didRecoverInterruptedRecordings = false

    private static let mediaExtensions: Set<String> = ["mp4", "ts"]

    /// Name of the recordings folder in Documents. Never localized: the folder would
    /// change, and the recordings be lost, with the language.
    nonisolated static let folderName = "Recordings"

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        Self.excludeFromBackups(self.directory)
        reload()
        if !Self.didRecoverInterruptedRecordings, AppInstanceLock.isPrimaryInstance {
            // Only once per process, at launch, before any recording of this process starts, and
            // never while another instance of the app may be recording.
            Self.didRecoverInterruptedRecordings = true
            recoverInterruptedRecordings()
        }
    }

    /// Documents/Recordings (Caches/Recordings on Apple TV, see `PlatformStorage`), or the isolated recordings
    /// folder of a debug run (`-FluxoDebugStore`).
    private static var defaultDirectory: URL {
        #if DEBUG
        if let directory = DebugEnvironment.shared?.recordingsDirectory {
            return directory
        }
        #endif
        return PlatformStorage.userFilesDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Recordings stay out of the device's backups (iCloud, the Mac's): an hour of HD video is several GB, which would
    /// fill the user's iCloud storage, and what they recorded stays watchable in Fluxo on this device. Set on the
    /// folder, so it covers every recording in it.
    private static func excludeFromBackups(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Returns a new, unique file URL for a recording of `channelName`. The name is language-independent
    /// ("Recording-2026-11-03T20-15-00" without a channel name); the title shown is in the metadata.
    func makeRecordingURL(channelName: String?, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let base = "\(Self.sanitize(channelName ?? "Recording"))-\(formatter.string(from: date))"
        var url = directory.appendingPathComponent(base).appendingPathExtension("ts")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("mp4").path) {
            url = directory.appendingPathComponent("\(base)-\(suffix)").appendingPathExtension("ts")
            suffix += 1
        }
        return url
    }

    /// Marks `url` as being written by the engine. Without a `title` (a channel without a name), the list
    /// shows a localized "Recording from <date>". `logo` is the channel's, for the recording's artwork.
    func recordingDidStart(_ url: URL, title: String?, logo: String? = nil) {
        Self.activeURLs.insert(url)
        writeMetadata(RecordingMetadata(title: title, logo: logo, createdOn: Date(), duration: nil), for: url)
        reload()
    }

    /// Converts a complete .ts recording to MP4 in the background, then refreshes the list.
    func finalize(_ url: URL) {
        Self.activeURLs.remove(url)
        guard url.pathExtension.lowercased() == "ts", !Self.finalizingURLs.contains(url) else {
            reload()
            return
        }
        guard let size = Self.fileSize(of: url), size > 0 else {
            // Nothing was recorded (e.g. stopped before the first key frame).
            removeFiles(of: url)
            reload()
            return
        }

        Self.finalizingURLs.insert(url)
        reload()

        let mp4URL = url.deletingPathExtension().appendingPathExtension("mp4")
        let temporaryURL = Self.conversionURL(for: url)
        Task.detached(priority: .utility) { [weak self] in
            // Converted under a hidden name and renamed when complete, so that a partial MP4 is
            // never listed and never mistaken for a finished one after a crash.
            var result = Self.convert(url, to: temporaryURL)
            if case .success = result {
                do {
                    _ = try FileManager.default.replaceItemAt(mp4URL, withItemAt: temporaryURL)
                } catch {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    result = .failure(ConversionError(message: error.localizedDescription))
                }
            } else {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            await self?.conversionDidFinish(source: url, destination: mp4URL, result: result)
        }
    }

    func delete(_ recording: Recording) {
        guard !Self.activeURLs.contains(recording.url), !Self.finalizingURLs.contains(recording.url) else {
            return
        }
        removeFiles(of: recording.url)
        reload()
    }

    /// Deletes every recording that is neither being written nor being converted.
    func deleteAll() {
        for recording in recordings where !Self.activeURLs.contains(recording.url) && !Self.finalizingURLs.contains(recording.url) {
            removeFiles(of: recording.url)
        }
        reload()
    }

    /// Size of all recordings on disk.
    var totalBytes: Int64 {
        recordings.reduce(0) { $0 + $1.bytes }
    }

    func reload() {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        // Hidden files are metadata sidecars and conversions in progress.
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []

        recordings = files
            .filter { Self.mediaExtensions.contains($0.pathExtension.lowercased()) }
            .map { url -> Recording in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let metadata = readMetadata(for: url)
                let createdOn = metadata?.createdOn ?? values?.creationDate ?? Date()
                return Recording(
                    url: url,
                    title: Self.title(of: url, metadata: metadata, createdOn: createdOn),
                    logo: metadata?.logo,
                    createdOn: createdOn,
                    duration: metadata?.duration,
                    bytes: Int64(values?.fileSize ?? 0),
                    isFinalizing: Self.activeURLs.contains(url) || Self.finalizingURLs.contains(url),
                    isRecording: Self.activeURLs.contains(url)
                )
            }
            .sorted { $0.createdOn > $1.createdOn }
    }

    func clearError() {
        lastError = nil
    }

    #if DEBUG
    /// Debug harness: lists an existing media file of the recordings folder as a finished recording.
    func debugAddRecording(at url: URL, title: String, logo: String? = nil, createdOn: Date, duration: TimeInterval?) {
        writeMetadata(RecordingMetadata(title: title, logo: logo, createdOn: createdOn, duration: duration), for: url)
        reload()
    }
    #endif

    // MARK: - Private

    private func conversionDidFinish(source: URL, destination: URL, result: Result<TimeInterval, ConversionError>) {
        Self.finalizingURLs.remove(source)
        var metadata = readMetadata(for: source) ?? RecordingMetadata(title: nil, logo: nil, createdOn: Date(), duration: nil)
        switch result {
        case .success(let duration):
            metadata.duration = duration
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: Self.metadataURL(for: source))
            writeMetadata(metadata, for: destination)
        case .failure(let error):
            // Keep the MPEG-TS file: it is still playable through the remux engine.
            lastError = error.message
            metadata.conversionFailed = true
            writeMetadata(metadata, for: source)
        }
        reload()
    }

    /// Finalizes .ts files left behind by an interrupted session (e.g. the app was killed while recording).
    private func recoverInterruptedRecordings() {
        for recording in recordings where recording.url.pathExtension.lowercased() == "ts" {
            let url = recording.url
            guard !Self.activeURLs.contains(url), !Self.finalizingURLs.contains(url) else {
                continue
            }
            // A conversion that was cut short.
            try? FileManager.default.removeItem(at: Self.conversionURL(for: url))
            let mp4 = url.deletingPathExtension().appendingPathExtension("mp4")
            if !FileManager.default.fileExists(atPath: mp4.path) && readMetadata(for: url)?.conversionFailed != true {
                finalize(url)
            }
        }
    }

    private func removeFiles(of url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: Self.metadataURL(for: url))
    }

    private func readMetadata(for url: URL) -> RecordingMetadata? {
        guard let data = try? Data(contentsOf: Self.metadataURL(for: url)) else {
            return nil
        }
        return try? JSONDecoder().decode(RecordingMetadata.self, from: data)
    }

    private func writeMetadata(_ metadata: RecordingMetadata, for url: URL) {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return
        }
        try? data.write(to: Self.metadataURL(for: url), options: .atomic)
    }

    /// The title in the metadata; a localized "Recording from <date>" for a recording without one. A file without
    /// metadata (copied into the folder) shows its name.
    private static func title(of url: URL, metadata: RecordingMetadata?, createdOn: Date) -> String {
        guard let metadata else {
            return url.deletingPathExtension().lastPathComponent
        }
        // Earlier versions saved the file name ("Recording-2026-11-03T20-15-00") as the title of a recording
        // without a channel name.
        if let title = metadata.title, !title.isEmpty, title != url.deletingPathExtension().lastPathComponent {
            return title
        }
        let date = createdOn.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Recording from \(date)", comment: "Title of a recording of a channel that has no name; the placeholder is when it was recorded, such as Nov 3, 2026 at 20:15.")
    }

    private nonisolated static func metadataURL(for url: URL) -> URL {
        // Hidden sidecar, e.g. ".News-2026-11-02T10-00-00.json".
        url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).json")
    }

    /// Hidden file the MP4 is written to before it is renamed, e.g. ".News-2026-11-02T10-00-00.converting.mp4".
    private nonisolated static func conversionURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).converting.mp4")
    }

    private nonisolated static func fileSize(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(Int64.init) }
    }

    private nonisolated static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
            .split(whereSeparator: { $0 == " " })
            .joined(separator: "-")
        let trimmed = String(cleaned.prefix(48))
        return trimmed.isEmpty ? "Recording" : trimmed
    }

    struct ConversionError: Error {
        let message: String
    }

    private nonisolated static func convert(_ source: URL, to destination: URL) -> Result<TimeInterval, ConversionError> {
        try? FileManager.default.removeItem(at: destination)
        var duration: Double = 0
        var buffer = [CChar](repeating: 0, count: 512)
        let result = source.path.withCString { sourcePointer in
            destination.path.withCString { destinationPointer in
                buffer.withUnsafeMutableBufferPointer { bufferPointer in
                    fluxo_remux_convert_file(sourcePointer, destinationPointer, &duration, bufferPointer.baseAddress, Int32(bufferPointer.count))
                }
            }
        }
        guard result == 0 else {
            let message = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            return .failure(ConversionError(message: message.isEmpty
                ? String(localized: "Unable to save the recording.", comment: "Error while saving a recording.")
                : EngineMessage.localized(message)))
        }
        return .success(duration)
    }
}

private struct RecordingMetadata: Codable {
    /// Nil for a channel without a name (the title shown is then built in the current language).
    var title: String?
    /// The channel's logo (optional: sidecars written before it was kept have none).
    var logo: String?
    var createdOn: Date
    var duration: TimeInterval?
    var conversionFailed: Bool?
}
