//
//  RemoteTests.swift
//  RemoteTests
//
//  Drives Fluxo on an Apple TV simulator with real Siri Remote presses (XCUIRemote) and checks where the focus goes
//  (see ../remote-tests.sh). Each test launches the installed Debug app with the harness (a seeded library in
//  memory) and a route, then presses the remote and reads the focused element.
//
//  The series page: every season tab is reachable with left and right, the season under the focus shows its
//  episodes, a long row of tabs scrolls, down enters the season's episodes at its Up Next (or first) episode, up
//  comes back to the selected season, and Select on a tab moves into its episodes. Series with 1 (Test Series),
//  2 (Deep Field), 3 (Orbit) and 12 seasons (Evergreen Street).
//
//  $FLUXO_SHOTS: the screenshot folder; $FLUXO_APPEARANCE: dark (default) or light.
//

import XCTest

// XCUIApplication and the elements it finds are main-actor isolated: the tests run on the main actor.
@MainActor
final class SeriesSeasonFocusTests: XCTestCase {

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

    // MARK: - Tests

    /// One season: no tabs, the season's title over its episodes, and down goes from the actions to the episodes.
    func testOneSeason() throws {
        open("Test Series")
        shot("1-season-open")
        XCTAssertFalse(tab(1).exists, "a series of one season has no season tabs")
        try moveDown(until: { $0.hasPrefix("Play") }, presses: 3)
        press(.down)
        let label = focusedLabel()
        XCTAssertTrue(isEpisode(label, season: 1, number: 1), "down from Play focuses the first episode, not \(label)")
        shot("1-season-episode-focused")
    }

    func testTwoSeasons() throws {
        try checkSeasons(of: "Deep Field", count: 2, slug: "2-seasons")
    }

    /// Orbit has an episode watched part-way (S1 E2), so its first season opens at it.
    func testThreeSeasons() throws {
        try checkSeasons(of: "Orbit", count: 3, slug: "3-seasons", upNextOfFirstSeason: 2)
    }

    func testTwelveSeasons() throws {
        try checkSeasons(of: "Evergreen Street", count: 12, slug: "12-seasons")
    }

    /// Back from the player (Menu), the focus is on the episode that was played, in the season that was chosen.
    /// The seeded Orbit episodes cannot load, so the player shows its error and Menu closes it.
    func testFocusReturnsToPlayedEpisode() throws {
        open("Orbit")
        try moveDown(until: { $0 == "Season 1" }, presses: 4)
        press(.right)
        press(.select)
        press(.right)
        XCTAssertTrue(isEpisode(focusedLabel(), season: 2, number: 2), "S2 E2 focused: \(focusedLabel())")
        press(.select)
        Thread.sleep(forTimeInterval: 4)
        shot("player-from-season-2")
        for _ in 0..<3 {
            press(.menu)
            Thread.sleep(forTimeInterval: 1.5)
            if focusedLabel().hasPrefix("Season ") {
                break
            }
        }
        let label = focusedLabel()
        XCTAssertTrue(isEpisode(label, season: 2, number: 2), "back from the player on S2 E2, not \(label)")
        XCTAssertTrue(tab(2).isSelected, "Season 2 is still the selected season")
        shot("back-from-player")
    }

    // MARK: - The season row

