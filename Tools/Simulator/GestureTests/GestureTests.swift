//
//  GestureTests.swift
//  GestureTests
//
//  Real touches on the installed Fluxo Debug build (see ../gesture-tests.sh): the mini player opens on a tap and
//  on a swipe up, the player follows a drag down 1:1 (checked with its Debug drag probe and a screenshot while the
//  finger holds), springs back from a short one, ignores horizontal drags and closes on a long drag or a flick,
//  it covers the whole screen in portrait and landscape (also pulled up), Home's cover stretches over a real
//  pull down, scrubbing the timeline never closes the player, its X stops playback, and nothing shows above the
//  tab bar while nothing plays. On a (simulated) foldable, the channel list beside the video scrolls and switches
//  channel without moving the player. Deleting a TV guide source (swipe, context menu, the Guide Sources sheet)
//  leaves the app running and the row gone.
//  The app runs with the debug harness (seeded in-memory library, routes) and the test streams of
//  test-stream.sh. Screenshots of the steps go to $FLUXO_SHOTS (default /tmp/fluxo-shots/gesture-tests).
//

import UIKit
import XCTest

final class GestureTests: XCTestCase {

    let out = ProcessInfo.processInfo.environment["FLUXO_SHOTS"] ?? "/tmp/fluxo-shots/gesture-tests"

