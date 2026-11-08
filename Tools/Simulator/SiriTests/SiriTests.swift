//
//  SiriTests.swift
//  SiriTests
//
//  The system side of Fluxo's App Intents on a Simulator clone (see ../siri-tests.sh): the Shortcuts app lists
//  Fluxo's App Shortcuts and actions and runs them in the app, Spotlight finds the indexed channels, and Siri
//  (where the Simulator has it) answers a Fluxo phrase. Fluxo runs first with the debug harness (seeded in-memory
//  library and TV guide), and keeps running: the system runs intents in the running app, so they see that library.
//
//  These are checks with screenshots more than assertions: the system apps change between releases. Screenshots go
//  to $FLUXO_SHOTS (default /tmp/fluxo-shots/siri-tests).
//

import XCTest

// XCUIApplication and the elements it finds are main-actor isolated: the tests run on the main actor.
@MainActor
final class SiriTests: XCTestCase {

    let out = ProcessInfo.processInfo.environment["FLUXO_SHOTS"] ?? "/tmp/fluxo-shots/siri-tests"
    let fluxo = XCUIApplication(bundleIdentifier: "dev.watermelon.Fluxo")
    let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    // The asynchronous setUp: unlike the synchronous one, it runs on the main actor like the tests.
    override func setUp() async throws {
        continueAfterFailure = true
        // Favorites, history and a guide: what the phrases, Spotlight and "What's On" use. FLUXO_SEED=store
        // (TEST_RUNNER_FLUXO_SEED) uses the invented channels of the App Store screenshots instead of `sample`.
        let store = ProcessInfo.processInfo.environment["FLUXO_SEED"] == "store"
        let route = store ? "seed-guide;mini-player:Northwind Sports;wait:2;stop;spotlight-reindex" : "seed-guide;mini-player:Rai 1 HD;wait:2;stop;spotlight-reindex"
        fluxo.launchArguments = ["-FluxoDebugStore", "memory", "-FluxoDebugSeed", store ? "store" : "sample", "-FluxoDebugRoute", route]
        fluxo.launch()
        // The harness has seeded and indexed by then.
        sleep(14)
    }

    func shot(_ name: String) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    /// Writes the accessibility hierarchy of `app` next to the screenshots (to adapt the taps to a new release).
    func dump(_ app: XCUIApplication, _ name: String) {
        try? app.debugDescription.write(toFile: "\(out)/\(name).txt", atomically: true, encoding: .utf8)
    }

    /// Taps the first button or cell whose label contains `text`, if there is one within `timeout` (not the status
    /// bar's "◀ Fluxo" back link, which is no button of the app).
    @discardableResult
    func tap(_ app: XCUIApplication, containing text: String, timeout: TimeInterval = 6) -> Bool {
        let predicate = NSPredicate(format: "(elementType == %d OR elementType == %d OR elementType == %d) AND label CONTAINS[c] %@", XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.staticText.rawValue, text)
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        guard element.waitForExistence(timeout: timeout), element.isHittable else {
            return false
        }
        element.tap()
        return true
    }

