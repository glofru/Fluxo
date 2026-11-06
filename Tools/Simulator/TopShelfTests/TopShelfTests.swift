//
//  TopShelfTests.swift
//  TopShelfTests
//
//  Drives the Apple TV Home Screen with the Siri Remote (XCUIRemote) to check Fluxo's Top Shelf (see
//  ../topshelf-tests.sh): it focuses Fluxo's icon in the top row, then follows a list of remote presses and
//  screenshots. Fluxo must have run first with the harness (run.sh --keep), so the Top Shelf snapshot exists, and
//  should still run in the background, so a selected item opens in that same seeded library.
//
//  $FLUXO_TOPSHELF_STEPS: comma-separated steps, run in order:
//    home                 the Home button (back to the Home Screen)
//    focus:<app>          moves the focus along the top row to the icon whose label contains <app>
//    up, down, left, right, select, menu, playpause   one press
//    hold:<button>        a long press (select, playpause, ...)
//    wait:<seconds>
//    shot:<name>          screenshot <name>.png into $FLUXO_SHOTS
//    focused              logs the label of the focused element of the Home Screen
//

import XCTest

final class TopShelfTests: XCTestCase {

    let out = ProcessInfo.processInfo.environment["FLUXO_SHOTS"] ?? "/tmp/fluxo-shots/topshelf-tests"
    let steps = ProcessInfo.processInfo.environment["FLUXO_TOPSHELF_STEPS"] ?? "home,wait:2,focus:Fluxo,wait:5,shot:icon-focused"
    let remote = XCUIRemote.shared
    /// The Home Screen.
    let home = XCUIApplication(bundleIdentifier: "com.apple.HeadBoard")

    func testSteps() throws {
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for step in steps.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !step.isEmpty {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            print("TopShelfTests step: \(step)")
            switch parts[0] {
            case "home":
                remote.press(.home)
                sleep(1)
            case "focus":
                try focusIcon(containing: argument)
            case "hold":
                remote.press(try button(argument), forDuration: 1.5)
                sleep(1)
            case "wait":
                Thread.sleep(forTimeInterval: Double(argument) ?? 1)
            case "shot":
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(argument).png"))
            case "focused":
                print("TopShelfTests focused: \(focusedLabel() ?? "(none)")")
            default:
                remote.press(try button(parts[0]))
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
    }

    private func button(_ name: String) throws -> XCUIRemote.Button {
        switch name {
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        case "select": return .select
        case "menu": return .menu
        case "playpause": return .playPause
        default: throw XCTSkip("unknown button \(name)")
        }
    }

    private func focusedLabel() -> String? {
        let focused = home.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return focused.exists ? focused.label : nil
    }

    /// Moves the focus to the first icon of the row, then right until its label contains `name`.
    private func focusIcon(containing name: String) throws {
        for _ in 0..<12 {
            remote.press(.left)
        }
        sleep(1)
        for _ in 0..<24 {
            let label = focusedLabel() ?? ""
            print("TopShelfTests focus: \(label)")
            if label.localizedCaseInsensitiveContains(name) {
                return
            }
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.6)
        }
        XCTFail("no icon labelled \(name) in the row")
    }
}
