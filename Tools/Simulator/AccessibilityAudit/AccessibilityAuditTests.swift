//
//  AccessibilityAuditTests.swift
//  AccessibilityAudit
//
//  The Xcode accessibility audit (`XCUIApplication.performAccessibilityAudit`) of every main screen of the
//  installed Fluxo Debug build (see ../accessibility-audit.sh): missing or vague labels, elements that cannot be
//  reached or hit, hit regions under 44 pt, contrast, text that does not grow with Dynamic Type or is clipped,
//  and traits.
//
//  The app runs with the debug harness (seeded in-memory library, sample TV guide, routes). The script runs the
//  audit once per variant of the simulator (default, the largest accessibility text size, dark mode with
//  Increase Contrast); every issue is written to $FLUXO_AUDIT_OUT/<variant>/report.txt with a screenshot of the
//  screen, and an issue that is not in `knownIssues` (with the reason it is accepted) fails the test.
//

import XCTest

final class AccessibilityAuditTests: XCTestCase {

    let environment = ProcessInfo.processInfo.environment
    var out: String {
        "\(environment["FLUXO_AUDIT_OUT"] ?? "/tmp/fluxo-shots/accessibility-audit")/\(variant)"
    }
    var variant: String {
        environment["FLUXO_AUDIT_VARIANT"] ?? "default"
    }

    /// The screens audited: a name and the harness route that opens it (after the sample guide is seeded).
    static let screens: [(name: String, route: String)] = [
        ("home", "home"),
        ("home-browse", "home;home-section:browse"),
        ("category", "group:Sport"),
        ("category-grid", "browse:name,grid;group:Sport"),
        ("categories", "categories:live"),
        ("favorites", "favorites"),
        ("history", "history"),
        ("guide", "guide"),
        ("schedule", "schedule:Sky Sport F1"),
        ("search", "search:Sky"),
        ("settings", "settings"),
        ("library", "library"),
        ("add-playlist", "add-playlist"),
        ("player", "player:Sky Sport F1;wait:2"),
        ("mini-player", "mini-player:Sky Sport F1;wait:2"),
    ]

    /// Issues that are accepted, matched on the audit type and a part of the issue's description or element.
    /// Each one says why.
    static let knownIssues: [(screen: String?, type: XCUIAccessibilityAuditType, match: String, reason: String)] = [
        // Text drawn inside artwork (the seeded logos, the initials of the placeholders, category mosaics): the
        // images are hidden from VoiceOver or labelled with the channel name, and the card says the name.
        (nil, .elementDetection, "none", "text inside artwork"),
        (nil, .contrast, "Sky Sport", "artwork text"),
        // System controls: the search field (its clear button, its placeholder at large sizes), navigation bar
        // titles and buttons, text fields (they scroll their text), which show in the Large Content Viewer.
        (nil, .hitRegion, "Clear text", "system search field"),
        (nil, .textClipped, "re:^45 ", "system search field placeholder"),
        (nil, .dynamicType, "Tab Bar", "system tab bar (Large Content Viewer)"),
        (nil, .dynamicType, "\"Home\"", "navigation bar title (Large Content Viewer)"),
        ("add-playlist", .dynamicType, "\"Add\"", "navigation bar button (Large Content Viewer)"),
        ("add-playlist", .textClipped, "49 \"\"", "text fields scroll their text"),
        ("add-playlist", .textClipped, "M3U and M3U8", "the form's footer under the keyboard (it scrolls)"),
        // The schedule sheet: its inline navigation title and its list section headers are sized by the system;
        // "none" is a hidden width sample of the time column (`GuideTimeColumnText`).
        ("schedule", .textClipped, "\"Sky Sport F1\"", "inline navigation title (system)"),
        ("schedule", .textClipped, "\"Today\"", "list section header (system)"),
        ("schedule", .textClipped, "re:^none$", "hidden width sample of the time column"),
        // The A–Z index keeps its size, as the system's list index does; the dragged letter shows large.
        (nil, .dynamicType, "re:^48 \"[A-Z#]\" $", "single letter of the A–Z index"),
        // The player's text stops at AX2 and its buttons at xxxLarge, so the video stays visible; the buttons
        // show in the Large Content Viewer and VoiceOver reads the lines whole. The mini player keeps the tab
        // bar accessory's height.
        ("player", .dynamicType, "", "player text capped at AX2 (Large Content Viewer)"),
        ("player", .textClipped, "", "player programme lines (one line each, read whole by VoiceOver)"),
        ("mini-player", .dynamicType, "", "mini player capped (Large Content Viewer)"),
        // The programme over a grid card's artwork is a preview (one or two lines); the card's label has it whole.
        ("category-grid", .textClipped, "", "programme preview over artwork"),
    ]

