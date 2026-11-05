//
//  DebugIntentRoutes.swift
//  Fluxo
//
//  Debug harness: runs the App Intents in process, the way Siri and Shortcuts run them, on the seeded library.
//  Entity parameters are resolved through the entity queries (`entities(matching:)`, as Siri resolves the words it
//  heard), then `perform()` runs. Each step appends one line to tmp/FluxoDebug/Status/intents.log (and the log):
//  the parameters, the result or the error the user would hear, and the player state afterwards.
//
//      -FluxoDebugRoute "seed-guide;intent:play:Sky F1;intent:whats-on:Rai 1;siri-names"
//
//  What it does not check is Siri itself (speech, phrase matching, the system's process launch): see
//  "Siri & Apple Intelligence" in the README for the device steps.
//

#if DEBUG
import AppIntents
import CoreGraphics
import CoreSpotlight
import CoreText
import Foundation
import Synchronization

/// The intents and queries whose `services` the harness sets.
protocol DebugServicesInjectable {
    var services: AppServices { get set }
}

extension ContinueWatchingIntent: DebugServicesInjectable {}
extension StopPlaybackIntent: DebugServicesInjectable {}
extension PausePlaybackIntent: DebugServicesInjectable {}
extension ResumePlaybackIntent: DebugServicesInjectable {}
extension GetRecommendationsIntent: DebugServicesInjectable {}
extension GetFavoritesIntent: DebugServicesInjectable {}
extension OpenFluxoIntent: DebugServicesInjectable {}
extension RecordingIntent: DebugServicesInjectable {}

@MainActor
enum DebugIntentRoutes {

    static let all: [DebugRoute] = coreRoutes + visualRoutes

    private static let coreRoutes: [DebugRoute] = [
        DebugRoute("intent:<action>[:<words>]", "Runs an App Intent in process (actions: \(actions.keys.sorted().joined(separator: ", "))); writes the outcome to Status/intents.log.") { _, argument in
            let parts = argument.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
            let words = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            guard let action = actions[name] else {
                throw DebugRouteError.invalidArgument("intent", argument)
            }
            let services = try services()
            do {
                let outcome = try await action(words)
                report("intent \(name) \"\(words)\" → \(outcome) \(playerState(services))")
            } catch {
                report("intent \(name) \"\(words)\" → error: \(message(for: error)) \(playerState(services))")
            }
        },
        DebugRoute("siri-resolve:<words>", "Resolves spoken words to a channel like \"Play … in Fluxo\" (PlayByNameIntent).") { _, argument in
            let services = try services()
            if let resolution = await services.resolveChannel(argument) {
                report("resolve \"\(argument)\" → \(resolution.item.displayName) [\(resolution.reason)] number=\(resolution.item.number.map(String.init) ?? "-")")
            } else {
                report("resolve \"\(argument)\" → nothing")
            }
        },
        DebugRoute("siri-resolve-check", "Checks the channel-number rules (\"channel 5\" is a number, \"BBC 9\" is not) and, on the sample library, that names it lacks do not resolve to another channel.") { _, _ in
            let services = try services()
            var failures: [String] = []
            func expect(_ condition: Bool, _ what: String) {
                if !condition {
                    failures.append(what)
                }
            }
            let numbers: [(String, Int?)] = [
                ("5", 5), ("#5", 5), ("channel 5", 5), ("Channel number 7", 7), ("canale 105", 105), ("canale numero 3", 3),
                ("chaîne 2", 2), ("Kanal 4", 4), ("kanał 6", 6), ("n°5", 5), ("No. 9", 9), ("5チャンネル", 5), ("第5频道", 5),
                ("5번 채널", 5), ("канал 3", 3), ("قناة ٥", 5),
                ("BBC 9", nil), ("Eurosport 7", nil), ("Rai 4", nil), ("Sky Sport 24", nil), ("F1", nil), ("20:45", nil),
                ("channel 0", nil), ("the 5 o'clock show", nil),
            ]
            for (term, expected) in numbers {
                let digits = ChannelResolver.digitsForNumberWords(term)
                expect(ChannelResolver.channelNumber(in: digits) == expected, "channelNumber(\"\(term)\") = \(ChannelResolver.channelNumber(in: digits).map(String.init) ?? "nil"), expected \(expected.map(String.init) ?? "nil")")
            }
            expect(ChannelResolver.channelNumber(in: ChannelResolver.digitsForNumberWords("channel four")) == 4, "\"channel four\" is number 4")
            expect(ChannelResolver.channelNumber(in: ChannelResolver.digitsForNumberWords("BBC Four")) == nil, "\"BBC Four\" is not a number")
            let names: [(String, String, Bool)] = [
                ("Eurosport 7", "Eurosport 1", false), ("Eurosport 2", "Eurosport 2 HD", true), ("sky sport f 1", "Sky Sport F1", true),
                ("Rai 4", "Rai 14", false), ("Rai Uno", "Rai 1 HD", true), ("Rai 1", "Rai Uno", true), ("Sky Cinema", "Sky Cinema Uno", true),
            ]
            for (term, name, expected) in names {
                let has = ChannelResolver.hasNumbers(of: ChannelResolver.digitsForNumberWords(term), inName: name)
                expect(has == expected, "hasNumbers(\"\(term)\", \"\(name)\") = \(has)")
            }
            // On the sample library (Eurosport 1 and 2, no BBC): names it lacks find nothing.
            for term in ["BBC 9", "Eurosport 7", "Rai 9", "BBC Four"] {
                if let resolution = await services.resolveChannel(term) {
                    failures.append("resolve \"\(term)\" → \(resolution.item.displayName) [\(resolution.reason)], expected nothing")
                }
                let query = ChannelEntityQuery()
                query.services = services
                let entities = try await query.entities(matching: term)
                expect(entities.allSatisfy { ChannelResolver.hasNumbers(of: ChannelResolver.digitsForNumberWords(term), inName: $0.name) }, "entities(matching: \"\(term)\") offers \(entities.map(\.name))")
            }
            report(failures.isEmpty ? "siri-resolve-check: ok" : "siri-resolve-check: \(failures.count) failed\n  " + failures.joined(separator: "\n  "))
        },
        DebugRoute("siri-names", "Lists the channels Siri knows by name for the phrases (suggested entities) with their synonyms.") { _, _ in
            let services = try services()
            let entities = try await ChannelEntityQuery.parameterSuggestions(container: services.container)
            let lines = entities.map { entity in
                let synonyms = entity.displayRepresentation.synonyms.map { String(localized: $0) }
                return "  \(entity.name) [\(entity.kind.rawValue)] synonyms: \(synonyms.joined(separator: " | "))"
            }
            report("siri-names: \(entities.count) channels\n" + lines.joined(separator: "\n"))
        },
        DebugRoute("spotlight-search:<words>", "Searches the app's own Spotlight entries (checks that channels were indexed).") { _, argument in
            let titles = try await spotlightTitles(matching: argument)
            report("spotlight \"\(argument)\" → \(titles.count) items: \(titles.prefix(20).joined(separator: ", "))")
        },
        DebugRoute("spotlight-reindex", "Indexes the favorites and recently watched channels in Spotlight now, timing each call.") { _, _ in
            let services = try services()
            let entities = try await ChannelEntityQuery.suggestions(container: services.container, limit: ChannelSpotlightIndexer.limit)
            report("spotlight-reindex: \(entities.count) channels: " + (await timed { try await ChannelSpotlightIndexer.replaceIndex(with: entities) }))
        },
    ]