    private func checkSeasons(of series: String, count: Int, slug: String, upNextOfFirstSeason: Int = 1) throws {
        open(series)
        shot("\(slug)-0-open")

        // Down from the actions lands on the selected season (the first one here).
        try moveDown(until: { $0.hasPrefix("Season ") && !$0.contains(",") }, presses: 4)
        XCTAssertEqual(focusedLabel(), "Season 1")
        XCTAssertTrue(tab(1).isSelected, "Season 1 is the selected tab")
        shot("\(slug)-1-season-1-focused")

        // Right through every season: each takes the focus, becomes the selected tab, shows its episodes and is on
        // screen (the row scrolls).
        for season in 2...count {
            press(.right)
            XCTAssertEqual(focusedLabel(), "Season \(season)", "right from Season \(season - 1)")
            XCTAssertTrue(tab(season).isSelected, "Season \(season) is selected once it has the focus")
            XCTAssertTrue(episode(season: season, number: 1).waitForExistence(timeout: 3), "Season \(season) shows its episodes")
            XCTAssertFalse(episode(season: season - 1, number: 1).exists, "Season \(season - 1)'s episodes are gone")
            assertOnScreen(tab(season), "Season \(season)'s tab")
            if season == 2 || season == count || season == count / 2 + 1 {
                shot("\(slug)-2-season-\(season)-focused")
            }
        }
        // The end of the row: the focus stays on the last season.
        press(.right)
        XCTAssertEqual(focusedLabel(), "Season \(count)", "right at the end of the row")

        // Down enters the last season's episodes at its first one; up comes back to its tab, not a neighbour.
        press(.down)
        XCTAssertTrue(isEpisode(focusedLabel(), season: count, number: 1), "down from Season \(count): \(focusedLabel())")
        shot("\(slug)-3-season-\(count)-episode-focused")
        press(.right)
        XCTAssertTrue(isEpisode(focusedLabel(), season: count, number: 2), "right along the episodes: \(focusedLabel())")
        press(.up)
        XCTAssertEqual(focusedLabel(), "Season \(count)", "up from the episodes returns to the selected season")
        shot("\(slug)-4-back-on-season-\(count)")

        // Left all the way back; the row scrolls back to the first season.
        for season in stride(from: count - 1, through: 1, by: -1) {
            press(.left)
            XCTAssertEqual(focusedLabel(), "Season \(season)", "left from Season \(season + 1)")
        }
        XCTAssertTrue(tab(1).isSelected)
        assertOnScreen(tab(1), "Season 1's tab")
        XCTAssertTrue(episode(season: 1, number: 1).waitForExistence(timeout: 3), "Season 1 shows its episodes again")
        press(.down)
        XCTAssertTrue(isEpisode(focusedLabel(), season: 1, number: upNextOfFirstSeason), "down from Season 1: \(focusedLabel())")
        press(.up)
        XCTAssertEqual(focusedLabel(), "Season 1")

        // Select on a tab moves into its episodes.
        press(.right)
        press(.select)
        XCTAssertTrue(isEpisode(focusedLabel(), season: 2, number: 1), "Select on Season 2: \(focusedLabel())")
        shot("\(slug)-5-selected-season-2")

        // Up past the tabs reaches the actions; down from them returns to the selected season, not the nearest tab.
        press(.up)
        XCTAssertEqual(focusedLabel(), "Season 2")
        press(.up)
        let header = focusedLabel()
        XCTAssertFalse(header.hasPrefix("Season "), "up from the tabs reaches the actions, not \(header)")
        shot("\(slug)-6-actions")
        press(.down)
        XCTAssertEqual(focusedLabel(), "Season 2", "down from the actions returns to the selected season")
    }

    // MARK: - Helpers

    /// Launches Fluxo on the page of a series and waits until it has the focus.
    private func open(_ series: String) {
        app.launchArguments = ["-FluxoDebugStore", "memory", "-FluxoDebugSeed", "sample", "-FluxoDebugRoute", "series:\(series)", "-FluxoDebugAppearance", appearance]
        app.launch()
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            // The page is up once one of its episodes is listed (their labels start with the season).
            if episode(season: 1, number: 1).exists {
                sleep(2)
                return
            }
            sleep(1)
        }
        XCTFail("the page of \(series) did not open")
    }

    private func tab(_ season: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Season \(season)")).firstMatch
    }

    /// "Season 2, episode 1", then its title, Up Next, its progress… when it has them.
    private func episodePattern(season: Int, number: Int) -> String {
        "Season \(season), episode \(number)(,.*)?"
    }

    private func episode(season: Int, number: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", episodePattern(season: season, number: number))).firstMatch
    }

    private func isEpisode(_ label: String, season: Int, number: Int) -> Bool {
        NSPredicate(format: "SELF MATCHES %@", episodePattern(season: season, number: number)).evaluate(with: label)
    }

    private func focusedLabel() -> String {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        let label = focused.exists ? focused.label : ""
        print("RemoteTests focused: \(label)")
        return label
    }

    private func press(_ button: XCUIRemote.Button) {
        remote.press(button)
        // The focus animation and the season's episodes.
        Thread.sleep(forTimeInterval: 0.9)
    }

    private func moveDown(until matches: (String) -> Bool, presses: Int) throws {
        for _ in 0..<presses {
            if matches(focusedLabel()) {
                return
            }
            press(.down)
        }
        XCTAssertTrue(matches(focusedLabel()), "down did not reach the season tabs (focus: \(focusedLabel()))")
    }

    private func assertOnScreen(_ element: XCUIElement, _ name: String) {
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(element.frame), "\(name) is on screen (\(element.frame) in \(screen))")
    }

    private func shot(_ name: String) {
        let path = "\(out)/\(appearance)-\(name).png"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
    }
}
