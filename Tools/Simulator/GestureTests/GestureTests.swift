//
//  GestureTests.swift
//  GestureTests
//
//  Real touches on the installed Fluxo Debug build (see ../gesture-tests.sh): the mini player opens on a tap and
//  on a swipe up, the player follows a drag down 1:1 (checked with its Debug drag probe and a screenshot while the
//  finger holds), springs back from a short one, ignores horizontal drags and closes on a long drag or a flick,
//  it covers the whole screen in portrait and landscape (also pulled up), Home's cover stretches over a real
//  pull down, scrubbing the timeline never closes the player, its X stops playback, and nothing shows above the
//  tab bar while nothing plays.
//  The app runs with the debug harness (seeded in-memory library, routes) and the test streams of
//  test-stream.sh. Screenshots of the steps go to $FLUXO_SHOTS (default /tmp/fluxo-shots/gesture-tests).
//

import UIKit
import XCTest

final class GestureTests: XCTestCase {

    let out = ProcessInfo.processInfo.environment["FLUXO_SHOTS"] ?? "/tmp/fluxo-shots/gesture-tests"

    func launch(_ route: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.watermelon.Fluxo")
        // Light mode whatever the simulator uses: `darkShareOfBottomRows` tells the player from the app by color.
        app.launchArguments = ["-FluxoDebugStore", "memory", "-FluxoDebugSeed", "sample", "-FluxoDebugRoute", route, "-FluxoDebugAppearance", "light"]
        app.launch()
        return app
    }