    /// Visual Intelligence's search (the matching and the text recognition; the system's side is not in the
    /// Simulator).
    private static let visualRoutes: [DebugRoute] = [
        DebugRoute("visual-search:<line>[|<line>…][#<label>,…]", "Visual Intelligence: the channels for these lines of text (as read in an image) and labels.") { _, argument in
            let services = try services()
            let parts = argument.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let lines = parts[0].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let labels = parts.count > 1 ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : []
            let items = await services.channels(forVisualSearch: VisualSearchTerms(lines: lines, labels: labels))
            report("visual-search \(lines) \(labels) → \(items.count) channels: \(items.map(\.displayName).joined(separator: ", "))")
        },
        DebugRoute("visual-ocr:<text>[|<text>…]", "Visual Intelligence: draws the texts in an image (the first one largest), reads it like a Visual Intelligence image, and searches.") { _, argument in
            let services = try services()
            let texts = argument.split(separator: "|").map(String.init)
            guard let image = renderedText(texts) else {
                throw DebugRouteError.invalidArgument("visual-ocr", argument)
            }
            let lines = await VisualSearchTerms.readLines(in: image, customWords: await services.visualSearchVocabulary())
            let items = await services.channels(forVisualSearch: VisualSearchTerms(lines: lines, labels: []))
            report("visual-ocr read \(lines) → \(items.count) channels: \(items.map(\.displayName).joined(separator: ", "))")
        },
    ]

    /// White texts on a dark background, like a TV picture: the first one large (a title), the others smaller.
    private static func renderedText(_ texts: [String]) -> CGImage? {
        let size = CGSize(width: 1200, height: 800)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        var y = size.height - 180
        for (index, text) in texts.enumerated() {
            let fontSize: CGFloat = index == 0 ? 96 : 44
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(line, context)
            y -= fontSize * 1.8
        }
        return context.makeImage()
    }

