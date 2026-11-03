//
//  ReminderCenter.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import Observation
import os
import SwiftData
import UserNotifications

/// Programme reminders: a `ProgrammeReminder` row plus a local notification `leadMinutes` before the programme
/// starts. Tapping the notification (or its Watch action) plays the channel: `channelToOpen` is set and the
/// root view plays it.
///
/// The keys of the reminders are kept in memory (there are few), so every programme cell can show its bell
/// without a fetch of its own.
@MainActor
@Observable
final class ReminderCenter {

    nonisolated static let leadMinutesKey = "guide.reminderLeadMinutes"
    nonisolated static let defaultLeadMinutes = 5
    nonisolated static let leadChoices = [0, 5, 10, 15, 30]
    nonisolated static let categoryIdentifier = "fluxo.programme-reminder"
    nonisolated static let watchActionIdentifier = "fluxo.programme-reminder.watch"

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Reminders")

    /// Keys (`GuideProgramme.reminderKey`) of the scheduled reminders.
    private(set) var keys: Set<String> = []
    /// Set when a reminder notification was opened; the root view plays it and clears it.
    var channelToOpen: ChannelItem?
    /// Last authorization state seen, for the reminders screen.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Set when scheduling failed because notifications are off, so the UI can explain it.
    var isShowingPermissionHint = false

    @ObservationIgnored
    private let container: ModelContainer
    @ObservationIgnored
    private let delegate = ReminderNotificationDelegate()
    @ObservationIgnored
    private var didStart = false

    init(container: ModelContainer) {
        self.container = container
    }

    nonisolated static var leadMinutes: Int {
        let value = UserDefaults.fluxo.object(forKey: leadMinutesKey) as? Int
        return value ?? defaultLeadMinutes
    }

    /// Installs the notification delegate, drops reminders of programmes that are over and re-reads the
    /// authorization. Call once at launch (before a notification response can arrive).
    func start() {
        guard !didStart else {
            return
        }
        didStart = true
        delegate.onOpen = { [weak self] key in
            self?.open(reminderKey: key)
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let watch = UNNotificationAction(identifier: Self.watchActionIdentifier, title: String(localized: "Watch"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [watch], intentIdentifiers: [])])
        pruneEndedReminders()
        reloadKeys()
        Task {
            await refreshAuthorization()
        }
    }

    func isScheduled(_ programme: GuideProgramme) -> Bool {
        keys.contains(programme.reminderKey)
    }

    /// Whether a reminder can still be set (the programme has not started).
    nonisolated static func canRemind(_ programme: GuideProgramme, now: Date = .now) -> Bool {
        programme.start > now
    }

    func toggle(_ programme: GuideProgramme, on channel: ChannelItem) async {
        if isScheduled(programme) {
            cancel(key: programme.reminderKey)
        } else {
            await schedule(programme, on: channel)
        }
    }

    /// Asks for permission if needed, stores the reminder and schedules its notification.
    @discardableResult
    func schedule(_ programme: GuideProgramme, on channel: ChannelItem) async -> Bool {
        guard Self.canRemind(programme), let channelURL = channel.url else {
            return false
        }
        guard await requestAuthorizationIfNeeded() else {
            isShowingPermissionHint = true
            return false
        }
        let key = programme.reminderKey
        let fireDate = Self.fireDate(for: programme.start)
        let context = container.mainContext
        if let existing = try? context.fetch(EPGQueries.reminder(key: key)).first {
            context.delete(existing)
        }
        context.insert(ProgrammeReminder(key: key, programme: programme, channel: channel, channelURL: channelURL, fireDate: fireDate))
        save()
        keys.insert(key)

        let content = Self.notificationContent(key: key, title: programme.title, channel: channel, start: programme.start)
        let interval = max(1, fireDate.timeIntervalSinceNow)
        let request = UNNotificationRequest(identifier: key, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            Self.logger.error("Could not schedule a reminder: \(error.localizedDescription, privacy: .public)")
            cancel(key: key)
            return false
        }
    }

