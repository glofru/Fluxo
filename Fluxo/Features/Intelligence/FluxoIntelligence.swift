//
//  FluxoIntelligence.swift
//  Fluxo
//
//  Apple Intelligence in Fluxo: availability of the on-device model and the features built on it
//  (recommendations, smart search, programme summaries).
//
//  Everything runs on the device with the Foundation Models framework (`SystemLanguageModel.default`). No
//  request ever leaves the device: there is no Private Cloud Compute or third-party model. Every feature has a
//  deterministic fallback, so the app works the same (with plainer results) when Apple Intelligence is off,
//  not supported, still downloading, or does not speak the device language.
//

import Foundation
import FoundationModels
import NaturalLanguage
import Observation
import os
import SwiftData

/// Whether the on-device model can be used now, and why not.
enum IntelligenceStatus: Equatable, Sendable {
    case available
    /// Turned off in Fluxo's settings.
    case turnedOff
    /// Apple Intelligence is off in the system settings.
    case appleIntelligenceOff
    /// The device does not support Apple Intelligence.
    case deviceNotEligible
    /// The model is still downloading or preparing.
    case modelNotReady
    /// The model does not support the language of the app.
    case unsupportedLanguage

    var isAvailable: Bool {
        self == .available
    }

    /// A short explanation for Settings, or nil when the features are available.
    var explanation: String? {
        switch self {
        case .available:
            return nil
        case .turnedOff:
            return String(localized: "Turned off. Fluxo uses simpler suggestions and search.")
        case .appleIntelligenceOff:
            return String(localized: "Turn on Apple Intelligence in the Settings app to get personal suggestions, smart search and summaries.")
        case .deviceNotEligible:
            return String(localized: "This device does not support Apple Intelligence. Fluxo uses simpler suggestions and search.")
        case .modelNotReady:
            return String(localized: "Apple Intelligence is getting ready. Its features turn on once the model has downloaded.")
        case .unsupportedLanguage:
            return String(localized: "Apple Intelligence does not support the language Fluxo uses yet.")
        }
    }
}

/// The app's entry point to Apple Intelligence: the current availability, the user's switch, and the feature
/// engines. One instance, owned by `FluxoApp` and shared through the environment.
@MainActor
@Observable
final class FluxoIntelligence {

    nonisolated static let enabledKey = "intelligence.enabled"

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Intelligence")

    private(set) var status: IntelligenceStatus = .deviceNotEligible

    /// Personal recommendations for Home and the Guide.
    let recommendations: RecommendationCenter
    /// Short summaries of long programme descriptions.
    let summaries: ProgrammeSummarizer

    init(container: ModelContainer, epg: EPGStore) {
        recommendations = RecommendationCenter(container: container, epg: epg)
        summaries = ProgrammeSummarizer()
        recommendations.intelligence = self
        refreshAvailability()
    }

    /// The user's switch in Settings (on by default).
    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return UserDefaults.fluxo.object(forKey: Self.enabledKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                UserDefaults.fluxo.set(newValue, forKey: Self.enabledKey)
            }
            refreshAvailability()
        }
    }

    var isAvailable: Bool {
        status.isAvailable
    }

    /// Re-reads the model availability. Call when the app becomes active: Apple Intelligence can be turned on
    /// or off, and the model can finish downloading, while the app runs.
    func refreshAvailability() {
        let newStatus = Self.currentStatus(isEnabled: isEnabled)
        if newStatus != status {
            Self.logger.notice("Apple Intelligence status: \(String(describing: newStatus), privacy: .public)")
            status = newStatus
        }
    }

    /// The model availability, without the user's switch (Settings shows it next to the switch).
    nonisolated static func systemStatus() -> IntelligenceStatus {
        #if DEBUG
        if let forced = debugForcedStatus {
            return forced
        }
        #endif
        #if os(tvOS)
        // No on-device model on Apple TV (`PlatformFeatures.onDeviceLanguageModel`): the fallbacks, always.
        return .deviceNotEligible
        #else
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            // The language the responses are written in (the app's), which can differ from the system's.
            return model.supportsLocale(OnDeviceModel.responseLocale) ? .available : .unsupportedLanguage
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .deviceNotEligible
        }
        #endif
    }

    private nonisolated static func currentStatus(isEnabled: Bool) -> IntelligenceStatus {
        let system = systemStatus()
        if system == .available && !isEnabled {
            return .turnedOff
        }
        return system
    }

    #if DEBUG
    /// `-FluxoDebugIntelligence available|off|unavailable|notReady|unsupported` forces a status, to check the
    /// fallbacks on a device or simulator that has the model (and the real path on one that has not, for
    /// `available`, which then fails at generation time and falls back).
    private nonisolated static var debugForcedStatus: IntelligenceStatus? {
        switch UserDefaults.standard.string(forKey: "FluxoDebugIntelligence")?.lowercased() {
        case "available":
            return .available
        case "off", "appleintelligenceoff":
            return .appleIntelligenceOff
        case "unavailable", "noteligible":
            return .deviceNotEligible
        case "notready":
            return .modelNotReady
        case "unsupported":
            return .unsupportedLanguage
        default:
            return nil
        }
    }
    #endif
}

