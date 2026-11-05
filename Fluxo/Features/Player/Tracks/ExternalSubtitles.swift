//
//  ExternalSubtitles.swift
//  Fluxo
//
//  Subtitle files the user loads for a movie or an episode (Load Subtitle File… in the Audio and Subtitles
//  menu): the copy kept for the next time the same item plays, and the cues the player shows now.
//
//  The file is copied into the app's container (Application Support/Subtitles/<hash of the stream URL>/), so it
//  loads again by itself when the item plays again, even after the original is moved or deleted; the 200 most
//  recent are kept. The cues are drawn over the video by `SubtitleOverlay` in the system caption style. They
//  follow the playback with a boundary time observer (one callback per cue start and end, no polling) and are
//  looked up again after a seek.
//

import AVFoundation
import CryptoKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Subtitles")

/// A subtitle file that was loaded for an item.
struct ExternalSubtitleTrack: Equatable, Sendable {
    /// The file name as the user picked it ("Movie.en.srt").
    let fileName: String
    let file: SubtitleFile
    /// The file's contents, to keep it again for the item when it is chosen again.
    let data: Data

    static func == (lhs: ExternalSubtitleTrack, rhs: ExternalSubtitleTrack) -> Bool {
        lhs.fileName == rhs.fileName && lhs.data == rhs.data
    }

    /// The name shown in the menu: the file name without its extension.
    var title: String {
        (fileName as NSString).deletingPathExtension
    }
}

/// The copies of loaded subtitle files, one per item (stream URL).
enum ExternalSubtitleStore {

    static let maximumKeptFiles = 200

    /// Every read and change of the kept files, in the order they were asked for: choosing a file and then
    /// Off quickly must not leave the file kept.
    private static let queue = DispatchQueue(label: "Fluxo.ExternalSubtitleStore", qos: .utility)

    static var directory: URL {
        #if DEBUG
        if let environment = DebugEnvironment.shared {
            return environment.recordingsDirectory.deletingLastPathComponent().appendingPathComponent("Subtitles", isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Subtitles", isDirectory: true)
    }

    static func folder(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    }

    /// Reads and parses a file the user picked (a security-scoped URL from the file importer), and keeps a copy
    /// for `key`. Runs off the main actor.
    static func importFile(at url: URL, for key: String?) async throws -> ExternalSubtitleTrack {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize, size > SubtitleFile.maximumSize {
                throw SubtitleFile.ParseError.unreadable
            }
            let data = try Data(contentsOf: url)
            let file = try SubtitleFile(data: data, fileExtension: url.pathExtension)
            let fileName = url.lastPathComponent
            if let key {
                queue.sync {
                    save(data, fileName: fileName, for: key)
                }
            }
            return ExternalSubtitleTrack(fileName: fileName, file: file, data: data)
        }.value
    }

    /// The file kept for `key`, if any. Runs off the main actor.
    static func load(for key: String) async -> ExternalSubtitleTrack? {
        await withCheckedContinuation { continuation in
            queue.async {
                let folder = folder(for: key)
                guard let file = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first,
                      let data = try? Data(contentsOf: file),
                      let parsed = try? SubtitleFile(data: data, fileExtension: file.pathExtension) else {
                    continuation.resume(returning: nil)
                    return
                }
                // Recently used: kept by the pruning.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
                continuation.resume(returning: ExternalSubtitleTrack(fileName: file.lastPathComponent, file: parsed, data: data))
            }
        }
    }

    /// Keeps `track` for `key` again (chosen again after other subtitles).
    static func keep(_ track: ExternalSubtitleTrack, for key: String) {
        queue.async {
            save(track.data, fileName: track.fileName, for: key)
        }
    }

    /// Forgets the file kept for `key` (the user chose other subtitles or none).
    static func remove(for key: String) {
        let folder = folder(for: key)
        queue.async {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func save(_ data: Data, fileName: String, for key: String) {
        let fileManager = FileManager.default
        let folder = folder(for: key)
        do {
            try? fileManager.removeItem(at: folder)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            // Only the last path component, sanitized: never a path.
            let safeName = fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            try data.write(to: folder.appendingPathComponent(safeName.isEmpty ? "subtitles.srt" : safeName), options: .atomic)
            prune()
        } catch {
            logger.error("Could not keep the subtitle file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func prune() {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              folders.count > maximumKeptFiles else {
            return
        }
        let sorted = folders.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first > second
        }
        for folder in sorted.dropFirst(maximumKeptFiles) {
            try? fileManager.removeItem(at: folder)
        }
    }
}

/// Shows the cues of an external subtitle file in time with a player.
@MainActor
@Observable
final class ExternalSubtitlePlayback {

    /// The cues to draw now (empty between cues).
    private(set) var visibleCues: [SubtitleCue] = []
    /// Shifts every cue (positive: later), for files that are not quite in sync.
    var offset: TimeInterval = 0 {
        didSet {
            if offset != oldValue {
                restartObserver()
            }
        }
    }

    @ObservationIgnored private let file: SubtitleFile
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var boundaryObserver: Any?
    @ObservationIgnored private var jumpObserver: NSObjectProtocol?
    @ObservationIgnored private var itemObserver: NSKeyValueObservation?

    init(file: SubtitleFile, player: AVPlayer) {
        self.file = file
        self.player = player
        restartObserver()
        itemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.observeJumps()
                self?.refresh()
            }
        }
        observeJumps()
    }

    func stop() {
        if let boundaryObserver {
            player?.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
        if let jumpObserver {
            NotificationCenter.default.removeObserver(jumpObserver)
        }
        jumpObserver = nil
        itemObserver?.invalidate()
        itemObserver = nil
        visibleCues = []
    }

    private func restartObserver() {
        guard let player else {
            return
        }
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
        }
        // AVFoundation calls back as playback crosses each time: once per cue start and end.
        let times = file.changeTimes.map { NSValue(time: CMTime(seconds: max(0, $0 + offset), preferredTimescale: 1000)) }
        boundaryObserver = times.isEmpty ? nil : player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        refresh()
    }

    /// Seeks (and skips, scrubbing, a new item) are not boundary crossings: look the cues up again.
    private func observeJumps() {
        if let jumpObserver {
            NotificationCenter.default.removeObserver(jumpObserver)
        }
        jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: player?.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard let player, player.currentItem != nil else {
            visibleCues = []
            return
        }
        let time = player.currentTime().seconds
        // A boundary callback can come a hair before the cue time: look slightly ahead.
        let cues = time.isFinite ? file.cues(at: time - offset + 0.01) : []
        if cues != visibleCues {
            visibleCues = cues
        }
    }
}
