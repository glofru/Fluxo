//
//  SettingsViewModel.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-06.
//

import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {

    /// Segments written by the remux engine (see AVPlayerViewModel).
    let streamFilesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hls", isDirectory: true)
    private(set) var streamFilesSize: Int = 0
    /// Bytes of channel logos in the on-disk image cache.
    private(set) var logoCacheSize: Int = 0

    /// Cheap on purpose: SwiftUI evaluates the `@State` initial value every time the parent rebuilds
    /// SettingsView. The sizes are computed by `refresh()` when the view appears.
    init() {}

    /// Measures the stream folder and the logo cache off the main thread.
    func refresh() async {
        let directory = streamFilesDirectory
        let (folderSize, logoSize) = await Task.detached(priority: .utility) {
            (Self.folderSize(at: directory), LogoImageLoader.shared.diskUsage)
        }.value
        streamFilesSize = folderSize
        logoCacheSize = logoSize
    }

    func clearLogoCache() {
        LogoImageLoader.shared.removeAll()
        logoCacheSize = LogoImageLoader.shared.diskUsage
    }

    /// Removes leftover stream segments. Only offered while nothing plays: a running session owns its files.
    func deleteStreamFiles() {
        StreamRemuxer.removeAllFiles(in: streamFilesDirectory)
        streamFilesSize = Self.folderSize(at: streamFilesDirectory)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    static var ffmpegVersion: String {
        String(cString: fluxo_remux_library_version())
    }

    private nonisolated static func folderSize(at url: URL) -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil) else {
            return 0
        }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(fileSize)
            }
        }
        return Int(total)
    }
}