/// Shared settings of the on-device model sessions.
enum OnDeviceModel {

    /// The localization the app runs in ("it", "pt-BR", "zh-Hant"): the language of its interface, which the
    /// generated text must match. Not `Locale.current`, whose language may be one the app has no strings for,
    /// and whose identifier can drop the script ("zh-TW").
    static var responseLanguage: Locale.Language {
        Locale.Language(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// The locale of the app's language, for case mapping of generated text (Turkish dotted İ).
    static var responseLocale: Locale {
        Locale(identifier: responseLanguage.minimalIdentifier)
    }

    /// English name of the language the app runs in, for the instructions ("Write in Italian."). Names the
    /// script or the region where they matter: "Chinese (Traditional)", "Portuguese (Brazil)".
    static var responseLanguageName: String {
        let english = Locale(identifier: "en")
        let language = responseLanguage
        let code = language.languageCode?.identifier ?? "en"
        let name = english.localizedString(forLanguageCode: code) ?? "English"
        if code == "zh" {
            let script = language.maximalIdentifier.contains("Hant") ? "Hant" : "Hans"
            return "\(name) (\(english.localizedString(forScriptCode: script) ?? script))"
        }
        if let region = language.region?.identifier, let regionName = english.localizedString(forRegionCode: region) {
            return "\(name) (\(regionName))"
        }
        return name
    }

    /// Language code of the app ("it", "zh"), for prompts that only depend on the language.
    static var responseLanguageCode: String {
        responseLanguage.languageCode?.identifier ?? "en"
    }

    /// Whether `detected` (from `NLLanguageRecognizer`) is the app's language. Chinese is compared with its
    /// script, as the recognizer tells Simplified ("zh-Hans") from Traditional ("zh-Hant"); other languages by
    /// their code ("pt" for pt-BR).
    static func isResponseLanguage(_ detected: NLLanguage) -> Bool {
        let code = responseLanguageCode
        guard code == "zh" else {
            return Locale.Language(identifier: detected.rawValue).languageCode?.identifier == code
        }
        let script = responseLanguage.maximalIdentifier.contains("Hant") ? NLLanguage.traditionalChinese : .simplifiedChinese
        return detected == script
    }

    /// The instruction that makes the model write user-facing text in the app's language.
    static var languageInstruction: String {
        "The viewer reads \(responseLanguageName). Write every reason in \(responseLanguageName) only."
    }

    /// Makes sure short generated texts are in the app's language. The small on-device model sometimes answers
    /// in English when the prompt is English and the names in it are not; such texts are then translated in one
    /// request (they are a few short lines). Returns the input when it is already right or the translation fails.
    @concurrent static func localized(_ texts: [String]) async -> [String] {
        #if os(tvOS)
        return texts
        #else
        let joined = texts.joined(separator: ". ")
        guard !texts.isEmpty, !joined.isEmpty else {
            return texts
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(joined)
        guard let detected = recognizer.dominantLanguage, !isResponseLanguage(detected) else {
            return texts
        }
        do {
            let session = session(instructions: "You translate short captions of a TV app into \(responseLanguageName). Keep them short and natural, addressed to the viewer. Keep channel and programme names as they are.")
            let prompt = "Translate each line into \(responseLanguageName):\n" + texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let response = try await withTimeout(seconds: 15) {
                try await session.respond(to: prompt, generating: TranslatedLines.self, options: options(maximumTokens: 60 * texts.count + 40))
            }
            let lines = response.content.lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return lines.count == texts.count && !lines.contains(where: \.isEmpty) ? lines : texts
        } catch {
            return texts
        }
        #endif
    }

    #if !os(tvOS)
    /// A new session on the on-device model. Sessions are cheap; each request uses its own, so requests never
    /// share a transcript (and its context window).
    static func session(tools: [any Tool] = [], instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: .default, tools: tools, instructions: instructions)
    }

    /// Low temperature: picks and query plans should be stable from one run to the next.
    static func options(maximumTokens: Int) -> GenerationOptions {
        GenerationOptions(temperature: 0.3, maximumResponseTokens: maximumTokens)
    }
    #endif

    /// Runs `operation`, giving up after `seconds` (the on-device model can be slow on a busy device; the
    /// feature then keeps its fallback result).
    @concurrent static func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable @concurrent () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            defer {
                group.cancelAll()
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }
}

/// Thrown by the features built on the on-device model where there is none (Apple TV): they keep their fallback.
struct OnDeviceModelUnavailable: Error {}

#if !os(tvOS)
@Generable
struct TranslatedLines {
    @Guide(description: "The translated lines, in the same order, one per input line.")
    var lines: [String]
}
#endif
