//
//  ReminderDelivery.swift
//  Fluxo
//
//  How a programme reminder reaches the viewer. `ReminderCenter` stores the reminders and decides when they fire;
//  a delivery shows them: system notifications on iPhone, iPad and Mac (`SystemReminderNotifications`), an alert in
//  the app on Apple TV (`InAppReminderAlerts`), where an app's notifications can only badge its icon.
//  `PlatformReminderDelivery` is the one of the platform the app is built for.
//

import Foundation
import UserNotifications

/// A reminder as the viewer sees it when it fires.
struct ReminderAlert: Identifiable, Equatable, Sendable {
    /// The reminder key (`GuideProgramme.reminderKey`), also the identifier of its notification.
    let key: String
    let title: String
    let channelName: String
    let start: Date
    let fireDate: Date

    var id: String {
        key
    }

    /// "Starts in 5 minutes, at 20:15." or "Starting now (20:15).", with the lead time set in Settings.
    var body: String {
        ReminderCenter.body(start: start, leadMinutes: ReminderCenter.leadMinutes)
    }
}

extension ReminderAlert {
    init(_ reminder: ProgrammeReminder) {
        self.init(key: reminder.key, title: reminder.title, channelName: reminder.channel.displayName, start: reminder.start, fireDate: reminder.fireDate)
    }
}

/// Shows reminders when they are due. Methods are called on the main actor by `ReminderCenter`.
@MainActor
protocol ReminderDelivery: AnyObject {
    /// Called with the key of a reminder the viewer opened (to play its channel).
    var onOpen: ((String) -> Void)? { get set }
    /// Called when a reminder is due and the app shows it itself (in-app alerts only).
    var onDue: ((ReminderAlert) -> Void)? { get set }
    /// Whether scheduled reminders survive the app's process (system notifications do; in-app alerts must be armed
    /// again at every launch).
    var persistsAcrossLaunches: Bool { get }

    /// Sets the delivery up. Called once, at launch, before a notification that launched the app is delivered.
    func install()
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Asks the viewer for permission; returns the status afterwards.
    func requestAuthorization() async -> UNAuthorizationStatus
    /// Schedules `alert` at its fire date, replacing a scheduled alert with the same key.
    func schedule(_ alert: ReminderAlert) async throws
    func remove(keys: [String])
    /// The keys of the reminders scheduled and not delivered yet.
    func pendingKeys() async -> Set<String>
}
