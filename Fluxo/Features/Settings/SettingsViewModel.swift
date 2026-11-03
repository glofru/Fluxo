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

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hls", isDirectory: true)
    var appFolderSize: Int = 0
    /// Bytes of channel logos in the on-disk image cache.
    var logoCacheSize: Int = 0

    /// Cheap on purpose: SwiftUI evaluates the `@State` initial value every time the parent rebuilds
    /// SettingsView. The sizes are computed by `refresh()` when the view appears.
    init() {}

    /// Measures the stream folder and the logo cache off the main thread.
    func refresh() async {
        let url = url
        let (folderSize, logoSize) = await Task.detached(priority: .utility) {
            (Self.folderSize(at: url), LogoImageLoader.shared.diskUsage)
        }.value
        appFolderSize = folderSize
        logoCacheSize = logoSize
    }

    func clearLogoCache() {
        LogoImageLoader.shared.removeAll()
        logoCacheSize = LogoImageLoader.shared.diskUsage
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

    func deleteAllDataInAppDirectory() {
        let fileManager = FileManager.default
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            for fileURL in fileURLs {
                try? fileManager.removeItem(at: fileURL)
            }
        } catch {
            // Optionally handle errors if needed
        }
        appFolderSize = Self.folderSize(at: url)
    }
}
