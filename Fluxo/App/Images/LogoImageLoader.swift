//
//  LogoImageLoader.swift
//  Fluxo
//
//  Shared loader for channel logos and posters.
//
//  - Decoded images live in a cost-bounded NSCache (evicted under memory pressure, and emptied on iOS
//    memory warnings and when the app goes to the background).
//  - Downloaded bytes go through a dedicated on-disk URLCache, so logos survive relaunches without
//    being kept in memory twice.
//  - Every image is decoded with ImageIO straight to the size it is displayed at
//    (CGImageSourceCreateThumbnailAtIndex), never at the full resolution of the source.
//  - Concurrent requests for the same image share one load, and a load is cancelled as soon as the
//    last view waiting for it disappears.
//  - Inline `data:image/...` logos are decoded off the main thread too.
//
//  The file has no SwiftUI dependency so that it can be benchmarked outside the app (Tools/ImageLoaderBenchmark).
//

import CoreGraphics
import Foundation
import ImageIO
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// How the image is fitted into its frame; decides which edge the decoded size is based on.
enum LogoContentMode: Sendable {
    /// The whole image is visible (letterboxed): the longest edge must fit.
    case fit
    /// The image covers the frame (cropped): the shortest edge must cover it.
    case fill
}

/// One image at one display size.
struct LogoRequest: Hashable, Sendable {

    enum Source: Hashable, Sendable {
        case remote(URL)
        /// A local file (the artwork kept with an offline download).
        case file(URL)
        /// The full `data:` URI.
        case inline(String)
    }

    let source: Source
    /// Target size in pixels.
    let pixelWidth: Int
    let pixelHeight: Int
    let contentMode: LogoContentMode
    /// Cache key of the decoded image (source + size + mode).
    let key: String
    /// Cache key of the source only, used to remember images that cannot be loaded.
    let sourceKey: String

    /// The only folder local artwork is read from: the downloads (`DownloadRecord.artworkFileName`).
    private static let localArtworkFolder = DownloadCenter.defaultDirectory.standardizedFileURL.path + "/"

    /// Returns nil for sources that cannot be an image (empty, unsupported scheme, not a data:image URI).
    init?(source string: String?, pointSize: CGSize, scale: CGFloat, contentMode: LogoContentMode) {
        guard let string, !string.isEmpty, pointSize.width > 0, pointSize.height > 0 else {
            return nil
        }
        if string.hasPrefix("data:") {
            guard string.hasPrefix("data:image") else {
                return nil
            }
            source = .inline(string)
            // Data URIs can be tens of KB: key them by length and a hash of the payload instead of the full text.
            var hasher = Hasher()
            hasher.combine(string)
            sourceKey = "data:\(string.utf8.count):\(String(UInt(bitPattern: hasher.finalize()), radix: 36))"
        } else {
            guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "file" else {
                return nil
            }
            if scheme == "file" {
                // Only the artwork kept with a download: a playlist's own `file://` logo is not read.
                guard url.standardizedFileURL.path.hasPrefix(Self.localArtworkFolder) else {
                    return nil
                }
                source = .file(url)
            } else {
                source = .remote(url)
            }
            sourceKey = url.absoluteString
        }
        let scale = max(1, scale)
        // Rounded up to 8 px, so that nearly identical frames share one decoded image.
        pixelWidth = Self.roundUp(pointSize.width * scale)
        pixelHeight = Self.roundUp(pointSize.height * scale)
        self.contentMode = contentMode
        key = "\(sourceKey)|\(pixelWidth)x\(pixelHeight)|\(contentMode == .fit ? "fit" : "fill")"
    }

    private static func roundUp(_ value: CGFloat) -> Int {
        let pixels = Int(value.rounded(.up))
        return max(8, (pixels + 7) / 8 * 8)
    }
}

/// Unchecked `Sendable`: the caches (`NSCache`, `URLCache`) and the session are thread-safe, and the mutable state
/// (`inFlight`, `statistics`) is only read and written under `lock`.
final class LogoImageLoader: @unchecked Sendable {

    static let shared = LogoImageLoader()

    /// Counters for Tools/ImageLoaderBenchmark; only maintained in debug builds and the benchmark.
    struct Statistics: Sendable {
        var memoryHits = 0
        /// Loads of http(s) logos (served by the disk cache or the network).
        var remoteLoads = 0
        var inlineDecodes = 0
        /// Requests that joined a load already in flight.
        var joinedLoads = 0
        /// Loads cancelled because nobody was waiting for them any more.
        var cancelledLoads = 0
        var failures = 0
        /// Bytes of the source images that were decoded.
        var sourceBytes = 0
        /// Bytes of the decoded (downsampled) bitmaps.
        var decodedBytes = 0
    }

    /// Largest source image accepted; bigger downloads are not decoded.
    static let maximumSourceBytes = 16 * 1024 * 1024