    func testShortcutsAppListsAndRunsFluxoShortcuts() {
        shortcuts.launch()
        sleep(3)
        // First launch: a welcome screen on some releases.
        tap(shortcuts, containing: "Continue", timeout: 2)
        goToLibrary()
        shot("01-shortcuts-library")
        // Library › Apps › Fluxo: the App Shortcuts of the app.
        let fluxoApp = shortcuts.buttons["Fluxo"]
        XCTAssertTrue(fluxoApp.waitForExistence(timeout: 8), "Fluxo is among the apps of the Shortcuts library")
        fluxoApp.tap()
        sleep(3)
        shot("02-fluxo-app-shortcuts")
        dump(shortcuts, "02-fluxo-app-shortcuts")
        // One tile (an "Other" element labelled with the short title) per App Shortcut, and one per entity Siri knows
        // by name (the channels of Play Channel, What's On, Add to Favorites and Recording, the programmes of Set
        // Reminder): the list is long and its order is the system's, so scroll down to each, then back up.
        for title in ["Continue Watching", "Suggestions", "Search TV Guide", "Search", "Play Channel", "What's On", "Open Screen", "Add to Favorites", "Recording", "Set Reminder"] {
            // Open Screen has a screen in each of its phrases: the system shows one tile per screen ("TV Guide"…).
            let label = title == "Open Screen" ? "TV Guide" : title
            let tile = shortcuts.descendants(matching: .other).matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
            var swipes = 0
            while !tile.exists, swipes < 25 {
                shortcuts.swipeUp()
                swipes += 1
            }
            swipes = 0
            while !tile.exists, swipes < 50 {
                shortcuts.swipeDown()
                swipes += 1
            }
            XCTAssertTrue(tile.exists, "the \(title) App Shortcut is listed")
            if title == "Recording" {
                shot("02b-fluxo-app-shortcuts-more")
            }
        }

        // Runs "What's On" through the system: a background intent of the running app, answered with a dialog and
        // the snippet of what the favorite channels show.
        let whatsOn = shortcuts.descendants(matching: .other).matching(NSPredicate(format: "label ==[c] %@", "What's On")).firstMatch
        for _ in 0..<30 where !(whatsOn.exists && whatsOn.isHittable) {
            shortcuts.swipeDown()
        }
        if whatsOn.isHittable {
            whatsOn.tap()
            sleep(7)
            shot("03-whats-on-result")
            dump(shortcuts, "03-whats-on-result")
            dismissIntentResult()
        }
    }

    /// Screenshots Fluxo's App Shortcuts in the Shortcuts app (`02-fluxo-app-shortcuts`), then runs What's On and
    /// screenshots its answer (`03-whats-on-result`), in the language of the simulator: `FLUXO_WHATS_ON` is the tile's
    /// title in it (default "What's On"; Italian "Cosa c’è in onda"). For the App Store screenshots
    /// (`Design/AppStore/Scripts/capture.sh`); it checks nothing else. On the iOS 27.2 Simulator the answer's sheet
    /// stays in English (its system Done button too) when the simulator is in another language.
    func testWhatsOnResultScreenshot() {
        let title = ProcessInfo.processInfo.environment["FLUXO_WHATS_ON"] ?? "What's On"
        shortcuts.launch()
        sleep(3)
        tap(shortcuts, containing: "Continue", timeout: 2)
        goToLibrary()
        let fluxoApp = shortcuts.buttons["Fluxo"]
        XCTAssertTrue(fluxoApp.waitForExistence(timeout: 8), "Fluxo is among the apps of the Shortcuts library")
        fluxoApp.tap()
        sleep(3)
        shot("02-fluxo-app-shortcuts")
        let whatsOn = shortcuts.descendants(matching: .other).matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch
        for _ in 0..<30 where !(whatsOn.exists && whatsOn.isHittable) {
            shortcuts.swipeDown()
        }
        XCTAssertTrue(whatsOn.isHittable, "the \(title) App Shortcut is listed")
        whatsOn.tap()
        sleep(7)
        shot("03-whats-on-result")
        dismissIntentResult()
    }

    /// The Library of the Shortcuts app (it reopens where it was left, e.g. All Shortcuts).
    func goToLibrary() {
        for _ in 0..<3 {
            let back = shortcuts.navigationBars.buttons.firstMatch
            // "BackButton" in any language (the Italian app's back button is "Libreria").
            let elsewhere = shortcuts.staticTexts["All Shortcuts"].exists || shortcuts.buttons["Library"].exists || shortcuts.navigationBars.buttons["BackButton"].exists
            guard elsewhere, back.exists else {
                break
            }
            back.tap()
            sleep(1)
        }
    }

