//
//  ProgrammeSummarizer.swift
//  Fluxo
//
//  Short on-device summaries of long programme descriptions (TV guides often carry a full paragraph of plot,
//  cast and credits). The summary is streamed into the programme screen as the model writes it, and kept in
//  memory for the rest of the session.
//

import Foundation
import FoundationModels
import Observation
import os

@MainActor
@Observable
final class ProgrammeSummarizer {

    /// Descriptions shorter than this are shown as they are.
    static let minimumLength = 280
    private static let cacheLimit = 200
    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Intelligence")

    @ObservationIgnored
    private var cache: [String: String] = [:]
    @ObservationIgnored
    private var cacheOrder: [String] = []

    static func needsSummary(_ programme: GuideProgramme) -> Bool {
        programme.summary.count >= minimumLength
    }

    func cachedSummary(for programme: GuideProgramme) -> String? {
        cache[key(for: programme)]
    }

    /// Streams the summary of `programme`: each element is the text so far. Finishes at once with the cached
    /// summary when there is one; throws when the model fails.
    func summarize(_ programme: GuideProgramme) -> AsyncThrowingStream<String, Error> {
        let key = key(for: programme)
        if let cached = cache[key] {
            return AsyncThrowingStream { continuation in
                continuation.yield(cached)
                continuation.finish()
            }
        }
        #if os(tvOS)
        // No on-device model on Apple TV (`PlatformFeatures.onDeviceLanguageModel`): the description shows as it is.
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: OnDeviceModelUnavailable())
        }
        #else
        let prompt = Self.prompt(for: programme)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                do {
                    let session = OnDeviceModel.session(instructions: Self.instructions)
                    var latest = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: OnDeviceModel.options(maximumTokens: 120)) {
                        latest = snapshot.content
                        continuation.yield(latest)
                    }
                    var final = latest.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Written in another language than the app's (the guide's own language, usually): translate.
                    if !final.isEmpty, let localized = await OnDeviceModel.localized([final]).first, localized != final {
                        final = localized
                        continuation.yield(final)
                    }
                    if !final.isEmpty {
                        self?.store(final, for: key)
                    }
                    continuation.finish()
                } catch {
                    Self.logger.error("Summary failed: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        #endif
    }

    private func key(for programme: GuideProgramme) -> String {
        "\(programme.reminderKey)|\(programme.summary.count)"
    }

    private func store(_ summary: String, for key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = summary
        if cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    static var instructions: String {
        """
        You summarize TV programme descriptions for a TV guide. Write one or two short sentences, at most 40 \
        words, in \(OnDeviceModel.responseLanguageName), about what the programme is: the story or the topic. \
        Leave out cast lists, credits, ratings and the channel. Do not start with "This programme" or with the title.
        """
    }

    static func prompt(for programme: GuideProgramme) -> String {
        var lines = ["Title: \(programme.title)"]
        if let detail = programme.detailLine {
            lines.append("Episode: \(detail)")
        }
        if !programme.categories.isEmpty {
            lines.append("Categories: \(programme.categories.joined(separator: ", "))")
        }
        // The model's context is small; the start of a description carries the plot.
        lines.append("Description: \(programme.summary.prefix(2_400))")
        return lines.joined(separator: "\n")
    }
}