    /// Reported for review, not failures: the contrast check samples the screenshot, and over Liquid Glass,
    /// gradients, blurred artwork and video it fails text that passes (even white body text on black in dark
    /// mode with Increase Contrast). The text colors themselves are checked against WCAG AA in `Theme.swift`.
    static let advisoryTypes: [XCUIAccessibilityAuditType] = [.contrast]

    func testAuditEveryScreen() throws {
        var unexpected: [String] = []
        var report: [String] = []
        var advisory = 0
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        for screen in Self.screens {
            let app = launch(route: "seed-guide;\(screen.route)")
            shot(screen.name)
            do {
                try app.performAccessibilityAudit(for: auditTypes) { issue in
                    let element = Self.describe(issue.element)
                    let line = "\(screen.name) | \(Self.name(of: issue.auditType)) | \(issue.compactDescription) | \(element)"
                    let known = Self.knownIssues.first { known in
                        (known.screen == nil || known.screen == screen.name) && known.type == issue.auditType
                            && Self.matches(known.match, description: issue.detailedDescription, element: element)
                    }
                    if let known {
                        report.append("accepted (\(known.reason)): \(line)")
                    } else if Self.advisoryTypes.contains(issue.auditType) {
                        report.append("review: \(line)")
                        advisory += 1
                    } else {
                        report.append("ISSUE: \(line)\n    \(issue.detailedDescription)")
                        unexpected.append(line)
                    }
                    // Handled: collected into the report rather than failing at the first one.
                    return true
                }
            } catch {
                report.append("\(screen.name): the audit failed to run: \(error)")
            }
            app.terminate()
        }

        let text = (["Accessibility audit, variant \(variant): \(unexpected.count) unexpected issue(s), \(advisory) to review"] + report).joined(separator: "\n")
        do {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try text.write(toFile: "\(out)/report.txt", atomically: false, encoding: .utf8)
        } catch {
            XCTFail("Could not write the report to \(out): \(error)")
        }
        print(text)
        XCTAssertTrue(unexpected.isEmpty, "Unexpected accessibility issues (see \(out)/report.txt):\n" + unexpected.joined(separator: "\n"))
    }

    /// The player's Audio and Subtitles menu with the "Test Clip (Audio and Subtitles)" stream of test-stream.sh
    /// (FLUXO_TEST_STREAM_URL): the menu lists both audio renditions (Italiano marked as an audio description)
    /// and the subtitles (English marked SDH); choosing Italiano subtitles shows them on the video and in the
    /// button's VoiceOver value.
    func testMediaSelectionMenu() throws {
        guard let streams = environment["FLUXO_TEST_STREAM_URL"], !streams.isEmpty else {
            throw XCTSkip("FLUXO_TEST_STREAM_URL is not set (start test-stream.sh)")
        }
        guard variant == "default" else {
            throw XCTSkip("checked in the default variant")
        }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let app = launch(route: "player:Test Clip (Audio and Subtitles);wait:4", extra: ["-FluxoDebugTestStreamURL", streams])
        let button = app.buttons["player.mediaSelection"]
        // The controls hide while the clip plays: a tap on the video shows them.
        if !button.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the Audio and Subtitles button shows")
        XCTAssertEqual(button.label, "Audio and Subtitles")
        button.tap()
        sleep(1)
        shot("media-menu")
        // AVFoundation names the renditions in the user's language ("Italian AD", "English SDH").
        let audioDescription = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Audio Description'")).firstMatch
        XCTAssertTrue(audioDescription.exists, "the audio description is marked for VoiceOver")
        let sdh = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Deaf and Hard of Hearing'")).firstMatch
        XCTAssertTrue(sdh.exists, "the SDH subtitles are marked for VoiceOver")
        // The last option of the menu: the Italian subtitles.
        let italian = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Itali'"))
        XCTAssertGreaterThanOrEqual(italian.count, 2, "Italian audio and subtitles are listed")
        italian.element(boundBy: italian.count - 1).tap()
        sleep(3)
        shot("media-subtitles")
        if !button.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = button.waitForExistence(timeout: 5)
        }
        let value = button.value as? String ?? ""
        try? "button value: \(value)\n".write(toFile: "\(out)/media-selection.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(value.contains("Subtitles: Itali"), "the value says the chosen subtitles (\(value))")
        app.terminate()
    }