    /// The actions of `intent:`. Each one builds the intent, resolves its parameters and runs it.
    private static let actions: [String: @MainActor (String) async throws -> String] = [
        "play": { words in
            var intent = PlayChannelIntent()
            intent.services = try services()
            intent.target = try await channel(words)
            _ = try await intent.perform()
            return "played \(intent.target.name)"
        },
        "play-name": { words in
            var intent = PlayByNameIntent()
            intent.services = try services()
            intent.term = words
            return describe(try await intent.perform())
        },
        "continue": { _ in
            describe(try await injected(ContinueWatchingIntent()).perform())
        },
        "stop": { _ in
            describe(try await injected(StopPlaybackIntent()).perform())
        },
        "pause": { _ in
            describe(try await injected(PausePlaybackIntent()).perform())
        },
        "resume": { _ in
            describe(try await injected(ResumePlaybackIntent()).perform())
        },
        "whats-on": { words in
            var intent = WhatsOnIntent()
            intent.services = try services()
            intent.channel = words.isEmpty ? nil : try await channel(words)
            return describe(try await intent.perform())
        },
        "search-guide": { words in
            var intent = SearchProgrammesIntent()
            intent.services = try services()
            intent.query = words
            return describe(try await intent.perform())
        },
        "find": { words in
            var intent = FindChannelsIntent()
            intent.services = try services()
            intent.query = words
            return describe(try await intent.perform())
        },
        "search": { words in
            var intent = SearchInFluxoIntent()
            intent.services = try services()
            intent.criteria = StringSearchCriteria(term: words)
            _ = try await intent.perform()
            return "searched \"\(words)\""
        },
        "suggestions": { _ in
            describe(try await injected(GetRecommendationsIntent()).perform())
        },
        "favorites": { _ in
            describe(try await injected(GetFavoritesIntent()).perform())
        },
        "favorite-add": { words in
            var intent = AddFavoriteIntent()
            intent.services = try services()
            intent.channel = words.isEmpty ? nil : try await channel(words)
            return describe(try await intent.perform())
        },
        "favorite-remove": { words in
            var intent = RemoveFavoriteIntent()
            intent.services = try services()
            intent.channel = words.isEmpty ? nil : try await channel(words)
            return describe(try await intent.perform())
        },
        "schedule": { words in
            var intent = ShowScheduleIntent()
            intent.services = try services()
            intent.channel = words.isEmpty ? nil : try await channel(words)
            _ = try await intent.perform()
            return "schedule of \(intent.channel?.name ?? "the current channel")"
        },
        "open": { words in
            guard let destination = FluxoDestination(rawValue: words.lowercased()) else {
                throw DebugRouteError.invalidArgument("intent open", words)
            }
            _ = try await injected(OpenFluxoIntent(target: destination)).perform()
            return "opened \(destination.rawValue)"
        },
        "record-start": { words in
            var intent = RecordingIntent(action: .start)
            intent.services = try services()
            intent.channel = words.isEmpty ? nil : try await channel(words)
            return describe(try await intent.perform())
        },
        "record-stop": { _ in
            describe(try await injected(RecordingIntent(action: .stop)).perform())
        },
        "reminder": { words in
            // The first programme of the guide search that has not started.
            var query = ProgramEntityQuery()
            query.services = try services()
            let programmes = try await query.entities(matching: words)
            guard let program = programmes.first(where: { $0.start > .now }) else {
                throw DebugRouteError.notFound("future programme", words)
            }
            var intent = SetReminderIntent()
            intent.services = try services()
            intent.program = program
            return describe(try await intent.perform())
        },
    ]

    /// `@Dependency` resolves only for intents the AppIntents runtime runs: give these the app's services.
    private static func injected<Intent: AppIntent>(_ intent: Intent) throws -> Intent {
        var intent = intent
        let services = try services()
        if var dependent = intent as? any DebugServicesInjectable {
            dependent.services = services
            intent = dependent as! Intent
        }
        return intent
    }

    /// Runs `operation` and says how long it took, or that it did not return within `limit`.
    private static func timed(limit: Duration = .seconds(15), _ operation: @escaping @Sendable () async throws -> Void) async -> String {
        let clock = ContinuousClock()
        let start = clock.now
        let done = Mutex(false)
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (String) -> Void = { text in
                if done.withLock({ wasDone in defer { wasDone = true }; return !wasDone }) {
                    continuation.resume(returning: text)
                }
            }
            Task {
                do {
                    try await operation()
                    finish("ok in \(clock.now - start)")
                } catch {
                    finish("error after \(clock.now - start): \(error)")
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                finish("no answer after \(limit)")
            }
        }
    }

    /// The channel Siri would resolve for these words: the first match of the entity query.
    private static func channel(_ words: String) async throws -> ChannelEntity {
        let query = ChannelEntityQuery()
        query.services = try services()
        guard let entity = try await query.entities(matching: words).first else {
            throw DebugRouteError.notFound("channel entity", words)
        }
        return entity
    }

