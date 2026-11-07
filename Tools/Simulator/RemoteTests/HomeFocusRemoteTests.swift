//
//  HomeFocusRemoteTests.swift
//  RemoteTests
//
//  The Home hero with real Siri Remote presses (XCUIRemote): down from the tab bar lands on the Play of the hero's
//  page on screen, never on a shelf below it, also while the hero pages by itself (every 9 s while the focus is
//  elsewhere; the press lands during the page's slide too). It used to land on a Continue Watching card now and then,
//  with the hero scrolled half off screen.
//
//  $FLUXO_SHOTS: the screenshot folder; $FLUXO_APPEARANCE: dark (default) or light.
//

import XCTest

// XCUIApplication and the elements it finds are main-actor isolated: the tests run on the main actor.
@MainActor
final class HomeHeroFocusTests: XCTestCase {

    let out = ProcessInfo.processInfo.environment["FLUXO_SHOTS"] ?? "/tmp/fluxo-shots/remote-tests"
    let appearance = ProcessInfo.processInfo.environment["FLUXO_APPEARANCE"] ?? "dark"
    let remote = XCUIRemote.shared
    let app = XCUIApplication(bundleIdentifier: "dev.watermelon.Fluxo")

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    }

    // The asynchronous tearDown: unlike the synchronous one, it runs on the main actor like the tests.
    override func tearDown() async throws {
        app.terminate()
    }

    /// Up to the tab bar, then down after waits that put the press before, during and after the hero's own paging.
    func testDownFromTabBarLandsOnHeroPlay() throws {
        app.launchArguments = ["-FluxoDebugStore", "memory", "-FluxoDebugSeed", "sample", "-FluxoDebugRoute", "home", "-FluxoDebugAppearance", appearance]
        app.launch()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 40), "Home is up")
        sleep(4)
        // The auto-advance runs every 9 s once the focus left the hero (its slide takes 0.8 s).
        for (index, wait) in [2.0, 9.1, 9.4, 9.7, 10.2].enumerated() {
            reachTabBar()
            Thread.sleep(forTimeInterval: wait)
            remote.press(.down)
            Thread.sleep(forTimeInterval: 1.2)
            let focused = focusedElement()
            let label = focused.exists ? focused.label : ""
            print("RemoteTests focused: \(label) at \(focused.frame)")
            shot("hero-\(index)-after-\(wait)s")
            XCTAssertTrue(isHeroPlay(label), "down from the tab bar after \(wait) s focuses the hero's Play, not \(label)")
            let screen = app.windows.firstMatch.frame
            XCTAssertTrue(screen.contains(focused.frame), "the focused Play is on screen (\(focused.frame))")
        }
    }

    // MARK: - Helpers

    /// Presses up until a tab of the tab bar has the focus.
    private func reachTabBar() {
        for _ in 0..<4 {
            let label = focusedElement().label
            if ["Search", "Home", "Live TV", "Movies", "Series", "Library", "Settings"].contains(label) {
                return
            }
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.9)
        }
        XCTFail("the tab bar did not take the focus (focus: \(focusedElement().label))")
    }

    /// The hero's main button: "Play, <title>", "Play S1 E2, <series>", "Resume …", "Watch Live, <channel>" and the
    /// series' other titles from `SeriesPlayback.buttonTitle`; its label ends with the page's title.
    private func isHeroPlay(_ label: String) -> Bool {
        ["Play", "Resume", "Watch Live", "Continue", "Start", "Watch Again", "Next"].contains { label.hasPrefix($0) } && label.contains(",")
    }

    private func focusedElement() -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func shot(_ name: String) {
        let path = "\(out)/\(appearance)-\(name).png"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
    }
}
