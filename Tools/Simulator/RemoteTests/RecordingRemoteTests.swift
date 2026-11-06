//
//  RecordingRemoteTests.swift
//  RemoteTests
//
//  Recording a live programme with real Siri Remote presses (XCUIRemote), from the programme's sheet of the TV guide
//  to the Library: right from Watch Now to Record, Select plays the channel and records it (REC over the video, Stop
//  Recording in the transport bar), Menu asks before closing the player (Keep Recording goes back to it, Stop
//  Recording closes it and saves the recording), and the recording is in the Library's Recordings shelf.
//
//  Needs the loopback test streams (Tools/Simulator/test-stream.sh start): "Test Pattern (MPEG-TS)" plays through
//  the remux engine, which records.
//
//  $FLUXO_SHOTS: the screenshot folder; $FLUXO_APPEARANCE: dark (default) or light.
//

import XCTest

// XCUIApplication and the elements it finds are main-actor isolated: the tests run on the main actor.
@MainActor
final class ProgrammeRecordingTests: XCTestCase {

    let out = ProcessInfo.processInfo.environment["FLUXO_SHOTS"] ?? "/tmp/fluxo-shots/remote-tests"
    let appearance = ProcessInfo.processInfo.environment["FLUXO_APPEARANCE"] ?? "dark"
    let remote = XCUIRemote.shared
    let app = XCUIApplication(bundleIdentifier: "dev.watermelon.Fluxo")
    let channel = "Test Pattern (MPEG-TS)"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    }

    // The asynchronous tearDown: unlike the synchronous one, it runs on the main actor like the tests.
    override func tearDown() async throws {
        app.terminate()
    }

    func testRecordFromProgrammeSheet() throws {
        // The Live TV guide of the loopback playlist: down from the tab bar and the channel column to the channel, then
        // right to its programme on now.
        app.launchArguments = ["-FluxoDebugStore", "memory", "-FluxoDebugSeed", "sample", "-FluxoDebugRoute", "seed-guide;playlist:Loopback Test;tab:guide", "-FluxoDebugAppearance", appearance]
        app.launch()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, focusedLabel() != "Live TV" {
            sleep(1)
        }
        sleep(3)
        for _ in 0..<12 where !focusedLabel().hasPrefix(channel) {
            press(.down)
        }
        // Right from the channel's name (past the Earlier cell) to the programme on now.
        for _ in 0..<4 where !(focusedLabel().contains(channel) && focusedLabel().contains("On Now")) {
            press(.right)
        }
        XCTAssertTrue(focusedLabel().contains(channel), "the programme on now has the focus")
        shot("rec-0-guide")

        // Select opens its sheet: Watch Now has the focus, Record is next to it.
        press(.select)
        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "the programme sheet offers Record")
        sleep(2)
        XCTAssertEqual(focusedLabel(), "Watch Now", "Watch Now has the focus when the sheet opens")
        shot("rec-1-sheet")
        press(.right)
        XCTAssertEqual(focusedLabel(), "Record", "right from Watch Now")
        shot("rec-2-sheet-record-focused")

        // Select: the channel plays and records once its stream is open.
        press(.select)
        let rec = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Recording'")).firstMatch
        XCTAssertTrue(rec.waitForExistence(timeout: 40), "REC shows over the video")
        sleep(6)
        shot("rec-3-player-recording")

        // Paused, the transport bar shows Stop Recording.
        press(.playPause)
        sleep(1)
        shot("rec-4-transport-bar-recording")
        press(.select)
        sleep(1)
        shot("rec-4b-transport-bar-select")
        press(.playPause)

        // Menu asks before closing the player (a first Menu may only hide the transport bar).
        let alert = app.alerts["Stop Recording?"]
        for _ in 0..<3 where !alert.exists {
            press(.menu)
            _ = alert.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(alert.exists, "Menu while recording asks first")
        shot("rec-5-stop-alert")

        // Menu on the alert keeps recording: the player stays.
        press(.menu)
        XCTAssertFalse(alert.waitForExistence(timeout: 2), "the alert closed")
        sleep(3)
        XCTAssertTrue(rec.exists, "still recording after Keep Recording")
        shot("rec-6-kept-recording")

        // Menu again, then Stop Recording: the player closes and the recording is saved.
        for _ in 0..<3 where !alert.exists {
            press(.menu)
            _ = alert.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(alert.exists)
        for _ in 0..<3 where focusedLabel() != "Stop Recording" {
            press(.up)
        }
        XCTAssertEqual(focusedLabel(), "Stop Recording")
        shot("rec-7-stop-alert-stop-focused")
        press(.select)
        XCTAssertFalse(alert.waitForExistence(timeout: 2))
        sleep(2)
        XCTAssertFalse(rec.exists, "the player closed")
        sleep(1)
        shot("rec-8-back-in-guide")

        // Back on the programme in the guide, Live TV; the Library's Recordings shelf lists it (once converted, with
        // its duration).
        XCTAssertTrue(focusedLabel().contains(channel), "back from the player on the programme in the guide, not \(focusedLabel())")
        press(.menu)
        for _ in 0..<8 where focusedLabel() != "Library" {
            press(.right)
        }
        XCTAssertEqual(focusedLabel(), "Library", "the Library tab")
        sleep(2)
        // Down shelf by shelf (they load as they scroll in) to the Recordings shelf: its first card is the newest.
        let isRecordingCard = { (label: String) in label.hasPrefix(self.channel) && label.contains("second") }
        for _ in 0..<10 where !focusedLabel().contains("second") {
            press(.down)
        }
        // Down keeps the column of the tab bar: left to the first, newest, recording.
        for _ in 0..<4 where !isRecordingCard(focusedLabel()) {
            press(.left)
        }
        XCTAssertTrue(isRecordingCard(focusedLabel()), "the recording is in Library: \(focusedLabel())")
        sleep(1)
        shot("rec-9-library-recording-focused")
    }

    /// The long-press menu of a live channel's card (Continue Watching on Home) has Record: it plays and records.
    func testRecordFromChannelMenu() throws {
        app.launchArguments = ["-FluxoDebugStore", "memory", "-FluxoDebugSeed", "sample", "-FluxoDebugRoute", "home", "-FluxoDebugAppearance", appearance]
        app.launch()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, focusedLabel().isEmpty || focusedLabel() == "Home" {
            sleep(1)
        }
        sleep(2)
        for _ in 0..<5 where !focusedLabel().hasPrefix(channel) {
            press(.down)
        }
        XCTAssertTrue(focusedLabel().hasPrefix(channel), "the channel's card in Continue Watching")
        remote.press(.select, forDuration: 1.5)
        sleep(2)
        shot("menu-0-open")
        let record = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Record'")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5), "the long-press menu offers Record")
        // Watch Live comes first; Record is the next item (the menu's items do not report their focus).
        press(.down)
        shot("menu-1-record-focused")
        press(.select)
        let rec = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Recording'")).firstMatch
        XCTAssertTrue(rec.waitForExistence(timeout: 40), "REC shows over the video")
        sleep(3)
        shot("menu-2-player-recording")
    }

    // MARK: - Helpers

    private func focusedLabel() -> String {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        let label = focused.exists ? focused.label : ""
        print("RemoteTests focused: \(label)")
        return label
    }

    private func press(_ button: XCUIRemote.Button) {
        remote.press(button)
        Thread.sleep(forTimeInterval: 0.9)
    }

    private func shot(_ name: String) {
        let path = "\(out)/\(appearance)-\(name).png"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
    }
}