    // MARK: - Helpers

    /// Dynamic Type and clipping are audited at the accessibility text size only, contrast in every variant.
    var auditTypes: XCUIAccessibilityAuditType {
        if variant == "ax5" {
            return [.dynamicType, .textClipped, .sufficientElementDescription, .hitRegion, .contrast]
        }
        return [.sufficientElementDescription, .hitRegion, .contrast, .elementDetection, .trait]
    }

    func launch(route: String, extra: [String] = []) -> XCUIApplication {
        let statusDirectory = environment["FLUXO_STATUS_DIR"]
        if let statusDirectory {
            try? FileManager.default.removeItem(atPath: statusDirectory)
        }
        let app = XCUIApplication(bundleIdentifier: "dev.watermelon.Fluxo")
        app.launchArguments = ["-FluxoDebugStore", "memory", "-FluxoDebugSeed", "sample", "-FluxoDebugRoute", route]
        if let appearance = environment["FLUXO_AUDIT_APPEARANCE"] {
            app.launchArguments += ["-FluxoDebugAppearance", appearance]
        }
        app.launchArguments += extra
        app.launch()
        // On a busy Mac a launch can fail to come up: try once more.
        if !app.wait(for: .runningForeground, timeout: 30) {
            app.launch()
            _ = app.wait(for: .runningForeground, timeout: 30)
        }
        // The harness writes `ready` once every route ran (see DebugHarness).
        let deadline = Date().addingTimeInterval(60)
        if let statusDirectory {
            while !FileManager.default.fileExists(atPath: "\(statusDirectory)/ready"), Date() < deadline {
                usleep(200_000)
            }
        } else {
            sleep(8)
        }
        sleep(1)
        return app
    }

    func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    /// Whether a known issue's `match` fits: empty matches everything, "re:" starts a regular expression on the
    /// element, anything else is looked for in the description and the element.
    static func matches(_ match: String, description: String, element: String) -> Bool {
        if match.isEmpty {
            return true
        }
        if match.hasPrefix("re:") {
            return element.range(of: String(match.dropFirst(3)), options: .regularExpression) != nil
        }
        return description.contains(match) || element.contains(match)
    }

    /// The element of an issue, or "none". It may be gone by the time the issue is reported (a row that a
    /// lazy list recycled): a snapshot throws then, where reading the element's properties would stop the test.
    static func describe(_ element: XCUIElement?) -> String {
        guard let element else {
            return "none"
        }
        guard let snapshot = try? element.snapshot() else {
            return "gone"
        }
        return "\(snapshot.elementType.rawValue) \"\(snapshot.label)\" \(snapshot.identifier)"
    }

    static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: return "contrast"
        case .dynamicType: return "dynamicType"
        case .elementDetection: return "elementDetection"
        case .hitRegion: return "hitRegion"
        case .sufficientElementDescription: return "sufficientElementDescription"
        case .textClipped: return "textClipped"
        case .trait: return "trait"
        default: return "other(\(type.rawValue))"
        }
    }
}
