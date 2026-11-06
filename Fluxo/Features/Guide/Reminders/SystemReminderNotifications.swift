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

    var onOpen: ((String) -> Void)? {
        get { delegate.onOpen }
        set { delegate.onOpen = newValue }
    }

    /// Never called: the system shows the notifications (also while the app is in the foreground).
    var onDue: ((ReminderAlert) -> Void)?

    let persistsAcrossLaunches = true

    private let delegate = ReminderNotificationDelegate()

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
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
final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {

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

    @concurrent func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    @concurrent func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
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
#endif
