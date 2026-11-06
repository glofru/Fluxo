//
//  VisualSearchIntents.swift
//  Fluxo
//
//  Visual Intelligence (Apple Intelligence; iOS 27 and macOS 27): point the camera at a TV, a poster or a
//  programme listing, or take a screenshot, then tap Search, and Fluxo's results appear with the system's. The
//  system hands over a `SemanticContentDescriptor` (the labels it recognized and the pixels); Fluxo reads the
//  text in the image on this device (a channel logo, a programme title) and returns the channels that match:
//  by name, by a programme on now or later with that title, then by the labels as guide categories. Tapping a
//  result plays the channel (`PlayChannelIntent`, its `OpenIntent`); "More results" opens Fluxo's search.
//

import AppIntents
import CoreImage
import Foundation
import Vision
#if canImport(VisualIntelligence)
import VisualIntelligence

/// The channels for what Visual Intelligence sees.
@available(macOS 27.0, *)
struct ChannelVisualSearchQuery: IntentValueQuery {

    @Dependency
    var services: AppServices

    func values(for input: SemanticContentDescriptor) async throws -> [ChannelEntity] {
        let terms = await VisualSearchTerms(input, customWords: await services.visualSearchVocabulary())
        let items = await services.channels(forVisualSearch: terms)
        let names = ChannelEntityQuery.playlistNames(services.container)
        return items.compactMap { ChannelEntity($0, playlistName: names[$0.playlistID]) }
    }
}

/// "More results" of Visual Intelligence: Fluxo's search with the most prominent text of the image (else the
/// first label it recognized).
@available(macOS 27.0, *)
@AppIntent(schema: .visualIntelligence.semanticContentSearch)
struct VisualSearchInFluxoIntent {

    /// It shows Fluxo's search, so the app comes to the front.
    static let supportedModes: IntentModes = .foreground(.immediate)

    var semanticContent: SemanticContentDescriptor

    @Dependency
    var services: AppServices

    @MainActor
    func perform() async throws -> some IntentResult {
        let terms = await VisualSearchTerms(semanticContent, customWords: services.visualSearchVocabulary())
        services.showSearch(terms.searchText)
        return .result()
    }
}

#endif

/// The words to search for in an image: the lines of text read on this device, largest first, and the labels
/// of the system.
struct VisualSearchTerms: Sendable {

    /// Lines of text in the image, the largest (titles, logos) first.
    var lines: [String]

    /// What the system recognized ("Television", "Soccer"), in its order.
    var labels: [String]

    /// What Search opens with.
    var searchText: String {
        lines.first ?? labels.first ?? ""
    }

    init(lines: [String], labels: [String]) {
        self.lines = lines
        self.labels = labels
    }

    /// The lines of text in `image` worth searching for (`lines(from:)`), read on this device.
    static func readLines(in image: CGImage, customWords: [String]) async -> [String] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.customWords = customWords
        guard let observations = try? await request.perform(on: image) else {
            return []
        }
        return lines(from: observations.compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, $0.confidence, observation.boundingBox.height) }
        })
    }

    /// The distinct lines worth searching for, the tallest text first: at least three characters with a letter,
    /// confidently read, at most `limit`.
    static func lines(from candidates: [(text: String, confidence: Float, height: CGFloat)], limit: Int = 8) -> [String] {
        var seen: Set<String> = []
        return candidates
            .filter { $0.confidence >= 0.4 }
            .sorted { $0.height > $1.height }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { text in
                text.count >= 3 && text.contains(where: \.isLetter)
                    && seen.insert(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted
            }
            .prefix(limit)
            .map { $0 }
    }
}

extension AppServices {

    /// Channel names for the text recognizer: the favorites and the channels watched recently.
    nonisolated func visualSearchVocabulary() async -> [String] {
        let entities = (try? await ChannelEntityQuery.suggestions(container: container, limit: 100)) ?? []
        return entities.map(\.name)
    }

    /// The channels for an image, best first, at most `limit`: a channel named by a line of text (or showing a
    /// programme with that title now), then the channels of upcoming programmes with that title, then programmes
    /// on in the next hours whose guide category is one of the labels.
    func channels(forVisualSearch terms: VisualSearchTerms, limit: Int = 12) async -> [ChannelItem] {
        let importIDs = allImportIDs()
        guard !importIDs.isEmpty else {
            return []
        }
        var results: [ChannelItem] = []
        var seen: Set<String> = []
        func add(_ item: ChannelItem) {
            guard results.count < limit, seen.insert(item.bookmarkKey ?? item.displayName).inserted else {
                return
            }
            results.append(item)
        }

        for line in terms.lines {
            // Fuzzy matches are no answer here: any text in a photo would find some channel.
            if let resolution = await resolveChannel(line) {
                switch resolution.reason {
                case .name, .programme:
                    add(resolution.item)
                case .number, .closest:
                    break
                }
            }
        }
        if await waitForGuide() {
            for line in terms.lines {
                let words = SmartSearchRules.words(line)
                guard !words.isEmpty else {
                    continue
                }
                for result in await epg.searchProgrammes(line, importIDs: importIDs, limit: 20) {
                    let titleWords = SmartSearchRules.words(result.programme.title)
                    if words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) {
                        add(result.channel)
                    }
                }
            }
            let nextHours = DateInterval(start: .now, duration: 6 * 60 * 60)
            for label in terms.labels.prefix(4) {
                for result in await epg.searchProgrammes(inCategory: label, importIDs: importIDs, overlapping: nextHours, limit: 10) {
                    add(result.channel)
                }
            }
        }
        return results
    }
}

#if canImport(VisualIntelligence)
@available(macOS 27.0, *)
extension VisualSearchTerms {

    /// Reads the text of `descriptor`'s image; `customWords` (channel names) help the recognizer with names that
    /// are no dictionary words.
    init(_ descriptor: SemanticContentDescriptor, customWords: [String]) async {
        labels = descriptor.labels
        lines = []
        guard let pixelBuffer = descriptor.pixelBuffer else {
            return
        }
        // A copy of the pixels: the buffer is only lent for the duration of the closure.
        let image: CGImage? = pixelBuffer.withUnsafeBuffer { buffer in
            let ciImage = CIImage(cvPixelBuffer: buffer)
            return CIContext(options: [.cacheIntermediates: false]).createCGImage(ciImage, from: ciImage.extent)
        }
        guard let image else {
            return
        }
        lines = await Self.readLines(in: image, customWords: customWords)
    }
}
#endif
