//
//  SettingsViewModel.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-06.
//

import SwiftUI

class SettingsViewModel: ObservableObject {

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hls", isDirectory: true)
    @Published var appFolderSize: Int = 0

    init() {
        self.appFolderSize = fetchAppFolderSize()
    }

    private func fetchAppFolderSize() -> Int {
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
        appFolderSize = fetchAppFolderSize()
    }
}
