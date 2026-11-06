//
//  DebugSeeder.swift
//  Fluxo
//
//  Debug harness: fills an isolated library for `-FluxoDebugSeed` (playlists through the real importer, then
//  favorites, watch history and a few recordings), and imports `-FluxoDebugImportPlaylist`.
//

#if DEBUG
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import os
import SwiftData

@MainActor
enum DebugSeeder {

    struct Services {
        let importCenter: PlaylistImportCenter
        let library: ChannelLibrary
        let recordings: RecordingStore
        let modelContext: ModelContext
    }

    static func seed(_ seed: DebugLaunchOptions.Seed, environment: DebugEnvironment, testStreamBaseURL: URL, services: Services, status: (String) -> Void) async {
        let logger = DebugLaunchOptions.logger
        if environment.mode == .scratch, ((try? services.modelContext.fetchCount(FetchDescriptor<Playlist>())) ?? 0) > 0 {
            logger.notice("The scratch library already has playlists; not seeding it again")
            return
        }
        let clock = ContinuousClock()
        let startedAt = clock.now

        status("Generating the \(seed.rawValue) library…")
        let directory = environment.seedDirectory
        // Drawing the artwork and writing the files stays off the main thread.
        let files: [(name: String, url: URL)] = await Task.detached(priority: .userInitiated) {
            DebugSeedCatalog.playlists(seed, testStreamBaseURL: testStreamBaseURL).enumerated().compactMap { index, playlist in
                let url = directory.appendingPathComponent("playlist-\(index + 1).m3u")
                do {
                    try Data(playlist.m3u.utf8).write(to: url, options: .atomic)
                    return (playlist.name, url)
                } catch {
                    logger.error("Could not write \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
        }.value

        for file in files {
            status("Importing \(file.name)…")
            do {
                let summary = try await services.importCenter.addPlaylist(name: file.name, url: file.url)
                logger.notice("Seeded \(file.name, privacy: .public): \(summary.channelCount) entries in \(summary.groupCount) groups")
            } catch {
                logger.error("Could not seed \(file.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        status("Adding favorites, history and recordings…")
        // The first name of each list ends up the most recent.
        for name in DebugSeedCatalog.favoriteNames.reversed() {
            if let item = channel(named: name, in: services.modelContext) {
                services.library.setFavorite(true, for: item)
            }
        }
        for name in DebugSeedCatalog.historyNames.reversed() {
            if let item = channel(named: name, in: services.modelContext) {
                services.library.recordWatch(item)
            }
        }
        let recordingLogos = DebugSeedCatalog.recordingTitles.reduce(into: [String: String]()) { logos, title in
            logos[title] = channel(named: title, in: services.modelContext)?.logo
        }
        await DebugRecordingFactory.addRecordings(titled: DebugSeedCatalog.recordingTitles, logos: recordingLogos, to: services.recordings)
        logger.notice("Seeded the \(seed.rawValue, privacy: .public) library in \(String(describing: clock.now - startedAt), privacy: .public)")
    }

    static func importPlaylist(from url: URL, services: Services, status: (String) -> Void) async {
        let name = url.deletingPathExtension().lastPathComponent.isEmpty ? (url.host() ?? "Playlist") : url.deletingPathExtension().lastPathComponent
        status("Importing \(name)…")
        do {
            let summary = try await services.importCenter.addPlaylist(name: name, url: url)
            DebugLaunchOptions.logger.notice("Imported \(url.absoluteString, privacy: .public): \(summary.channelCount) entries")
        } catch {
            DebugLaunchOptions.logger.error("Could not import \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A visible entry whose name is `name`, or starts with it.
    static func channel(named name: String, in context: ModelContext) -> ChannelItem? {
        let importIDs = ((try? context.fetch(FetchDescriptor<Playlist>())) ?? []).compactMap(\.currentImportID)
        let optionalName: String? = name
        var exact = FetchDescriptor<PlaylistChannel>(predicate: #Predicate { importIDs.contains($0.importID) && $0.name == optionalName })
        exact.fetchLimit = 1
        if let channel = try? context.fetch(exact).first {
            return ChannelItem(channel)
        }
        var matches = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { importIDs.contains($0.importID) && $0.name?.localizedStandardContains(name) == true },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        matches.fetchLimit = 200
        let candidates = (try? context.fetch(matches)) ?? []
        let channel = candidates.first { $0.name?.hasPrefix(name) == true } ?? candidates.first
        return channel.map(ChannelItem.init)
    }
}

/// Short synthetic MP4 clips (a colored frame with a moving bar), listed as finished recordings.
enum DebugRecordingFactory {

    @MainActor
    /// - Parameter logos: the logo of each title's channel (the artwork of its card).
    static func addRecordings(titled titles: [String], logos: [String: String] = [:], to store: RecordingStore) async {
        for (index, title) in titles.enumerated() {
            let createdOn = Date.now.addingTimeInterval(TimeInterval(-86_400 * index - 3_600))
            let url = store.makeRecordingURL(channelName: title, date: createdOn).deletingPathExtension().appendingPathExtension("mp4")
            let hue = Double(DebugArtwork.stableHash(title) % 360) / 360
            do {
                let startedAt = ContinuousClock.now
                let duration = try await Task.detached(priority: .userInitiated) {
                    try await writeClip(to: url, hue: hue, seconds: 4)
                }.value
                store.debugAddRecording(at: url, title: title, logo: logos[title], createdOn: createdOn, duration: duration)
                DebugLaunchOptions.logger.notice("Wrote the recording \(title, privacy: .public) in \(String(describing: ContinuousClock.now - startedAt), privacy: .public)")
            } catch {
                DebugLaunchOptions.logger.error("Could not write the recording \(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @concurrent private static func writeClip(to url: URL, hue: Double, seconds: Int) async throws -> TimeInterval {
        let width = 320
        let height = 180
        let fps: Int32 = 15
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: width, height: height)
        ))
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(fps) * seconds
        let (red, green, blue) = rgb(hue: hue)
        for frame in 0..<frameCount {
            guard let pool = receiver.pixelBufferPool else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            let mutableBuffer = try pool.makeMutablePixelBuffer()
            mutableBuffer.withUnsafeBuffer { buffer in
                CVPixelBufferLockBaseAddress(buffer, [])
                if let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ) {
                    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    let progress = CGFloat(frame) / CGFloat(frameCount)
                    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.85)
                    context.fill(CGRect(x: progress * CGFloat(width - 24), y: 0, width: 24, height: CGFloat(height)))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
            }
            // Waits until the input is ready for more media data.
            try await receiver.append(CVReadOnlyPixelBuffer(mutableBuffer), with: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        receiver.finish()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return TimeInterval(seconds)
    }

    private static func rgb(hue: Double) -> (CGFloat, CGFloat, CGFloat) {
        let sector = hue * 6
        let x = 1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: (r, g, b) = (1, x, 0)
        case 1: (r, g, b) = (x, 1, 0)
        case 2: (r, g, b) = (0, 1, x)
        case 3: (r, g, b) = (0, x, 1)
        case 4: (r, g, b) = (x, 0, 1)
        default: (r, g, b) = (1, 0, x)
        }
        // Not too bright, so the white bar stands out.
        return (CGFloat(r * 0.6), CGFloat(g * 0.6), CGFloat(b * 0.6))
    }
}
#endif
