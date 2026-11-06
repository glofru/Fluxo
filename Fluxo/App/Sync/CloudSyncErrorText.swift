//
//  CloudSyncErrorText.swift
//  Fluxo
//
//  What the iCloud status row (Settings › iCloud, on every platform) says when a sync fails. The descriptions of
//  CloudKit's errors are often English developer text that is not localized ("Server Rejected Request", "Request
//  Rate Limited", zone and record messages), so the row says what happened in the user's language instead, and the
//  raw description goes to the log (`CloudSync`). The app's own errors (iCloud storage is full, a deletion that was
//  not confirmed) already describe themselves in the user's language and are kept.
//

import CloudKit
import Foundation

enum CloudSyncErrorText {

    /// The status line for `error`, in the user's language.
    static func message(for error: Error) -> String {
        if let error = error as? CKError {
            return message(for: error)
        }
        if let error = error as? URLError, isOffline(error.code) {
            return offline
        }
        // The app's own errors (`CloudKitSyncTransport.QuotaExceededError`, `ZoneDeletionError`, the simulated
        // cloud's): localized where they are made.
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return generic
    }

    private static func message(for error: CKError) -> String {
        switch error.code {
        case .partialFailure:
            // Says nothing itself: the first error of an item says what went wrong.
            if let first = error.partialErrorsByItemID?.values.first {
                return message(for: first)
            }
            return generic
        case .networkUnavailable, .networkFailure:
            return offline
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return String(localized: "iCloud is busy. Fluxo tries again shortly.", comment: "Settings › iCloud status: iCloud is busy or asked the app to slow down; the sync is retried by itself.")
        case .notAuthenticated:
            return String(localized: "Sign in to iCloud to sync", comment: "Settings › iCloud status: the device is not signed in to an Apple Account with iCloud.")
        case .accountTemporarilyUnavailable:
            return String(localized: "iCloud is not available right now", comment: "Settings › iCloud status: the account is temporarily unavailable (for example while it is being set up).")
        case .quotaExceeded:
            return CloudKitSyncTransport.QuotaExceededError().errorDescription ?? generic
        default:
            return generic
        }
    }

    private static func isOffline(_ code: URLError.Code) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut].contains(code)
    }

    private static var offline: String {
        String(localized: "No internet connection. Fluxo syncs when you're back online.", comment: "Settings › iCloud status: the device is offline; the sync goes on once it is connected again.")
    }

    private static var generic: String {
        String(localized: "Couldn't sync with iCloud. Try again later.", comment: "Settings › iCloud status: a sync failed for a reason the app cannot explain (the details are in the log).")
    }
}
