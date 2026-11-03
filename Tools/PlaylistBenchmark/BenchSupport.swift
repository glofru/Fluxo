//
//  BenchSupport.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Darwin
import Foundation

enum Bench {
    static func peakRSSMegabytes() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576 // bytes on macOS
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    static func time(_ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        try body()
        return milliseconds(clock.now - start)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func temporaryStoreURL(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fluxo-bench-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("store.sqlite")
    }

    static func removeStore(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// Measures how long the main actor is blocked: the largest delay of a 5 ms main-actor tick.
@MainActor
final class MainThreadStallMonitor {
    private(set) var maxStallMilliseconds: Double = 0
    private var task: Task<Void, Never>?

    func start() {
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let before = clock.now
                try? await Task.sleep(for: .milliseconds(5))
                let stall = Bench.milliseconds(clock.now - before) - 5
                if let self, stall > self.maxStallMilliseconds {
                    self.maxStallMilliseconds = stall
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }
}