    let urlCache: URLCache

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "LogoImageLoader")

    private let memoryCache = NSCache<NSString, CachedImage>()
    /// Sources that failed to load (HTTP error, not an image): not retried while the entry lives.
    private let failedSources = NSCache<NSString, NSNumber>()
    private let session: URLSession

    // Guarded by `lock`.
    private let lock = NSLock()
    private var inFlight: [String: InFlightLoad] = [:]
    private var statistics = Statistics()

    #if canImport(UIKit)
    private var observers: [any NSObjectProtocol] = []
    #endif

    /// - Parameters:
    ///   - memoryCostLimit: bytes of decoded bitmaps kept in memory.
    ///   - diskCapacity: bytes of downloaded images kept on disk.
    ///   - cacheDirectory: directory of the disk cache; defaults to Caches/LogoImages.
    init(memoryCostLimit: Int = LogoImageLoader.defaultMemoryCostLimit, diskCapacity: Int = 200 * 1024 * 1024, cacheDirectory: URL? = nil) {
        memoryCache.totalCostLimit = memoryCostLimit
        memoryCache.countLimit = 600
        memoryCache.name = "dev.watermelon.Fluxo.LogoImages"
        failedSources.countLimit = 2_000

        let directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LogoImages", isDirectory: true)
        // Our own memory cache holds the decoded bitmaps: keeping the compressed bytes in memory too would be waste.
        urlCache = URLCache(memoryCapacity: 0, diskCapacity: diskCapacity, directory: directory)

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = urlCache
        // Logos rarely change: use the disk copy whatever its age, so scrolling never refetches.
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        // A logo URL that points at an endless resource (a stream by mistake) must not download for days.
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        #if canImport(UIKit)
        let center = NotificationCenter.default
        let trim: @Sendable (Notification) -> Void = { [weak self] _ in
            self?.removeAllFromMemory()
        }
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil, using: trim))
        // Smaller footprint in the background makes the app less likely to be terminated (PiP keeps playing).
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: trim))
        #endif
    }

    deinit {
        #if canImport(UIKit)
        observers.forEach(NotificationCenter.default.removeObserver)
        #endif
        session.invalidateAndCancel()
    }

    static var defaultMemoryCostLimit: Int {
        // About 1.5% of the device memory, between 24 and 96 MB.
        let budget = Int(min(Double(Int.max), Double(ProcessInfo.processInfo.physicalMemory) * 0.015))
        return min(96 * 1024 * 1024, max(24 * 1024 * 1024, budget))
    }

    // MARK: - Lookup

    /// The decoded image if it is in memory. Cheap enough to call from a view body.
    func cachedImage(for request: LogoRequest) -> CGImage? {
        guard let image = memoryCache.object(forKey: request.key as NSString)?.image else {
            return nil
        }
        record { $0.memoryHits += 1 }
        return image
    }

    /// True when the source is known to fail; the view can show its fallback right away.
    func hasFailed(_ request: LogoRequest) -> Bool {
        failedSources.object(forKey: request.sourceKey as NSString) != nil
    }

    /// Loads the image at the requested size. Returns nil when it cannot be loaded or when the calling
    /// task is cancelled (the shared load is cancelled too once nobody waits for it).
    @concurrent func image(for request: LogoRequest) async -> CGImage? {
        if let image = cachedImage(for: request) {
            return image
        }
        if hasFailed(request) {
            return nil
        }
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                enqueue(request, waiter: waiter, continuation: continuation)
            }
        } onCancel: {
            cancel(waiter: waiter, key: request.key)
        }
    }

    // MARK: - Maintenance

    func removeAllFromMemory() {
        memoryCache.removeAllObjects()
        failedSources.removeAllObjects()
    }

    /// Empties the memory and disk caches.
    func removeAll() {
        removeAllFromMemory()
        urlCache.removeAllCachedResponses()
    }

    var diskUsage: Int {
        urlCache.currentDiskUsage
    }

    func currentStatistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        return statistics
    }

    var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.count
    }

    // MARK: - Request coalescing

    /// Unchecked `Sendable`: its properties are only read and written under `lock` (the detached load task captures it
    /// to complete it).
    private final class InFlightLoad: @unchecked Sendable {
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
    }

    private func enqueue(_ request: LogoRequest, waiter: UUID, continuation: CheckedContinuation<CGImage?, Never>) {
        lock.lock()
        // The cancellation handler may already have run (before this waiter existed).
        if Task.isCancelled {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        if let load = inFlight[request.key] {
            load.waiters[waiter] = continuation
            statistics.joinedLoads += 1
            lock.unlock()
            return
        }
        let load = InFlightLoad()
        load.waiters[waiter] = continuation
        inFlight[request.key] = load
        // Created under the lock so that a cancellation always finds the task; it starts asynchronously.
        load.task = Task.detached(priority: .utility) { [weak self] in
            let image = await self?.load(request)
            self?.complete(request, load: load, image: image)
        }
        lock.unlock()
    }

    private func cancel(waiter: UUID, key: String) {
        lock.lock()
        guard let load = inFlight[key], let continuation = load.waiters.removeValue(forKey: waiter) else {
            lock.unlock()
            return
        }
        var abandoned: Task<Void, Never>?
        if load.waiters.isEmpty {
            abandoned = load.task
            inFlight[key] = nil
            statistics.cancelledLoads += 1
        }
        lock.unlock()
        // Outside the lock: cancelling runs the load's own cancellation handlers synchronously.
        abandoned?.cancel()
        continuation.resume(returning: nil)
    }

    private func complete(_ request: LogoRequest, load: InFlightLoad, image: CGImage?) {
        if let image {
            memoryCache.setObject(CachedImage(image), forKey: request.key as NSString, cost: Self.cost(of: image))
        }
        lock.lock()
        if inFlight[request.key] === load {
            inFlight[request.key] = nil
        }
        let waiters = load.waiters
        load.waiters = [:]
        lock.unlock()
        for continuation in waiters.values {
            continuation.resume(returning: image)
        }
    }

    // MARK: - Loading

    private enum LoadFailure: Error {
        case httpStatus(Int)
        case tooLarge
        case invalidData
    }

    @concurrent private func load(_ request: LogoRequest) async -> CGImage? {
        do {
            let data: Data
            switch request.source {
            case .remote(let url):
                data = try await download(url)
                record { $0.remoteLoads += 1 }
            case .file(let url):
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            case .inline(let uri):
                guard let decoded = Self.decodeDataURI(uri) else {
                    throw LoadFailure.invalidData
                }
                data = decoded
                record { $0.inlineDecodes += 1 }
            }
            try Task.checkCancellation()
            guard let image = Self.downsample(data, to: request) else {
                throw LoadFailure.invalidData
            }
            let sourceBytes = data.count
            let decodedBytes = Self.cost(of: image)
            record {
                $0.sourceBytes += sourceBytes
                $0.decodedBytes += decodedBytes
            }
            return image
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                return nil
            }
            // Offline: try again later instead of remembering the logo as broken.
            if let urlError = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlError.code) {
                return nil
            }
            failedSources.setObject(1, forKey: request.sourceKey as NSString)
            record { $0.failures += 1 }
            Self.logger.debug("Logo failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @concurrent private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        // Streamed so that an oversized or endless body is abandoned at the cap, never held in memory whole.
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LoadFailure.httpStatus(http.statusCode)
        }
        let expectedLength = response.expectedContentLength
        guard expectedLength <= Int64(Self.maximumSourceBytes) else {
            throw LoadFailure.tooLarge
        }
        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maximumSourceBytes {
                throw LoadFailure.tooLarge
            }
        }
        return data
    }

    /// Updates the benchmark counters. Compiled out of release builds (the benchmark defines
    /// FLUXO_LOADER_STATISTICS), so a memory hit costs no lock round trip there.
    @inline(__always)
    private func record(_ update: (inout Statistics) -> Void) {
        #if DEBUG || FLUXO_LOADER_STATISTICS
        lock.lock()
        update(&statistics)
        lock.unlock()
        #endif
    }

    // MARK: - Decoding

    /// Decodes `data:image/<type>[;base64],<payload>`.
    static func decodeDataURI(_ uri: String) -> Data? {
        guard let comma = uri.firstIndex(of: ",") else {
            return nil
        }
        let header = uri[..<comma]
        var payload = String(uri[uri.index(after: comma)...])
        if payload.contains("%") {
            payload = payload.removingPercentEncoding ?? payload
        }
        if header.lowercased().hasSuffix(";base64") {
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }
        return payload.data(using: .utf8)
    }

    /// Decodes `data` directly at the size of `request` (never larger than the source).
    static func downsample(_ data: Data, to request: LogoRequest) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        var maxPixelSize = max(request.pixelWidth, request.pixelHeight)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           width > 0, height > 0 {
            var (sourceWidth, sourceHeight) = (width, height)
            if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
                // Rotated by 90 degrees: the displayed width is the stored height.
                swap(&sourceWidth, &sourceHeight)
            }
            let widthRatio = Double(request.pixelWidth) / sourceWidth
            let heightRatio = Double(request.pixelHeight) / sourceHeight
            let ratio = request.contentMode == .fit ? min(widthRatio, heightRatio) : max(widthRatio, heightRatio)
            let longestEdge = max(sourceWidth, sourceHeight)
            // Never upscale: a small logo is decoded at its own size.
            maxPixelSize = Int(min(longestEdge, (longestEdge * ratio).rounded(.up)))
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode now, on this background thread, instead of lazily at the first draw on the main thread.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as [CFString: Any] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }
}

/// NSCache needs a class value.
private final class CachedImage {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}