    func launch(_ route: String, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.watermelon.Fluxo")
        // Light mode whatever the simulator uses: `darkShareOfBottomRows` tells the player from the app by color.
        app.launchArguments = ["-FluxoDebugStore", "memory", "-FluxoDebugSeed", "sample", "-FluxoDebugRoute", route, "-FluxoDebugAppearance", "light"] + arguments
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

    /// The player of a foldable iPhone open like a book (simulated with -FluxoDebugPosture; needs a simulator of
    /// at least 951 x 669 pt, e.g. an iPad): scrolling the channel list beside the video never moves or closes
    /// the player, a tap on a channel plays it in place, and the top bar button gives the display back to the
    /// video.
    func testFoldableChannelListScrollsAndSwitchesWithoutClosing() {
        let app = launch("seed-guide;player:Sky Sport F1;wait:2", arguments: ["-FluxoDebugPosture", "book"])
        waitPlayerSettled(app, timeout: 40)
        let list = app.descendants(matching: .any)["player.companion.channels"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the channel list shows beside the video")
        shot("foldable-0-book")
        let middle = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -260)), withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
        let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 300)), withVelocity: .slow, thenHoldForDuration: 0)
        sleep(1)
        shot("foldable-1-scrolled")
        waitPlayerOpen(app, true)
        XCTAssertEqual(dragProbe(app)["maxOffset"] ?? 0, 0, accuracy: 1, "the list's scrolling never dragged the player")
        let other = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'player.companion.channel' AND label CONTAINS 'Sky Sport Uno'")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 5), "another channel of the category is listed")
        other.tap()
        sleep(2)
        shot("foldable-2-switched")
        waitPlayerOpen(app, true)
        let nowPlaying = app.descendants(matching: .any)["player.companion.nowPlaying"]
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: 5), "the panel shows what plays")
        XCTAssertTrue(nowPlaying.label.contains("Sky Sport Uno"), "the tapped channel plays: \(nowPlaying.label)")
        let schedule = app.buttons["Schedule"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5), "live channels with a guide have a schedule")
        schedule.tap()
        sleep(2)
        shot("foldable-2b-schedule")
        waitPlayerOpen(app, true)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        let toggle = app.buttons["player.splitToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the top bar offers to hide the channels")
        toggle.tap()
        sleep(2)
        shot("foldable-3-full")
        XCTAssertFalse(list.exists, "the video has the whole display")
        waitPlayerOpen(app, true)
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

    // MARK: - Copy Link

    /// The appearance of the Copy Link tests: `TEST_RUNNER_FLUXO_APPEARANCE=dark` (default light).
    var appearance: String {
        ProcessInfo.processInfo.environment["FLUXO_APPEARANCE"] ?? "light"
    }

    func launchCopyLink(_ route: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.watermelon.Fluxo")
        app.launchArguments = ["-FluxoDebugStore", "memory", "-FluxoDebugSeed", "sample", "-FluxoDebugRoute", route, "-FluxoDebugAppearance", appearance]
        app.launch()
        return app
    }

    /// Copy Link in the context menu of a channel row (an Xtream-style link: the toast warns about the login in it),
    /// then Share (the share sheet, titled with the channel), and Copy Link of a plain link (no warning).
    func testCopyLinkFromChannelMenu() {
        let app = launchCopyLink("group:Sport;wait:2")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sky Sport MotoGP'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the channel row")
        sleep(2)
        row.press(forDuration: 1.2)
        let copy = app.buttons["Copy Link"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy Link in the menu")
        XCTAssertTrue(app.buttons["Share"].exists || app.buttons["Share…"].exists, "Share in the menu")
        sleep(1)
        shot("copy-\(appearance)-1-menu")
        copy.tap()
        usleep(700_000)
        shot("copy-\(appearance)-2-toast-credentials")
        sleep(4)

        row.press(forDuration: 1.2)
        let share = app.buttons["Share"].exists ? app.buttons["Share"] : app.buttons["Share…"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "Share in the menu")
        share.tap()
        sleep(7)
        shot("copy-\(appearance)-3-share-sheet")
        app.terminate()

        let plain = launchCopyLink("group:Test Streams;wait:2")
        let test = plain.buttons.matching(NSPredicate(format: "label CONTAINS 'Test Pattern (HLS)'")).firstMatch
        XCTAssertTrue(test.waitForExistence(timeout: 30), "the loopback channel row")
        sleep(2)
        test.press(forDuration: 1.2)
        XCTAssertTrue(plain.buttons["Copy Link"].waitForExistence(timeout: 5), "Copy Link in the menu")
        plain.buttons["Copy Link"].tap()
        usleep(700_000)
        shot("copy-\(appearance)-4-toast-plain")
    }

    /// Copy Link in the player's ••• menu, with the toast over the video.
    func testCopyLinkFromPlayerMenu() {
        let app = launchCopyLink("player:Sky Sport F1;wait:3")
        waitPlayerSettled(app, timeout: 40)
        let more = app.buttons["More"]
        if !more.isHittable {
            app.tap()
            sleep(1)
        }
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the player's More menu")
        more.tap()
        let copy = app.buttons["Copy Link"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy Link in the player menu")
        sleep(1)
        shot("copy-\(appearance)-5-player-menu")
        copy.tap()
        usleep(700_000)
        shot("copy-\(appearance)-6-player-toast")
    }

    /// Copy Link in the context menu of a Home card (iPad: a larger screen).
    func testCopyLinkFromHomeCard() {
        let app = launchCopyLink("home;wait:2")
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sky Sport F1'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "a channel card")
        sleep(2)
        card.press(forDuration: 1.2)
        let copy = app.buttons["Copy Link"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy Link in the card menu")
        sleep(1)
        shot("copy-\(appearance)-7-card-menu")
        copy.tap()
        usleep(700_000)
        shot("copy-\(appearance)-8-card-toast")
    }

    /// iPad: Copy Link in the context menu of a row of the player's side panel, with the toast over the player.
    func testCopyLinkFromSidePanel() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad only")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchCopyLink("seed-guide;side-panel:channels;player:Sky Sport F1;wait:2")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sky Sport MotoGP'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the channel row in the side panel")
        sleep(2)
        row.press(forDuration: 1.2)
        let copy = app.buttons["Copy Link"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy Link in the side panel menu")
        sleep(1)
        shot("copy-\(appearance)-9-panel-menu")
        copy.tap()
        usleep(700_000)
        shot("copy-\(appearance)-10-panel-toast")
        XCUIDevice.shared.orientation = .portrait
    }

    /// Screenshots of layouts in both orientations (`simctl` cannot rotate a simulator). Runs only when
    /// `TEST_RUNNER_FLUXO_LAYOUT_SHOTS` lists scenes, separated by `;;`, each `name|portrait or landscape|light or
    /// dark|route` (the route is a `-FluxoDebugRoute`, `;`-separated), e.g.
    /// `home-landscape|landscape|dark|seed-guide;home`. Every scene launches the app again; after the route has
    /// run the device turns and the screenshot is taken. The device turns back to portrait at the end, unless
    /// `TEST_RUNNER_FLUXO_LAYOUT_KEEP_ORIENTATION=1`.
    func testLayoutScreenshots() throws {
        let scenes = (ProcessInfo.processInfo.environment["FLUXO_LAYOUT_SHOTS"] ?? "")
            .components(separatedBy: ";;")
            .map { $0.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count == 4 }
        try XCTSkipIf(scenes.isEmpty, "no FLUXO_LAYOUT_SHOTS")
        for scene in scenes {
            let (name, orientation, appearance, route) = (scene[0], scene[1], scene[2], scene[3])
            XCUIDevice.shared.orientation = orientation == "landscape" ? .landscapeLeft : .portrait
            let app = XCUIApplication(bundleIdentifier: "dev.watermelon.Fluxo")
            app.launchArguments = ["-FluxoDebugStore", "memory", "-FluxoDebugSeed", "sample", "-FluxoDebugRoute", route, "-FluxoDebugAppearance", appearance]
            app.launch()
            // Seeding (about 2 s), then 1.2 s per route step and its animations.
            let steps = route.split(separator: ";").count
            sleep(UInt32(8 + steps * 2))
            shot(name)
            app.terminate()
        }
        // `TEST_RUNNER_FLUXO_LAYOUT_KEEP_ORIENTATION=1` leaves the device turned, so that `run.sh` can then
        // cold-launch the app in that orientation (with `simctl launch`, not XCUITest).
        if ProcessInfo.processInfo.environment["FLUXO_LAYOUT_KEEP_ORIENTATION"] != "1" {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// iPad: the context menu of a row in the player's side panel has nothing that would present under the
    /// player; its "Today's Schedule" shows the channel's schedule in the panel's Guide tab, with a way back.
    func testSidePanelScheduleMenu() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad only")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch("seed-guide;side-panel:channels;player:Sky Sport F1;wait:2")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sky Sport MotoGP'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the channel row in the side panel")
        sleep(2)
        row.press(forDuration: 1.2)
        let schedule = app.buttons["Today's Schedule"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5), "Today's Schedule in the menu")
        XCTAssertFalse(app.buttons["Guide Channel…"].exists, "no guide matching over the player")
        shot("panel-1-menu")
        schedule.tap()
        let back = app.buttons["Back to Playing Channel"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the schedule shows in the panel")
        sleep(2)
        shot("panel-2-schedule")
        back.tap()
        sleep(1)
        XCTAssertFalse(back.exists, "back to the playing channel's guide")
        shot("panel-3-back")
        XCUIDevice.shared.orientation = .portrait
    }

    /// iPad: a channel row dragged onto Favorites in the sidebar becomes a favorite (landscape, where the sidebar
    /// shows next to the content).
    func testDragChannelOntoFavoritesTab() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad only")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch("group:Sport;wait:2")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sky Sport MotoGP'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the channel row")
        sleep(6)
        shot("drag-1-before")
        // Sidebar entries are cells.
        let favorites = app.cells.matching(NSPredicate(format: "label == 'Favorites'")).firstMatch
        XCTAssertTrue(favorites.exists, "Favorites in the sidebar")
        row.press(forDuration: 1.2, thenDragTo: favorites, withVelocity: .slow, thenHoldForDuration: 1.0)
        sleep(2)
        favorites.tap()
        sleep(3)
        shot("drag-2-favorites")
        let added = app.staticTexts.matching(NSPredicate(format: "label == 'Sky Sport MotoGP'")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 5), "the dropped channel is a favorite")
        XCUIDevice.shared.orientation = .portrait
    }
    // MARK: - Deleting a TV guide

    /// The row of the guide `add-guide-source` adds ("Debug Guide"), scrolled into view.
    func debugGuideRow(_ app: XCUIApplication, file: StaticString = #file, line: UInt = #line) -> XCUIElement {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Debug Guide'")).firstMatch
        // Seeding the guide takes a few seconds; the row exists once it is stored and scrolled near (lists are lazy).
        let deadline = Date().addingTimeInterval(60)
        while !(row.exists && row.isHittable) && Date() < deadline {
            if !row.waitForExistence(timeout: 3) || !row.isHittable {
                app.swipeUp(velocity: .slow)
            }
        }
        // Clear of the bars: a swipe or long press on a row under the tab bar would hit the bar.
        if row.exists, row.frame.maxY > app.frame.maxY - 200 {
            app.swipeUp(velocity: .slow)
            sleep(1)
        }
        XCTAssertTrue(row.exists && row.isHittable, "the Debug Guide row is on screen", file: file, line: line)
        return row
    }

    /// Confirms the deletion, then checks that the app is still running and the row went away.
    func confirmGuideDeletion(_ app: XCUIApplication, shotName: String, file: StaticString = #file, line: UInt = #line) {
        let confirm = app.buttons["Delete Guide Source"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the delete confirmation", file: file, line: line)
        shot("\(shotName)-1-confirm")
        confirm.tap()
        sleep(4)
        shot("\(shotName)-2-deleted")
        XCTAssertEqual(app.state, .runningForeground, "Fluxo is still running after deleting the guide", file: file, line: line)
        let gone = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Debug Guide'")).firstMatch
        XCTAssertFalse(gone.exists, "the deleted guide's row is gone", file: file, line: line)
    }

    /// The app keeps working after the deletion: the Guide tab and Home render (from Settings).
    func checkGuideAndHomeAfterDeletion(_ app: XCUIApplication, shotName: String, file: StaticString = #file, line: UInt = #line) {
        scrollToTop(app)
        tabButton(app, "Guide").tap()
        sleep(2)
        shot("\(shotName)-3-guide")
        tabButton(app, "Home").tap()
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "Fluxo is still running on Guide and Home", file: file, line: line)
    }

    /// Settings: swipe the guide row, Delete, confirm. With a playlist guide as well, so the Guide keeps a grid.
    func testDeleteGuideSourceBySwipeInSettings() {
        let app = launch("seed-guide;add-guide-source;guide;wait:2;settings")
        let row = debugGuideRow(app)
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the Delete swipe action")
        delete.tap()
        confirmGuideDeletion(app, shotName: "guide-delete-swipe")
        checkGuideAndHomeAfterDeletion(app, shotName: "guide-delete-swipe")
    }

    /// Settings: the context menu's Delete…, the only guide of the library.
    func testDeleteGuideSourceByContextMenuInSettings() {
        let app = launch("add-guide-source;guide;wait:2;settings")
        let row = debugGuideRow(app)
        row.press(forDuration: 1.2)
        let delete = app.buttons["Delete…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete… in the context menu")
        delete.tap()
        confirmGuideDeletion(app, shotName: "guide-delete-menu")
        checkGuideAndHomeAfterDeletion(app, shotName: "guide-delete-menu")
    }

    /// The Guide Sources sheet over the Guide grid: deleting the only guide turns the Guide behind the sheet into
    /// its "no guide" screen while the sheet is still up.
    func testDeleteGuideSourceInGuideSourcesSheet() {
        let app = launch("add-guide-source;guide", arguments: ["-FluxoDebugGuideSources", "YES"])
        let row = debugGuideRow(app)
        sleep(1)
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the Delete swipe action")
        delete.tap()
        confirmGuideDeletion(app, shotName: "guide-delete-sheet")
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the sheet's Close button")
        close.tap()
        sleep(2)
        shot("guide-delete-sheet-3-guide")
        XCTAssertEqual(app.state, .runningForeground, "Fluxo is still running on the Guide")
        XCTAssertTrue(app.buttons["Add Guide Source"].waitForExistence(timeout: 5), "the Guide shows its screen without guides")
    }
}
