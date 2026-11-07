//
//  main.swift
//  ImageLoaderBenchmark
//
//  Compares the former logo path (full-size decode per view, no shared cache) with LogoImageLoader
//  (downsampled decode, bounded memory cache, request coalescing, cancellation). Built and run by run.sh
//  against a loopback-only HTTP server that serves 1024x1024 PNG logos.
//
//  Usage: image-loader-benchmark <base-url> <image-file> <count>
//

import CoreGraphics
import Darwin
import Foundation
import ImageIO

func footprintMegabytes() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let (seconds, attoseconds) = (ContinuousClock.now - start).components
    return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
}

/// What the old views did for every visible logo: fetch the bytes and decode the full image.
func legacyDecode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4, let count = Int(arguments[3]) else {
    print("usage: image-loader-benchmark <base-url> <image-file> <count>")
    exit(2)
}
let baseURL = arguments[1]
let imageData = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let dataURI = "data:image/png;base64," + imageData.base64EncodedString()
// A 75x75 pt logo on a 2x display, as in the channel strips.
let logoSize = CGSize(width: 75, height: 75)
let scale: CGFloat = 2

// Plain session without cache, like AsyncImage with the shared session for uncacheable responses.
let plainSession = URLSession(configuration: .ephemeral)

func runLegacy() async {
    let before = footprintMegabytes()
    let start = ContinuousClock.now
    var visible: [CGImage] = []
    var decodedBytes = 0
    for index in 0..<count {
        guard let url = URL(string: "\(baseURL)?legacy=\(index)"),
              let (data, _) = try? await plainSession.data(from: url),
              let image = legacyDecode(data) else {
            continue
        }
        decodedBytes += image.bytesPerRow * image.height
        visible.append(image)
    }
    // Inline logos: Data(contentsOf:) of the data: URL, decoded in full, on every render.
    var inlineMilliseconds = 0.0
    if let url = URL(string: dataURI) {
        let inlineStart = ContinuousClock.now
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: url), let image = legacyDecode(data) {
                visible.append(image)
            }
        }
        inlineMilliseconds = milliseconds(since: inlineStart) / 50
    }
    print(String(format: "legacy: %d remote logos decoded in full: %.0f ms, decoded %.1f MB, footprint +%.1f MB; data: URI decode per render %.2f ms",
                 count, milliseconds(since: start), Double(decodedBytes) / 1_048_576, footprintMegabytes() - before, inlineMilliseconds))
    withExtendedLifetime(visible) {}
}

func runLoader(_ loader: LogoImageLoader, label: String) async {
    let before = footprintMegabytes()
    let start = ContinuousClock.now
    var visible: [CGImage] = []
    for index in 0..<count {
        guard let request = LogoRequest(source: "\(baseURL)?logo=\(index)", pointSize: logoSize, scale: scale, contentMode: .fit),
              let image = await loader.image(for: request) else {
            continue
        }
        visible.append(image)
    }
    let statistics = loader.currentStatistics()
    print(String(format: "%@: %d remote logos at %dx%d px: %.0f ms, decoded %.2f MB (source %.1f MB), footprint +%.1f MB, remote loads %d, disk cache %.1f MB",
                 label, visible.count, visible.first?.width ?? 0, visible.first?.height ?? 0, milliseconds(since: start),
                 Double(statistics.decodedBytes) / 1_048_576, Double(statistics.sourceBytes) / 1_048_576,
                 footprintMegabytes() - before, statistics.remoteLoads, Double(loader.diskUsage) / 1_048_576))
    withExtendedLifetime(visible) {}
}

let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("fluxo-logo-bench-\(UUID().uuidString)", isDirectory: true)
defer {
    try? FileManager.default.removeItem(at: cacheDirectory)
}

await runLegacy()

let loader = LogoImageLoader(memoryCostLimit: 24 * 1024 * 1024, cacheDirectory: cacheDirectory)
await runLoader(loader, label: "loader (cold)")
// Memory cache emptied (e.g. memory warning): images come back from the disk cache, no network.
loader.removeAllFromMemory()
await runLoader(loader, label: "loader (disk cache)")

// Memory hits: the same requests again.
do {
    let start = ContinuousClock.now
    var hits = 0
    for index in 0..<count {
        if let request = LogoRequest(source: "\(baseURL)?logo=\(index)", pointSize: logoSize, scale: scale, contentMode: .fit),
           loader.cachedImage(for: request) != nil {
            hits += 1
        }
    }
    print(String(format: "memory cache: %d/%d synchronous hits in %.2f ms", hits, count, milliseconds(since: start)))
}

// Request coalescing: 40 views ask for the same new logo at once.
do {
    let before = loader.currentStatistics()
    guard let request = LogoRequest(source: "\(baseURL)?shared=1", pointSize: logoSize, scale: scale, contentMode: .fit) else {
        exit(1)
    }
    let results = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<40 {
            group.addTask { await loader.image(for: request) != nil }
        }
        var images = 0
        for await loaded in group where loaded {
            images += 1
        }
        return images
    }
    let after = loader.currentStatistics()
    print("coalescing: 40 concurrent requests -> \(results) images, \(after.remoteLoads - before.remoteLoads) load, \(after.joinedLoads - before.joinedLoads) joined")
}

// Cancellation: cells scrolled away before their logo arrived.
do {
    let before = loader.currentStatistics()
    let tasks = (0..<30).map { index in
        Task {
            await loader.image(for: LogoRequest(source: "\(baseURL)?cancel=\(index)", pointSize: logoSize, scale: scale, contentMode: .fit)!)
        }
    }
    // Let the loads start, then scroll the cells away.
    try? await Task.sleep(for: .milliseconds(15))
    tasks.forEach { $0.cancel() }
    var returned = 0
    for task in tasks where await task.value != nil {
        returned += 1
    }
    try? await Task.sleep(for: .milliseconds(300))
    let after = loader.currentStatistics()
    print("cancellation: 30 cancelled requests -> \(returned) images, \(after.cancelledLoads - before.cancelledLoads) loads cancelled, \(loader.inFlightCount) still in flight")
}

// Inline data: URI logos, decoded once off the main thread, then served from memory.
do {
    let start = ContinuousClock.now
    guard let request = LogoRequest(source: dataURI, pointSize: logoSize, scale: scale, contentMode: .fit) else {
        exit(1)
    }
    let image = await loader.image(for: request)
    let first = milliseconds(since: start)
    let hitStart = ContinuousClock.now
    for _ in 0..<50 {
        _ = loader.cachedImage(for: request)
    }
    print(String(format: "data: URI: first decode %.2f ms to %dx%d px, then %.4f ms per render (memory hit)",
                 first, image?.width ?? 0, image?.height ?? 0, milliseconds(since: hitStart) / 50))
}

// Memory bound: many distinct logos, nothing kept by views (cells recycled).
do {
    let before = footprintMegabytes()
    let bounded = LogoImageLoader(memoryCostLimit: 4 * 1024 * 1024, cacheDirectory: cacheDirectory.appendingPathComponent("bounded"))
    for index in 0..<count {
        guard let request = LogoRequest(source: "\(baseURL)?poster=\(index)", pointSize: CGSize(width: 180, height: 266), scale: 3, contentMode: .fill) else {
            continue
        }
        _ = await bounded.image(for: request)
    }
    print(String(format: "bounded cache (4 MB limit, %d posters at 180x266 pt @3x): footprint +%.1f MB", count, footprintMegabytes() - before))
}
