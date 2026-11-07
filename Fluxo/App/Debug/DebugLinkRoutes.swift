//
//  DebugLinkRoutes.swift
//  Fluxo
//
//  Debug harness: the fluxo:// links (`FluxoLink`) and Siri on Apple TV.
//
//      -FluxoDebugRoute "link-check;link:fluxo://open?screen=movies;link-guide:Rai 1;settings-siri;focus:siri-play"
//
//  `link:` goes through the same handler as a link the system opens (`TVLinkHandler`); `xcrun simctl openurl <udid>
//  "fluxo://…"` checks the system's part (the scheme in Info-tvOS.plist). Outcomes go to Status/links.log.
//

#if DEBUG
import Foundation
import os

@MainActor
enum DebugLinkRoutes {

    static let all: [DebugRoute] = [
        DebugRoute("link:<fluxo url>", "Apple TV: opens a fluxo:// link in process, as the system does (a `FluxoLink`, see TVLinkHandler, or a Top Shelf `TopShelfLink`, see TopShelfLinks).") { _, argument in
            #if os(tvOS)
            guard let url = URL(string: argument) else {
                throw DebugRouteError.invalidArgument("link", argument)
            }
            if let link = FluxoLink(url: url) {
                report("link \(argument) → \(link)")
            } else if let link = TopShelfLink(url: url) {
                report("link \(argument) → Top Shelf \(link)")
            } else {
                throw DebugRouteError.invalidArgument("link", argument)
            }
            NotificationCenter.default.post(name: .fluxoDebugOpenLink, object: url)
            #else
            throw DebugRouteError.unsupported("link")
            #endif
        },
        DebugRoute("link-guide:<channel>", "Apple TV: opens the link of the TV guide at a channel (fluxo://guide?channel=<its ChannelEntity id>).") { context, argument in
            #if os(tvOS)
            let item = try context.channel(named: argument)
            guard let entity = ChannelEntity(item), let url = FluxoLink.guide(channelID: entity.id).url else {
                throw DebugRouteError.check("\(argument) has no ChannelEntity identifier")
            }
            report("link-guide \(argument) → \(url.absoluteString)")
            NotificationCenter.default.post(name: .fluxoDebugOpenLink, object: url)
            #else
            throw DebugRouteError.unsupported("link-guide")
            #endif
        },
        DebugRoute("link-check", "Apple TV: checks that every FluxoLink survives building and parsing, that malformed links and the Top Shelf's links are not FluxoLinks, and logs the links (Status/links.log).") { _, _ in
            #if os(tvOS)
            let links: [FluxoLink] = FluxoLink.Screen.allCases.map(FluxoLink.screen) + [
                .search("football tonight"),
                .search("Rai 1 & Rai 2 / ?#"),
                .guide(channelID: nil),
                .guide(channelID: "6A2B0C9E-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef"),
                .continueWatching,
            ]
            var problems: [String] = []
            for link in links {
                guard let url = link.url else {
                    problems.append("\(link) has no URL")
                    continue
                }
                if FluxoLink(url: url) != link {
                    problems.append("\(url.absoluteString) parses as \(String(describing: FluxoLink(url: url)))")
                }
                report("link-check \(url.absoluteString)")
            }
            let expectations: [(String, FluxoLink?)] = [
                ("FLUXO://Open?Screen=Guide", .screen(.guide)),
                ("fluxo://search", .screen(.search)),
                ("fluxo://search?q=%20%20", .screen(.search)),
                ("fluxo://guide?channel=", .guide(channelID: nil)),
                ("fluxo://search?q=" + String(repeating: "a", count: 500), .search(String(repeating: "a", count: FluxoLink.maximumSearchLength))),
                // The Top Shelf's links are TopShelfLink's, never FluxoLinks: a URL is opened once.
                ("fluxo://play?channel=abc", nil),
                ("fluxo://open?playlist=6A2B0C9E-0000-4000-8000-000000000001&series=s1", nil),
                ("fluxo://open?screen=downloads", nil),
                ("fluxo://unknown", nil),
                ("https://example.com/open?screen=guide", nil),
            ]
            for (string, expected) in expectations {
                guard let url = URL(string: string) else {
                    problems.append("\(string) is not a URL")
                    continue
                }
                let parsed = FluxoLink(url: url)
                if parsed != expected {
                    problems.append("\(string.prefix(80)) parses as \(String(describing: parsed)), expected \(String(describing: expected))")
                }
            }
            guard problems.isEmpty else {
                throw DebugRouteError.check(problems.joined(separator: "; "))
            }
            report("link-check passed: \(links.count) links, \(expectations.count) parsing cases")
            #else
            throw DebugRouteError.unsupported("link-check")
            #endif
        },
        DebugRoute("settings-siri", "Apple TV: Settings › Siri and Voice Search (`TVSiriScreen`).") { context, _ in
            #if os(tvOS)
            context.navigation.tab = .settings
            try await Task.sleep(for: .milliseconds(300))
            NotificationCenter.default.post(name: .fluxoDebugSiriPage, object: nil)
            #else
            throw DebugRouteError.unsupported("settings-siri")
            #endif
        },
        DebugRoute("acknowledgements[:<fluxo|ffmpeg|flyingfox|googlecast|gtmsessionfetcher|googlecast/<part>|source-offer|source-offer-sha>]", "Settings › About › Acknowledgements, or the page of one component (its license texts), or of a part of the Google Cast SDK (googlecast/eigen-3), or scrolled to the FFmpeg source offer: pushed in Settings, a sheet in the Mac's Settings window. A later step goes back to the page and opens the next one.") { context, argument in
            if let openSettings = context.openSettings {
                openSettings()
            } else {
                context.navigation.tab = .settings
            }
            try await Task.sleep(for: .milliseconds(600))
            NotificationCenter.default.post(name: .fluxoDebugAcknowledgements, object: argument.isEmpty ? nil : argument.lowercased())
        },
        DebugRoute("diagnostics[:sample|clear]", "Settings › About › Diagnostic Reports: pushed in Settings, a sheet in the Mac's Settings window. `sample` first keeps one invented report of each kind (screenshots of the list; nothing from MetricKit), `clear` deletes the kept reports. The reports of a harness run are in its isolated folder.") { context, argument in
            #if os(tvOS)
            throw DebugRouteError.unsupported("diagnostics")
            #else
            let store = DiagnosticsCollector.shared.store
            switch argument.lowercased() {
            case "":
                break
            case "sample":
                for (index, kind) in DiagnosticReportEntry.Kind.allCases.enumerated() {
                    let sample = Data("{\"debugSample\":\"\(kind.rawValue)\",\"note\":\"Invented by the debug harness; not a MetricKit report.\"}".utf8)
                    try store.save(sample, kind: kind, receivedOn: Date.now.addingTimeInterval(Double(-index) * 3_600))
                }
            case "clear":
                store.deleteAll()
            default:
                throw DebugRouteError.invalidArgument("diagnostics", argument)
            }
            if let openSettings = context.openSettings {
                openSettings()
            } else {
                context.navigation.tab = .settings
            }
            try await Task.sleep(for: .milliseconds(600))
            NotificationCenter.default.post(name: .fluxoDebugDiagnostics, object: nil)
            #endif
        },
    ]

    private static func report(_ line: String) {
        DebugLaunchOptions.logger.notice("\(line, privacy: .public)")
        let url = DebugEnvironment.statusDirectory.appendingPathComponent("links.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

extension Notification.Name {
    /// Debug harness (`settings-siri`): pushes Siri and Voice Search in Settings (Apple TV).
    static let fluxoDebugSiriPage = Notification.Name("FluxoDebugSiriPage")
}
#endif
