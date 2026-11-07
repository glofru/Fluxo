//
//  Stubs.swift
//  ImageLoaderBenchmark
//
//  What LogoImageLoader.swift uses from app sources the benchmark leaves out (Tools/ImageLoaderBenchmark/run.sh).
//

import Foundation

/// `Features/Downloads/DownloadCenter.swift`: the folder of the offline downloads, the only one the loader reads local
/// artwork from. The benchmark loads only remote logos.
enum DownloadCenter {
    nonisolated static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fluxo-image-bench-downloads", isDirectory: true)
    }
}
