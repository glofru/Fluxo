//
//  BackgroundActivity.swift
//  Fluxo
//
//  A UIKit background task, for work that should finish when the app leaves the foreground (a download
//  conversion, the Top Shelf).
//

#if canImport(UIKit)
import os
import UIKit

/// A UIKit background task that ends exactly once: when the work is done, or when its time runs out.
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        // The expiration handler runs on the main thread; it keeps the activity alive until it has ended.
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            DownloadCenter.logger.info("Background time ran out: \(name, privacy: .public) continues in the foreground")
            end()
        }
    }

    func end() {
        guard identifier != .invalid else {
            return
        }
        let ending = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(ending)
    }
}
#endif