    /// The root of the Shortcuts app (its layout changes between releases): a screenshot and the hierarchy.
    func testShortcutsRoot() {
        shortcuts.launch()
        sleep(3)
        tap(shortcuts, containing: "Continue", timeout: 2)
        goToLibrary()
        shot("00-shortcuts-root")
        dump(shortcuts, "00-shortcuts-root")
    }

    func testShortcutsActionsIncludeFluxo() {
        shortcuts.launch()
        sleep(3)
        tap(shortcuts, containing: "Continue", timeout: 2)
        tap(shortcuts, containing: "Shortcuts", timeout: 3)
        // A new shortcut, then the action search: Fluxo's actions (every intent, phrases or not).
        if tap(shortcuts, containing: "Add", timeout: 4) || tap(shortcuts, containing: "New Shortcut", timeout: 2) {
            sleep(2)
            let search = shortcuts.searchFields.firstMatch
            if search.waitForExistence(timeout: 5) {
                // A tap on its position: the field sits in the action sheet, which refuses "scroll to visible".
                sleep(1)
                search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                sleep(1)
                if shortcuts.keyboards.firstMatch.waitForExistence(timeout: 3) {
                    shortcuts.typeText("Play Channel")
                }
                sleep(5)
            }
            shot("04-fluxo-actions")
            dump(shortcuts, "04-fluxo-actions")
        }
    }

    /// Closes the result of an intent (its dialog and snippet, with a Done button), which stays over every app.
    func dismissIntentResult() {
        for app in [shortcuts, springboard] where app.state != .notRunning && tap(app, containing: "Done", timeout: 2) {
            sleep(1)
            return
        }
    }

