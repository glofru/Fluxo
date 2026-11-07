//
//  InAppReminderAlerts.swift
//  Fluxo
//
//  Reminders on Apple TV. tvOS lets an app's notifications badge its icon but never show text, so a reminder is an
//  alert the app shows itself, while it runs: the TV is the screen the viewer watches, and Fluxo is usually in front
//  when a programme they set a reminder for is about to start. One timer waits for the next fire date (no polling);
//  the reminders are armed again at every launch (`persistsAcrossLaunches` is false), from the stored rows.
//

#if os(tvOS)
import Foundation
import UserNotifications

typealias PlatformReminderDelivery = InAppReminderAlerts

@MainActor
final class InAppReminderAlerts: ReminderDelivery {

    var onOpen: ((OpenedReminder) -> Void)?
    var onDue: ((ReminderAlert) -> Void)?

    let persistsAcrossLaunches = false

    /// The scheduled alerts, by key.
    private var pending: [String: ReminderAlert] = [:]
    private var timer: Task<Void, Never>?

    func install() {}

    /// No permission is needed for the app's own alerts.
    func authorizationStatus() async -> UNAuthorizationStatus {
        .authorized
    }

    func requestAuthorization() async -> UNAuthorizationStatus {
        .authorized
    }

    func schedule(_ alert: ReminderAlert) async throws {
        pending[alert.key] = alert
        armTimer()
    }

    func remove(keys: [String]) {
        for key in keys {
            pending[key] = nil
        }
        armTimer()
    }

    func pendingKeys() async -> Set<String> {
        Set(pending.keys)
    }

    /// Waits for the earliest fire date, delivers what is due, then waits for the next one.
    private func armTimer() {
        timer?.cancel()
        guard let next = pending.values.map(\.fireDate).min() else {
            timer = nil
            return
        }
        timer = Task { [weak self] in
            let delay = max(0, next.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else {
                return
            }
            self?.deliverDueAlerts()
        }
    }

    /// Delivers every alert that is due, the earliest programme first: `ReminderCenter` shows them one after the
    /// other (programmes that start together). Timers do not run while the app is suspended, so after a return to
    /// Fluxo past their fire dates several can be due at once; those whose programme is over are dropped
    /// (`ReminderAlert.isTimely(at:)`).
    private func deliverDueAlerts() {
        let now = Date.now
        let due = pending.values.filter { $0.fireDate <= now }
        for alert in due {
            pending[alert.key] = nil
        }
        for alert in due.sorted(by: { $0.start < $1.start }) where alert.isTimely(at: now) {
            onDue?(alert)
        }
        armTimer()
    }
}
#endif
