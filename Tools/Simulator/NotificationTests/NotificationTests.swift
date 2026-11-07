//
//  NotificationTests.swift
//  NotificationTests
//
//  Reminder notifications opened the way a viewer opens them (see ../notification-tests.sh): Fluxo sets a reminder
//  through the debug harness (`reminder-soon:`, a real local notification a few seconds later), the system shows the
//  banner, and the test taps it, with Fluxo in the foreground, in the background, and terminated (the system then
//  launches it from the notification, without the harness arguments: `-FluxoDebugNextLaunch` hands the scratch
//  library and the routes of that launch over). Every case checks that Fluxo keeps running and plays the reminder's
//  channel, or, for a reminder deleted in the meantime, shows the TV guide with "Reminder Not Found".
//
//  Screenshots of the steps go to $FLUXO_SHOTS (default /tmp/fluxo-shots/notification-tests).
//

import XCTest

// XCUIApplication and the elements it finds are main-actor isolated: the tests run on the main actor.
@MainActor
final class NotificationTests: XCTestCase {

    let out = ProcessInfo.processInfo.environment["FLUXO_SHOTS"] ?? "/tmp/fluxo-shots/notification-tests"
    let fluxo = XCUIApplication(bundleIdentifier: "dev.watermelon.Fluxo")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// The seeded channel the reminders are set on, and how long after the route its notification fires: longer
    /// than the wait for the permission alert (`allowNotificationsIfAsked`), so the test already waits for the banner
    /// when it shows (it stays a few seconds; after that only Notification Center has it).
    let channel = "Rai 1 HD"
    let fireDelay = 20

    override func setUp() async throws {
        continueAfterFailure = false
        fluxo.terminate()
    }

    override func tearDown() async throws {
        fluxo.terminate()
    }

    // MARK: - Cases

    /// The banner shows over Fluxo, which is in front; a tap plays the channel.
    func testReminderOpenedInForeground() {
        launch(store: "memory", route: "seed-guide;reminder-soon:\(channel),\(fireDelay)")
        allowNotificationsIfAsked()
        shot("foreground-1-scheduled")
        openBanner(name: "foreground")
        expectChannelPlays(name: "foreground")
    }

    /// Fluxo is in the background (the Home Screen in front): a tap brings it back and plays the channel.
    func testReminderOpenedFromBackground() {
        launch(store: "memory", route: "seed-guide;reminder-soon:\(channel),\(fireDelay)")
        allowNotificationsIfAsked()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(fluxo.wait(for: .runningBackgroundSuspended, timeout: 10) || fluxo.state == .runningBackground, "Fluxo went to the background")
        shot("background-1-home")
        openBanner(name: "background")
        expectChannelPlays(name: "background")
    }

    /// Fluxo is not running: the tap launches it (a cold launch delivers the response during startup) and it plays
    /// the channel.
    func testReminderOpenedAfterTermination() {
        launch(store: "scratch", route: "seed-guide;reminder-soon:\(channel),\(fireDelay + 6)", nextLaunch: "wait:6;expect-player")
        allowNotificationsIfAsked()
        fluxo.terminate()
        XCTAssertEqual(fluxo.state, .notRunning, "Fluxo was terminated")
        shot("terminated-1-home")
        openBanner(name: "terminated")
        expectChannelPlays(name: "terminated")
    }

    /// Fluxo is not running and the reminder was deleted after its notification was scheduled (`reminder-forget:`
    /// leaves the notification, as a reminder deleted on another device, or one whose programme ended long ago, does):
    /// the tap launches Fluxo, which shows the TV guide and says why nothing plays, and keeps running.
    func testDeletedReminderOpenedAfterTermination() {
        launch(store: "scratch", route: "seed-guide;reminder-soon:\(channel),\(fireDelay + 6);reminder-forget:\(channel)", nextLaunch: "wait:4;modals-log")
        allowNotificationsIfAsked()
        fluxo.terminate()
        XCTAssertEqual(fluxo.state, .notRunning, "Fluxo was terminated")
        shot("deleted-1-home")
        openBanner(name: "deleted")
        XCTAssertTrue(fluxo.wait(for: .runningForeground, timeout: 20), "Fluxo launched from the notification")
        XCTAssertTrue(fluxo.alerts["Reminder Not Found"].waitForExistence(timeout: 10), "Fluxo says that the reminder no longer exists")
        let message = fluxo.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "no longer exists")).firstMatch
        XCTAssertTrue(message.exists, "the alert explains why nothing plays")
        shot("deleted-2-opened")
        fluxo.alerts.buttons["OK"].tap()
        XCTAssertFalse(fluxo.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'player.'")).firstMatch.exists, "nothing plays")
        sleep(3)
        shot("deleted-3-guide")
        XCTAssertEqual(fluxo.state, .runningForeground, "Fluxo is still running after the alert")
    }

    // MARK: - Steps

    func launch(store: String, route: String, nextLaunch: String? = nil) {
        fluxo.launchArguments = ["-FluxoDebugStore", store, "-FluxoDebugSeed", "sample", "-FluxoDebugRoute", route, "-FluxoDebugAppearance", "light"]
        if let nextLaunch {
            fluxo.launchArguments += ["-FluxoDebugNextLaunch", nextLaunch]
        }
        fluxo.launch()
        XCTAssertTrue(fluxo.wait(for: .runningForeground, timeout: 20), "Fluxo launched")
    }

    /// Answers the notification permission alert (the first reminder asks), if it shows.
    func allowNotificationsIfAsked() {
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) {
            shot("permission")
            allow.tap()
        }
        // The harness schedules the reminder once the permission is answered.
        sleep(3)
    }

    /// Waits for Fluxo's banner and taps it. Only the banner: on the Simulator a tap on a notification in
    /// Notification Center (the cover sheet) does not open the app under XCUITest, so every case schedules its
    /// notification to show while the test waits for it.
    func openBanner(name: String) {
        let banner = notification(in: springboard)
        let shows = banner.waitForExistence(timeout: TimeInterval(fireDelay + 30))
        if !shows {
            // To adapt the query to another release.
            try? springboard.debugDescription.write(toFile: "\(out)/\(name)-springboard.txt", atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(shows, "Fluxo's reminder banner shows")
        shot("\(name)-2-banner")
        banner.tap()
    }

    /// Fluxo's reminder notification on screen: its subtitle is the channel name.
    func notification(in springboard: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", channel)
        return springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").matching(predicate).firstMatch
    }

    /// Fluxo is in front, keeps running, and the player is up with the reminder's channel.
    func expectChannelPlays(name: String) {
        XCTAssertTrue(fluxo.wait(for: .runningForeground, timeout: 20), "Fluxo is in front after the tap")
        sleep(3)
        shot("\(name)-3-opened")
        let player = fluxo.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'player.'")).firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10), "the player is up")
        sleep(6)
        shot("\(name)-4-later")
        XCTAssertEqual(fluxo.state, .runningForeground, "Fluxo is still running 9 s after the tap")
    }

    func shot(_ name: String) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
}
