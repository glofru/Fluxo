//
//  ScrubPreviewProvider.swift
//  Fluxo
//
//  Frame previews over the scrubber while it is dragged, for movies and episodes AVPlayer plays itself (MP4 /
//  MOV files, from the network or a download): `AVAssetImageGenerator` on the item's own asset, at most one
//  frame in flight, only the latest position wanted, key frames for network files (they need the least media).
//  Media through the remux engine has no previews: its input is read by the engine alone (servers often allow a
//  single connection), so the scrubber only shows the time there.
//

import AVFoundation
import CoreGraphics
import Observation
import OSLog

private let previewLogger = Logger(subsystem: "dev.watermelon.Fluxo", category: "ScrubPreview")

@MainActor
@Observable
final class ScrubPreviewProvider {
    /// The latest preview frame (of `imageTime`), nil before the first one of a drag or without previews.
    private(set) var image: CGImage?
    private(set) var imageTime: TimeInterval?
    /// Previews are made for the current drag.
    private(set) var isActive = false

    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private weak var asset: AVURLAsset?
    @ObservationIgnored private var isLocal = false
    @ObservationIgnored private var wanted: TimeInterval?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Tells the task of the current drag from one that `end()` abandoned and that may still be finishing.
    @ObservationIgnored private var generation = 0
    /// Frames made in earlier drags of the same asset, by bucket of `bucketDuration`.
    @ObservationIgnored private var cache: [Int: CGImage] = [:]
    @ObservationIgnored private var cacheOrder: [Int] = []
    /// Consecutive failures: a server that refuses another connection gets no more requests for this asset.
    @ObservationIgnored private var failures = 0

    static let maximumSize = CGSize(width: 320, height: 320)
    static let cacheLimit = 24

    private var bucketDuration: TimeInterval {
        isLocal ? 1 : 4
    }

    /// How far a preview may be from the position under the finger and still show as its frame: the bucket of the
    /// cache, or the key frame tolerance of a network file. Beyond it the frame is of another place (the finger
    /// moved on while it was made, or it is the previous drag's): the scrubber dims it.
    var matchTolerance: TimeInterval {
        isLocal ? 1.5 : 6
    }

    /// Whether the preview shows about `time`.
    func matches(_ time: TimeInterval) -> Bool {
        guard let imageTime else {
            return false
        }
        return abs(imageTime - time) <= matchTolerance
    }

    /// The scrubber was touched: previews of `asset` (the playing item's) start.
    func begin(asset: AVURLAsset, isLocal: Bool) {
        if self.asset !== asset {
            cache.removeAll()
            cacheOrder.removeAll()
            failures = 0
            generator = nil
        }
        self.asset = asset
        self.isLocal = isLocal
        guard failures < 2 else {
            isActive = false
            return
        }
        if generator == nil {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = Self.maximumSize
            // A local file decodes the frame there; a network file shows the nearest key frame, which needs no
            // media before it.
            let tolerance = isLocal ? CMTime(value: 1, timescale: 2) : CMTime(value: 4, timescale: 1)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            self.generator = generator
        }
        image = nil
        imageTime = nil
        isActive = true
    }

    /// The finger is at `time`: a frame of about there is made (the latest position only).
    func request(_ time: TimeInterval) {
        guard isActive, time.isFinite else {
            return
        }
        let bucket = Int((time / bucketDuration).rounded(.down))
        if let cached = cache[bucket] {
            image = cached
            imageTime = Double(bucket) * bucketDuration
            wanted = nil
            return
        }
        wanted = time
        guard task == nil else {
            return
        }
        let generation = generation
        task = Task { [weak self] in
            await self?.generateWanted(generation: generation)
        }
    }

    /// The scrubber was released: the frame in progress is abandoned.
    func end() {
        isActive = false
        wanted = nil
        generation += 1
        task?.cancel()
        task = nil
        generator?.cancelAllCGImageGeneration()
        image = nil
        imageTime = nil
    }

    /// Playback stopped or changed: the frames of the previous item are dropped.
    func reset() {
        end()
        generator = nil
        asset = nil
        cache.removeAll()
        cacheOrder.removeAll()
        failures = 0
    }

    private func generateWanted(generation: Int) async {
        defer {
            // Only its own reference: after end() and a new drag, `task` is the newer drag's.
            if self.generation == generation {
                task = nil
            }
        }
        while isActive, self.generation == generation, let time = wanted, let generator {
            if !isLocal {
                // A finger still moving: only where it rests a moment is worth a network read.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, isActive, self.generation == generation, let latest = wanted else {
                    return
                }
                if abs(latest - time) > bucketDuration {
                    continue
                }
            }
            wanted = nil
            do {
                let (frame, actual) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                guard !Task.isCancelled, isActive, self.generation == generation else {
                    return
                }
                failures = 0
                let shown = actual.isNumeric ? actual.seconds : time
                store(frame, at: shown)
                image = frame
                imageTime = shown
            } catch {
                guard !Task.isCancelled, isActive, self.generation == generation else {
                    return
                }
                failures += 1
                previewLogger.info("No preview at \(time, format: .fixed(precision: 1)) s: \(error.localizedDescription, privacy: .public)")
                if failures >= 2 {
                    isActive = false
                    image = nil
                    return
                }
            }
        }
    }

    private func store(_ frame: CGImage, at time: TimeInterval) {
        let bucket = Int((time / bucketDuration).rounded(.down))
        if cache[bucket] == nil {
            cacheOrder.append(bucket)
        }
        cache[bucket] = frame
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
