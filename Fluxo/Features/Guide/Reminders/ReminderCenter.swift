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

/// Programme reminders: a `ProgrammeReminder` row plus an alert `leadMinutes` before the programme starts, delivered
/// by `PlatformReminderDelivery`: a local notification on iPhone, iPad and Mac, an alert in the app on Apple TV.
/// Opening it (the notification, its Watch action, or Watch in the alert) plays the channel: `channelToOpen` is
/// set and the root view plays it.
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
    /// The language and time format the pending notifications were written in (`formatSignature`).
    nonisolated static let formatSignatureKey = "guide.reminderFormatSignature"

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Reminders")

    /// Keys (`GuideProgramme.reminderKey`) of the scheduled reminders.
    private(set) var keys: Set<String> = []
    /// Set when a reminder notification was opened; the root view plays it and clears it.
    var channelToOpen: ChannelItem?
    /// Last authorization state seen, for the reminders screen.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Set when scheduling failed because notifications are off, so the UI can explain it.
    var isShowingPermissionHint = false
    /// A reminder that is due now and that the app shows itself (Apple TV, where notifications cannot show text):
    /// the root view presents it, with Watch (`openDueReminder()`) and dismiss (`dismissDueReminder()`).
    private(set) var dueReminder: ReminderAlert?
    /// Reminders that became due while `dueReminder` was on screen (programmes that start together), the earliest
    /// programme first. Each shows in turn, unless its programme is over by then.
    @ObservationIgnored
    private var queuedDueReminders: [ReminderAlert] = []
    /// Shows the next queued reminder once the alert that closed has left the screen.
    @ObservationIgnored
    private var nextDueReminder: Task<Void, Never>?

    @ObservationIgnored
    private let container: ModelContainer
    @ObservationIgnored
    private let delivery = PlatformReminderDelivery()
    @ObservationIgnored
    private var didStart = false
    @ObservationIgnored
    private var localeObserver: (any NSObjectProtocol)?

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
        delivery.onOpen = { [weak self] key in
            self?.open(reminderKey: key)
        }
        delivery.onDue = { [weak self] alert in
            self?.enqueueDueReminder(alert)
        }
        delivery.install()
        pruneEndedReminders()
        reloadKeys()
        if !delivery.persistsAcrossLaunches {
            // In-app alerts live as long as the process: arm the stored reminders again.
            Task {
                await rescheduleAll()
            }
        }
        // The text of a notification is fixed when it is scheduled: rewrite the pending ones when the language
        // or the time format changed since (while the app was not running, or while it runs).
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rewritePendingNotificationsIfFormatChanged()
            }
        }
        rewritePendingNotificationsIfFormatChanged()
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

        do {
            try await delivery.schedule(ReminderAlert(key: key, title: programme.title, channelName: channel.displayName, start: programme.start, stop: programme.stop, fireDate: fireDate))
            return true
        } catch {
            Self.logger.error("Could not schedule a reminder: \(error.localizedDescription, privacy: .public)")
            cancel(key: key)
            return false
        }
    }

    func cancel(key: String) {
        delivery.remove(keys: [key])
        queuedDueReminders.removeAll { $0.key == key }
        if dueReminder?.key == key {
            closeDueReminder()
        }
        let context = container.mainContext
        if let reminder = try? context.fetch(EPGQueries.reminder(key: key)).first {
            context.delete(reminder)
            save()
        }
        keys.remove(key)
    }

    func cancelAll() {
        let all = Array(keys)
        delivery.remove(keys: all)
        queuedDueReminders.removeAll()
        nextDueReminder?.cancel()
        nextDueReminder = nil
        dueReminder = nil
        try? container.mainContext.delete(model: ProgrammeReminder.self)
        save()
        keys.removeAll()
    }

    /// Reschedules every pending reminder, e.g. after the lead time changed.
    func rescheduleAll() async {
        let reminders = (try? container.mainContext.fetch(EPGQueries.reminders())) ?? []
        for reminder in reminders where reminder.start > .now {
            reminder.fireDate = Self.fireDate(for: reminder.start)
            try? await delivery.schedule(ReminderAlert(reminder))
        }
        save()
    }

    /// Plays the channel of the reminder the app shows (`dueReminder`) and closes it.
    func openDueReminder() {
        guard let alert = dueReminder else {
            return
        }
        closeDueReminder()
        open(reminderKey: alert.key)
    }

    /// Closes the reminder the app shows without playing it.
    func dismissDueReminder() {
        // The alert's binding also calls this after a button closed it: nothing is on screen by then.
        guard dueReminder != nil else {
            return
        }
        closeDueReminder()
    }

    /// A reminder the app shows itself is due: it shows now, or after the one on screen.
    private func enqueueDueReminder(_ alert: ReminderAlert) {
        guard dueReminder?.key != alert.key, !queuedDueReminders.contains(where: { $0.key == alert.key }) else {
            return
        }
        queuedDueReminders.append(alert)
        queuedDueReminders.sort { $0.start < $1.start }
        if dueReminder == nil, nextDueReminder == nil {
            showNextDueReminder()
        }
    }

    private func showNextDueReminder() {
        nextDueReminder = nil
        let now = Date.now
        queuedDueReminders.removeAll { !$0.isTimely(at: now) }
        guard dueReminder == nil, !queuedDueReminders.isEmpty else {
            return
        }
        dueReminder = queuedDueReminders.removeFirst()
    }

    /// The alert on screen closes; the next queued one follows once it has gone (an alert presented while the one
    /// before it still animates away would not show).
    private func closeDueReminder() {
        dueReminder = nil
        guard !queuedDueReminders.isEmpty, nextDueReminder == nil else {
            return
        }
        nextDueReminder = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else {
                return
            }
            self?.showNextDueReminder()
        }
    }

    #if DEBUG
    /// Debug harness (`reminder-due:`): delivers the scheduled reminder `key` now, as its timer would.
    /// System notifications show themselves: only the app's own alerts (Apple TV) can be delivered so.
    func debugDeliverNow(key: String) -> Bool {
        guard !delivery.persistsAcrossLaunches, let reminder = try? container.mainContext.fetch(EPGQueries.reminder(key: key)).first else {
            return false
        }
        delivery.remove(keys: [key])
        enqueueDueReminder(ReminderAlert(reminder))
        return true
    }

    /// Debug harness: the reminders waiting behind the one on screen.
    var debugQueuedDueReminderCount: Int {
        queuedDueReminders.count
    }
    #endif

    /// Rewrites the pending notifications (same identifier, same fire date) when the language or the time
    /// format differs from the one they were written in. Delivered ones are left alone, and none is added.
    private func rewritePendingNotificationsIfFormatChanged() {
        let signature = Self.formatSignature
        let defaults = UserDefaults.fluxo
        guard defaults.string(forKey: Self.formatSignatureKey) != signature else {
            return
        }
        defaults.set(signature, forKey: Self.formatSignatureKey)
        guard !keys.isEmpty else {
            return
        }
        Task {
            let pending = await delivery.pendingKeys()
            let reminders = (try? container.mainContext.fetch(EPGQueries.reminders())) ?? []
            for reminder in reminders where pending.contains(reminder.key) && reminder.fireDate > .now {
                try? await delivery.schedule(ReminderAlert(reminder))
            }
        }
    }

    /// The app's language and the current time format ("en|h:mm a"): what the text of a notification depends on.
    private static var formatSignature: String {
        let language = Bundle.main.preferredLocalizations.first ?? ""
        let timeFormat = DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: .current) ?? ""
        return "\(language)|\(timeFormat)"
    }

    func refreshAuthorization() async {
        authorization = await delivery.authorizationStatus()
    }

    /// Whether scheduling a reminder would first ask for permission (system notifications that were never allowed
    /// or refused). Never on Apple TV, whose reminders are the app's own alerts (`InAppReminderAlerts`).
    func needsPermissionPrompt() async -> Bool {
        await delivery.authorizationStatus() == .notDetermined
    }

    // MARK: - Private

    private func requestAuthorizationIfNeeded() async -> Bool {
        var status = await delivery.authorizationStatus()
        if status == .notDetermined {
            status = await delivery.requestAuthorization()
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