    func cancel(key: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [key])
        let context = container.mainContext
        if let reminder = try? context.fetch(EPGQueries.reminder(key: key)).first {
            context.delete(reminder)
            save()
        }
        keys.remove(key)
    }

    func cancelAll() {
        let all = Array(keys)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: all)
        try? container.mainContext.delete(model: ProgrammeReminder.self)
        save()
        keys.removeAll()
    }

    /// Reschedules every pending reminder, e.g. after the lead time changed.
    func rescheduleAll() async {
        let reminders = (try? container.mainContext.fetch(EPGQueries.reminders())) ?? []
        for reminder in reminders where reminder.start > .now {
            reminder.fireDate = Self.fireDate(for: reminder.start)
            let content = Self.notificationContent(key: reminder.key, title: reminder.title, channel: reminder.channel, start: reminder.start)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.fireDate.timeIntervalSinceNow), repeats: false)
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminder.key, content: content, trigger: trigger))
        }
        save()
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Private

    private func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        authorization = status
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    private func reloadKeys() {
        let now = Date.now
        let reminders = (try? container.mainContext.fetch(EPGQueries.reminders())) ?? []
        keys = Set(reminders.filter { $0.stop > now }.map(\.key))
    }

    /// Plays the channel of an opened reminder notification. The notification only carries the reminder key;
    /// the channel (whose stream URL may embed account credentials) stays in the app's store.
    private func open(reminderKey key: String) {
        guard let reminder = try? container.mainContext.fetch(EPGQueries.reminder(key: key)).first else {
            Self.logger.notice("An opened reminder no longer exists")
            return
        }
        channelToOpen = reminder.channel
    }

    /// Reminders of programmes that ended a while ago (their notification fired or was missed). Recently ended
    /// ones stay a little, so a notification opened late still finds its channel.
    private func pruneEndedReminders() {
        let cutoff = Date.now.addingTimeInterval(-Self.endedReminderRetention)
        try? container.mainContext.delete(model: ProgrammeReminder.self, where: #Predicate { $0.stop < cutoff })
        save()
    }

    /// How long a reminder is kept after its programme ended.
    private static let endedReminderRetention: TimeInterval = 12 * 3_600

    private func save() {
        do {
            try container.mainContext.save()
        } catch {
            Self.logger.error("Could not save reminders: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func notificationContent(key: String, title: String, channel: ChannelItem, start: Date) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = channel.displayName
        content.body = body(start: start, leadMinutes: leadMinutes)
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = "fluxo.reminders"
        content.userInfo = ReminderNotificationDelegate.userInfo(reminderKey: key)
        return content
    }

    nonisolated static func fireDate(for start: Date, leadMinutes: Int = ReminderCenter.leadMinutes) -> Date {
        max(Date.now.addingTimeInterval(1), start.addingTimeInterval(-TimeInterval(leadMinutes * 60)))
    }

    nonisolated static func body(start: Date, leadMinutes: Int) -> String {
        let time = start.formatted(date: .omitted, time: .shortened)
        if leadMinutes == 0 {
            return String(localized: "Starting now (\(time)).")
        }
        return String(localized: "Starts in \(leadMinutes) minutes, at \(time).")
    }
}

/// Receives notification taps. A separate NSObject because `UNUserNotificationCenterDelegate` needs one.
final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    /// Set at launch (`ReminderCenter.start()`, from the app initializer, so a cold launch from a notification
    /// is handled too); called on the main actor with the key of the opened reminder.
    @MainActor var onOpen: ((String) -> Void)?

    private static let reminderKeyField = "reminderKey"

    /// Only the reminder key: the system keeps delivered notifications, and the channel's stream URL can embed
    /// the account's user name and password.
    static func userInfo(reminderKey key: String) -> [String: String] {
        [reminderKeyField: key]
    }

    static func reminderKey(from userInfo: [AnyHashable: Any]) -> String? {
        (userInfo[reminderKeyField] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard content.categoryIdentifier == ReminderCenter.categoryIdentifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == ReminderCenter.watchActionIdentifier else {
            return
        }
        // The request identifier is the reminder key too.
        let key = Self.reminderKey(from: content.userInfo) ?? response.notification.request.identifier
        await MainActor.run {
            onOpen?(key)
        }
    }
}
