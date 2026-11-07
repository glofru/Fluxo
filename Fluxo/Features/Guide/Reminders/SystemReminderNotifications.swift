//
//  SystemReminderNotifications.swift
//  Fluxo
//
//  Reminders as local notifications (iPhone, iPad, Mac), with a Watch action that plays the channel.
//

#if !os(tvOS)
import Foundation
import UserNotifications

typealias PlatformReminderDelivery = SystemReminderNotifications

@MainActor
final class SystemReminderNotifications: ReminderDelivery {

    var onOpen: ((OpenedReminder) -> Void)? {
        get { delegate.onOpen }
        set {
            delegate.onOpen = newValue
            delegate.deliverPendingOpens()
        }
    }

    /// Never called: the system shows the notifications (also while the app is in the foreground).
    var onDue: ((ReminderAlert) -> Void)?

    let persistsAcrossLaunches = true

    /// The app's one notification delegate, installed before the library opens (`installEarly`).
    private var delegate: ReminderNotificationDelegate {
        .shared
    }

    func install() {
        Self.installEarly()
    }

    /// Installs the notification delegate and the Watch action, once. A response that arrives before `onOpen` is
    /// set (a notification that launched the app while the library updates) waits in the delegate.
    static func installEarly() {
        let center = UNUserNotificationCenter.current()
        guard center.delegate !== ReminderNotificationDelegate.shared else {
            return
        }
        center.delegate = ReminderNotificationDelegate.shared
        let watch = UNNotificationAction(identifier: ReminderCenter.watchActionIdentifier, title: String(localized: "Watch"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: ReminderCenter.categoryIdentifier, actions: [watch], intentIdentifiers: [])])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> UNAuthorizationStatus {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await authorizationStatus()
    }

    func schedule(_ alert: ReminderAlert) async throws {
        let interval = max(1, alert.fireDate.timeIntervalSinceNow)
        let request = UNNotificationRequest(identifier: alert.key, content: Self.content(of: alert), trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        try await UNUserNotificationCenter.current().add(request)
    }

    func remove(keys: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: keys)
    }

    func pendingKeys() async -> Set<String> {
        Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
    }

    private static func content(of alert: ReminderAlert) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.channelName
        content.body = alert.body
        content.sound = .default
        content.categoryIdentifier = ReminderCenter.categoryIdentifier
        content.threadIdentifier = "fluxo.reminders"
        content.userInfo = ReminderNotificationDelegate.userInfo(reminderKey: alert.key)
        return content
    }
}

/// Receives notification taps. A separate NSObject because `UNUserNotificationCenterDelegate` needs one.
///
/// Main-actor isolated, and so is its answer to a tap: Swift implements an `async` delegate method with a task that
/// calls the system's completion handler when the method returns, on the executor it returns on. iOS requires that
/// completion handler on the main thread (it updates the app's snapshot); called from the cooperative pool (as by a
/// nonisolated or `@concurrent` method) it aborts the app as soon as the viewer opens a notification, most visibly
/// on a cold launch from it.
@MainActor
final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// The one delegate of the app: `UNUserNotificationCenter` keeps only a weak reference to it.
    static let shared = ReminderNotificationDelegate()

    /// Set at launch (`ReminderCenter.start()`, from the app initializer, so a cold launch from a notification
    /// is handled too); called with the reminder the viewer opened.
    var onOpen: ((OpenedReminder) -> Void)?

    /// Responses that arrived before `onOpen` was set, handed over when it is: at the launch that updates the
    /// library, `ReminderCenter` starts seconds after the system delivered the response that launched the app.
    private var pendingOpens: [OpenedReminder] = []

    private nonisolated static let reminderKeyField = "reminderKey"

    /// Only the reminder key: the system keeps delivered notifications, and the channel's stream URL can embed
    /// the account's user name and password.
    nonisolated static func userInfo(reminderKey key: String) -> [String: String] {
        [reminderKeyField: key]
    }

    /// The reminder key of a notification's payload: a non-empty string, or nil (another payload, an older or
    /// damaged one).
    nonisolated static func reminderKey(from userInfo: [AnyHashable: Any]) -> String? {
        (userInfo[reminderKeyField] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The reminder a notification response opens: nil for other notifications and other actions (dismissing it).
    nonisolated static func openedReminder(categoryIdentifier: String, actionIdentifier: String, requestIdentifier: String, userInfo: [AnyHashable: Any], title: String) -> OpenedReminder? {
        guard categoryIdentifier == ReminderCenter.categoryIdentifier,
              actionIdentifier == UNNotificationDefaultActionIdentifier || actionIdentifier == ReminderCenter.watchActionIdentifier else {
            return nil
        }
        // The request identifier is the reminder key too.
        guard let key = reminderKey(from: userInfo) ?? (requestIdentifier.isEmpty ? nil : requestIdentifier) else {
            return nil
        }
        return OpenedReminder(key: key, title: title.isEmpty ? nil : title)
    }

    /// Hands responses that arrived early over to `onOpen`, once it is set.
    func deliverPendingOpens() {
        guard let onOpen, !pendingOpens.isEmpty else {
            return
        }
        let opens = pendingOpens
        pendingOpens.removeAll()
        opens.forEach(onOpen)
    }

    /// Shows the banner while Fluxo is in front too. Off the main actor: it touches nothing of the app, and the
    /// system accepts its completion handler on any thread.
    @concurrent nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// On the main actor (see the type): the system's completion handler is then called on the main thread, after
    /// the reminder was handed to `ReminderCenter`, which only records what to play (the windows play it once they
    /// are on screen).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        guard let opened = Self.openedReminder(categoryIdentifier: request.content.categoryIdentifier, actionIdentifier: response.actionIdentifier, requestIdentifier: request.identifier, userInfo: request.content.userInfo, title: request.content.title) else {
            return
        }
        guard let onOpen else {
            pendingOpens.append(opened)
            return
        }
        onOpen(opened)
    }
}
#endif