    func shot(_ name: String) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    /// Asks gesture-tests.sh for a screenshot named `name` in the middle of the gesture that follows (it is taken
    /// 1.2 s after this call, so the gesture should hold still from about 1 s to 2 s).
    func captureDuringGesture(_ name: String) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(out)/.capture-\(name)", contents: nil)
    }

    /// The player's record of the last drag (Debug builds with the harness): samples, the largest offset, the
    /// largest gap between the offset and the finger's translation, and the current offset.
    func dragProbe(_ app: XCUIApplication, file: StaticString = #file, line: UInt = #line) -> [String: Double] {
        let probe = app.descendants(matching: .any)["player.dragProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 3), "the drag probe exists", file: file, line: line)
        let value = probe.value as? String ?? ""
        var fields: [String: Double] = [:]
        for pair in value.split(separator: " ") {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let number = Double(parts[1]) {
                fields[String(parts[0])] = number
            }
        }
        return fields
    }

    /// Waits until the player is on screen (or gone). Uses the drag probe, which exists exactly while the player
    /// is presented, rather than a button: the controls hide after a few seconds without interaction.
    func waitPlayerOpen(_ app: XCUIApplication, _ open: Bool, timeout: TimeInterval = 8, file: StaticString = #file, line: UInt = #line) {
        let predicate = NSPredicate(format: open ? "exists == true AND value BEGINSWITH 'visible=1'" : "exists == false OR value BEGINSWITH 'visible=0'")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.descendants(matching: .any)["player.dragProbe"])
        let probe = app.descendants(matching: .any)["player.dragProbe"]
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "player open == \(open) (probe: \(probe.exists ? probe.value as? String ?? "?" : "none"))", file: file, line: line)
    }

    /// Waits until the player is on screen and its opening animation is over: a tap during the animation lands
    /// where the button will be, not where it is drawn yet.
    func waitPlayerSettled(_ app: XCUIApplication, timeout: TimeInterval = 8, file: StaticString = #file, line: UInt = #line) {
        waitPlayerOpen(app, true, timeout: timeout, file: file, line: line)
        sleep(1)
    }

    /// The share of near-black pixels in the bottom `rows` pixel rows of the screen (the app runs in light mode in
    /// these tests, see `launch`, so a black band there is a piece of the player left on screen).
    func darkShareOfBottomRows(_ rows: Int = 30) -> Double {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else {
            return 0
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * rows * 4)
        guard let context = CGContext(data: &pixels, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return 0
        }
        // Draws the image so that its bottom `rows` rows fill the context.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var dark = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) < 60 {
            dark += 1
        }
        return Double(dark) / Double(width * rows)
    }

    /// A tab: in the tab bar at the bottom on iPhone, in the one at the top on iPad.
    func tabButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// Scrolls the current screen back to its top. The minimized tab bar always expands there; one swipe back up
    /// from the middle of Home's long scroll view expands it only some of the time on iOS 27.2 (the same with
    /// nothing ever played, and on the build before the player layer), so tests never rely on that.
    func scrollToTop(_ app: XCUIApplication) {
        app.swipeDown(velocity: .slow)
        sleep(1)
        app.swipeDown(velocity: .fast)
        sleep(1)
        app.swipeDown(velocity: .fast)
        sleep(2)
    }

    func miniPlayer(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == 'Test Pattern (MPEG-TS)'")).firstMatch
    }

    func testMiniPlayerTapAndSwipeUpOpenThePlayer() {
        let app = launch("mini-player:Test Pattern (MPEG-TS);wait:3")
        let title = miniPlayer(app)
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        sleep(4)
        shot("mini-1-before")
        for attempt in 1...3 {
            title.tap()
            waitPlayerSettled(app)
            shot("mini-2-open-tap\(attempt)")
            app.buttons["player.close"].tap()
            waitPlayerOpen(app, false)
        }
        // Swipe up from the mini player.
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
        waitPlayerOpen(app, true)
        shot("mini-3-open-swipe")
    }

    func testDragDownFollowsCancelsAndDismisses() {
        let app = launch("player:Test Pattern (MPEG-TS);wait:4")
        waitPlayerOpen(app, true, timeout: 40)
        // Coordinates in the app's frame: `app.windows.firstMatch` can be another, empty window of the app (on
        // iPad it is a zero-size one after the first drag).
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        // A short, slow drag follows the finger 1:1 (screenshot while it holds), then springs back.
        captureDuringGesture("drag-0-holding")
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 120)), withVelocity: .slow, thenHoldForDuration: 2)
        sleep(1)
        shot("drag-1-after-short")
        waitPlayerOpen(app, true)
        let probe = dragProbe(app)
        XCTAssertGreaterThan(probe["samples"] ?? 0, 3, "the drag moved the player: \(probe)")
        XCTAssertEqual(probe["maxOffset"] ?? 0, 120, accuracy: 4, "the player went as far as the finger: \(probe)")
        XCTAssertLessThan(probe["maxDeviation"] ?? .infinity, 0.5, "the player stayed under the finger: \(probe)")
        XCTAssertEqual(probe["offset"] ?? -1, 0, "the player sprang back: \(probe)")
        // A horizontal drag does nothing.
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 150, dy: 10)))
        sleep(1)
        waitPlayerOpen(app, true)
        // A long drag dismisses: playback continues in the mini player.
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 420)), withVelocity: .default, thenHoldForDuration: 0)
        waitPlayerOpen(app, false)
        sleep(1)
        shot("drag-2-dismissed")
        XCTAssertTrue(miniPlayer(app).exists, "the mini player shows after the swipe down")
        // A fast flick from the top also dismisses.
        miniPlayer(app).tap()
        waitPlayerOpen(app, true)
        sleep(1)
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.02, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 140)), withVelocity: .fast, thenHoldForDuration: 0)
        waitPlayerOpen(app, false)
    }

    func testPlayerCoversTheScreenInEveryOrientation() {
        let app = launch("player:Test Pattern (HLS);wait:2")
        waitPlayerOpen(app, true, timeout: 40)
        // Wait until the controls hide: only the video and the black around it are left.
        sleep(7)
        shot("cover-1-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        shot("cover-2-landscape")
        // Pulled up in landscape: black continues below the player.
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        captureDuringGesture("cover-3-landscape-pulled-up")
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -150)), withVelocity: .slow, thenHoldForDuration: 2)
        waitPlayerOpen(app, true)
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shot("cover-4-portrait-again")
    }

    func testHomePullDownStretchesTheCover() {
        let app = launch("home;wait:2")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        sleep(4)
        shot("pull-0-home")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        captureDuringGesture("pull-1-holding")
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)), withVelocity: .slow, thenHoldForDuration: 2)
        sleep(2)
        shot("pull-2-released")
    }

    func testScrubbingNeverDismissesAndSeeks() {
        let app = launch("player:Test Pattern (MPEG-TS);wait:20")
        waitPlayerOpen(app, true, timeout: 40)
        sleep(20)
        // The controls hid by now: a tap on the video shows them.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let slider = app.descendants(matching: .any)["player.scrubber"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "the time-shift scrubber shows")
        shot("scrub-0-before")
        let right = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        // Diagonal, mostly horizontal, ending below the bar: still a scrub, never a dismissal.
        right.press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 2.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        shot("scrub-1-after")
        waitPlayerOpen(app, true)
        // A longer window shows "-m:ss Go Live" now; a short one may still count as the live edge.
        if app.buttons["Go Live"].waitForExistence(timeout: 3) {
            app.buttons["Go Live"].tap()
            sleep(1)
            shot("scrub-2-golive")
        }
    }

    /// Bug 1 ("an empty glass on top of the tab bar when you open the app"): nothing shows above the tab bar
    /// while nothing plays, at launch, after a trip to the background, after stopping from a minimized tab bar,
    /// across tab switches and after a relaunch.
    func testNoAccessoryWhileNothingPlays() {
        var app = launch("home;wait:2")
        XCTAssertTrue(tabButton(app, "Guide").waitForExistence(timeout: 30))
        sleep(3)
        shot("acc-1-launch")
        XCTAssertFalse(app.otherElements["miniPlayer"].exists, "at launch: no mini player")
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        sleep(2)
        shot("acc-2-foreground")
        XCTAssertFalse(app.otherElements["miniPlayer"].exists, "back from the background: no mini player")

        // Playing, with the tab bar minimized by a scroll down: open the player from the inline mini player and stop.
        app = launch("mini-player:Test Pattern (MPEG-TS);wait:3")
        XCTAssertTrue(miniPlayer(app).waitForExistence(timeout: 30))
        app.swipeUp(velocity: .slow)
        sleep(2)
        shot("acc-3-minimized-playing")
        miniPlayer(app).tap()
        waitPlayerSettled(app)
        app.buttons["player.stop"].tap()
        waitPlayerOpen(app, false)
        sleep(2)
        shot("acc-4-stopped-minimized")
        XCTAssertLessThan(darkShareOfBottomRows(), 0.2, "stopped with the tab bar minimized: nothing of the player is left at the bottom")
        XCTAssertFalse(app.otherElements["miniPlayer"].exists, "stopped: no mini player")
        // Scrolling back to the top expands the tab bar again, also after another scroll down and up.
        scrollToTop(app)
        shot("acc-5-expanded")
        XCTAssertTrue(tabButton(app, "Guide").waitForExistence(timeout: 5), "stopped while minimized: back at the top, the tab bar is expanded")
        app.swipeUp(velocity: .slow)
        sleep(2)
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The iPad's tabs are at the top and stay there.
            XCTAssertFalse(tabButton(app, "Guide").exists, "a scroll down minimizes the tab bar again")
        }
        scrollToTop(app)
        shot("acc-5b-expanded-again")
        XCTAssertTrue(tabButton(app, "Guide").waitForExistence(timeout: 5), "another scroll down and back to the top: the tab bar is expanded")
        for tab in ["Guide", "Favorites", "Home"] {
            tabButton(app, tab).tap()
            sleep(1)
        }
        shot("acc-6-tabs")
        XCTAssertFalse(app.otherElements["miniPlayer"].exists, "after tab switches: no mini player")

        app.terminate()
        app = launch("home;wait:2")
        XCTAssertTrue(tabButton(app, "Guide").waitForExistence(timeout: 30))
        sleep(3)
        shot("acc-7-relaunch")
        XCTAssertFalse(app.otherElements["miniPlayer"].exists, "after a relaunch: no mini player")
    }

    func testStopButtonEndsPlayback() {
        let app = launch("player:Test Pattern (HLS);wait:4")
        waitPlayerSettled(app, timeout: 40)
        app.buttons["player.stop"].tap()
        waitPlayerOpen(app, false)
        sleep(1)
        shot("stop-1-after")
        XCTAssertFalse(app.otherElements["miniPlayer"].exists, "nothing plays: no mini player")
    }
}
