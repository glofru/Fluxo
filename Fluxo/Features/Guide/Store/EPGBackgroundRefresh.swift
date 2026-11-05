//
//  EPGBackgroundRefresh.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import os
#if !os(macOS)
import BackgroundTasks
#endif

/// Background app refresh of the TV guide (iOS, tvOS). The task is registered by the app scene
/// (`.backgroundTask(.appRefresh(taskIdentifier))`), its identifier is listed under
/// `BGTaskSchedulerPermittedIdentifiers` in Info.plist, and the `fetch` background mode is on. The next run is
/// requested whenever the app goes to the background and at the start of every run. macOS refreshes while the
/// app runs (`EPGStore`).
enum EPGBackgroundRefresh {

    static let taskIdentifier = "dev.watermelon.Fluxo.guide-refresh"
    /// The system decides when to run; this is only the earliest time.
    static let interval: TimeInterval = 6 * 3_600

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "EPGBackgroundRefresh")

    static func schedule() {
        #if !os(macOS)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Fails in the Simulator and when Background App Refresh is off: the guide refreshes at launch then.
            logger.info("Guide refresh not scheduled: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }
}