    func testSpotlightFindsIndexedChannel() {
        dismissIntentResult()
        let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
        // The channel Fluxo indexed (its label has the kind, "The Silent Harbor (1968), Movie"), not one of the App
        // Shortcut tiles of the same name: the seeded in-memory library gets new identifiers at every launch, so a
        // tile registered by an earlier launch names a channel this launch does not have, and Siri asks which one.
        let result = spotlight.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'Identifier:AppViewResultCell' AND label BEGINSWITH[c] %@ AND label CONTAINS ','", "The Silent Harbor")).firstMatch
        // Right after an install of a new build, Spotlight takes a while to take the app's items again: a second
        // search, half a minute later.
        for attempt in 1...2 {
            searchSpotlight("silent harbor", shotSuffix: attempt == 1 ? "" : "-retry")
            if result.waitForExistence(timeout: 5) {
                break
            }
            if attempt == 1 {
                XCUIDevice.shared.press(.home)
                sleep(30)
            }
        }
        // The top hit is the channel Fluxo indexed: opening it plays the channel (its `OpenIntent`), in Fluxo.
        let topHit = result
        XCTAssertTrue(topHit.waitForExistence(timeout: 5), "Spotlight lists the channel Fluxo indexed")
        guard topHit.exists else {
            return
        }
        topHit.tap()
        sleep(6)
        shot("05b-spotlight-opened")
        XCTAssertEqual(fluxo.state, .runningForeground, "opening the channel from Spotlight brings Fluxo to the front")
        dump(fluxo, "05b-spotlight-opened")
        XCTAssertTrue(fluxo.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Silent Harbor")).firstMatch.waitForExistence(timeout: 5), "Fluxo plays the channel opened from Spotlight")
    }

    /// Opens Spotlight from the Home Screen and types `text`; screenshots and Spotlight's hierarchy.
    func searchSpotlight(_ text: String, shotSuffix: String) {
        XCUIDevice.shared.press(.home)
        sleep(2)
        // The Search pill of the Home Screen (iOS 27), else the pull down.
        // One pill per Home Screen page: the one on screen.
        let pills = springboard.descendants(matching: .any).matching(identifier: "spotlight-pill")
        _ = pills.firstMatch.waitForExistence(timeout: 3)
        if let pill = pills.allElementsBoundByIndex.first(where: \.isHittable) {
            pill.tap()
        } else {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
        sleep(3)
        shot("05a-spotlight-open\(shotSuffix)")
        // A new simulator first explains slide-to-type over the keyboard.
        if tap(springboard, containing: "Continue", timeout: 2) {
            sleep(1)
        }
        // The search field has the focus, but in a process XCUITest cannot type into (typeText fails with "Neither
        // element nor any descendant has keyboard focus"): tap the keys (iPhone portrait layout). A seeded favorite
        // with a name no web suggestion has.
        typeOnKeyboard(text)
        sleep(4)
        shot("05a-spotlight-typed\(shotSuffix)")
        // The results are drawn by Spotlight's own process (iOS 27): its hierarchy names each result.
        dump(XCUIApplication(bundleIdentifier: "com.apple.Spotlight"), "05a-spotlight-typed\(shotSuffix)")
    }

    /// Taps the letters and spaces of `text` on the software keyboard of an iPhone in portrait (English layout).
    func typeOnKeyboard(_ text: String) {
        let rows: [(keys: String, y: Double, x: [Double])] = [
            ("qwertyuiop", 0.6975, [54, 145, 235, 325, 417, 507, 597, 689, 779, 869]),
            ("asdfghjkl", 0.761, [98, 189, 279, 370, 461, 551, 642, 735, 825]),
            ("zxcvbnm", 0.8245, [189, 279, 370, 461, 551, 642, 735]),
        ]
        for character in text.lowercased() {
            var point: CGVector?
            if character == " " {
                point = CGVector(dx: 0.5, dy: 0.889)
            }
            for row in rows {
                if let index = row.keys.firstIndex(of: character) {
                    point = CGVector(dx: row.x[row.keys.distance(from: row.keys.startIndex, to: index)] / 924, dy: row.y)
                }
            }
            if let point {
                springboard.coordinate(withNormalizedOffset: point).tap()
                usleep(250_000)
            }
        }
    }

    /// Settings › Siri & Shortcuts in Fluxo: the phrases, the Siri tip and the Shortcuts link.
    func testSettingsSiriSection() {
        fluxo.activate()
        sleep(2)
        let settingsTab = fluxo.tabBars.buttons["Settings"]
        if settingsTab.waitForExistence(timeout: 5) {
            settingsTab.tap()
        } else {
            tap(fluxo, containing: "Settings")
        }
        sleep(2)
        let header = fluxo.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Siri & Shortcuts")).firstMatch
        // Short, slow drags (a swipe flings the header past the top between two checks).
        for _ in 0..<40 where !(header.exists && header.isHittable) {
            let start = fluxo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.1, thenDragTo: fluxo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(header.exists, "Settings has the Siri & Shortcuts section")
        // The header near the top, so the whole section shows.
        if header.isHittable, header.frame.minY > fluxo.frame.height * 0.35 {
            let start = fluxo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            // Slowly and held at the end: no momentum carries the header past the top.
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -(header.frame.minY - fluxo.frame.height * 0.15))), withVelocity: .slow, thenHoldForDuration: 0.5)
            sleep(1)
        }
        shot("08-settings-siri")
        dump(fluxo, "08-settings-siri")
        let phrase = fluxo.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "in Fluxo")).firstMatch
        XCTAssertTrue(phrase.exists, "the section lists phrases with the app name")
    }

    func testSiriPhrase() {
        // The Simulator has Siri only on some Macs and releases (not the iOS 27.2 one: "not enabled on this
        // device"); the screenshot shows what it answered.
        XCTExpectFailure("The Simulator may have no Siri", strict: false)
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "What's on in Fluxo")
        sleep(8)
        shot("06-siri-whats-on")
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "Play Rai 1 in Fluxo")
        sleep(8)
        shot("07-siri-play")
    }
}