    private static func services() throws -> AppServices {
        guard let services = AppServices.debugShared else {
            throw DebugRouteError.notFound("app services", "AppServices")
        }
        return services
    }

    /// The dialog and value of an intent result, from its reflection (the result type is opaque).
    private static func describe(_ result: some IntentResult) -> String {
        var parts: [String] = []
        func visit(_ value: Any, depth: Int) {
            guard depth < 8 else {
                return
            }
            if let dialog = value as? IntentDialog {
                parts.append("dialog: \"\(text(of: dialog))\"")
                return
            }
            if let entities = value as? [ChannelEntity] {
                parts.append("channels: \(entities.prefix(8).map(\.name).joined(separator: ", "))")
                return
            }
            if let entities = value as? [ProgramEntity] {
                parts.append("programmes: \(entities.prefix(6).map { "\($0.title) (\($0.channel.name))" }.joined(separator: ", "))")
                return
            }
            for child in Mirror(reflecting: value).children {
                visit(child.value, depth: depth + 1)
            }
        }
        visit(result, depth: 0)
        return parts.isEmpty ? "done" : parts.joined(separator: "; ")
    }

    /// The text of a dialog, from its reflection (its `LocalizedStringResource`).
    private static func text(of dialog: IntentDialog) -> String {
        var found: String?
        func visit(_ value: Any, depth: Int) {
            guard found == nil, depth < 6 else {
                return
            }
            if let resource = value as? LocalizedStringResource {
                found = String(localized: resource)
                return
            }
            for child in Mirror(reflecting: value).children {
                visit(child.value, depth: depth + 1)
            }
        }
        visit(dialog, depth: 0)
        return found ?? formatted(String(describing: dialog))
    }

    /// The dialog's text from its description (its resource is an Objective-C object Mirror cannot enter): the key
    /// with the argument values put in.
    private static func formatted(_ description: String) -> String {
        guard let keyRange = description.range(of: #"key: "(.*?)", defaultValue"#, options: .regularExpression) else {
            return description
        }
        var key = String(description[keyRange]).replacingOccurrences(of: "key: \"", with: "").replacingOccurrences(of: "\", defaultValue", with: "")
        let values = description.matches(of: /Storage\.value\((.*?)\)\)/).map { String($0.output.1).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        for value in values {
            guard let placeholder = key.range(of: #"%(lld|ld|d|@)"#, options: .regularExpression) else {
                break
            }
            key.replaceSubrange(placeholder, with: value)
        }
        return key
    }

    private static func message(for error: Error) -> String {
        if let error = error as? FluxoIntentError {
            return String(localized: error.localizedStringResource)
        }
        return error.localizedDescription
    }

    private static func playerState(_ services: AppServices) -> String {
        let player = services.player
        return "[player: \(player.currentChannel?.name ?? "none"), \(player.playbackState.label)\(player.isRecording ? ", recording" : "")]"
    }

    /// The titles of the app's Spotlight items matching `words`. In the Simulator the query sometimes never
    /// completes: after `limit` it is cancelled and what was found so far is returned (marked as partial).
    private static func spotlightTitles(matching words: String, limit: Duration = .seconds(10)) async throws -> [String] {
        #if os(tvOS)
        throw DebugRouteError.check("tvOS has no Spotlight index of app content (PlatformFeatures.spotlightIndexing)")
        #else
        let escaped = words.replacingOccurrences(of: "\"", with: "")
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title"]
        let query = CSSearchQuery(queryString: "title == \"*\(escaped)*\"cd", queryContext: context)
        let found = Mutex<[String]>([])
        let finished = Mutex(false)
        return try await withCheckedThrowingContinuation { continuation in
            let finish: @Sendable (Result<[String], Error>) -> Void = { result in
                if finished.withLock({ wasFinished in defer { wasFinished = true }; return !wasFinished }) {
                    continuation.resume(with: result)
                }
            }
            query.foundItemsHandler = { items in
                let titles = items.compactMap(\.attributeSet.title)
                found.withLock { $0.append(contentsOf: titles) }
            }
            query.completionHandler = { error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(found.withLock { $0 }))
                }
            }
            query.start()
            Task {
                try? await Task.sleep(for: limit)
                query.cancel()
                finish(.success(found.withLock { $0 } + ["(query did not complete within \(limit))"]))
            }
        }
        #endif
    }

    /// Appends a line to Status/intents.log and logs it.
    private static func report(_ line: String) {
        DebugLaunchOptions.logger.notice("\(line, privacy: .public)")
        let url = DebugEnvironment.statusDirectory.appendingPathComponent("intents.log")
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
#endif
