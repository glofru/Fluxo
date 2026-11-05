//
//  TrackPreferences.swift
//  Fluxo
//
//  The audio and subtitle languages the user chose last, remembered for every channel, movie and episode
//  (`UserDefaults.fluxo`). A choice in the player's Audio and Subtitles menu is remembered, and the next item
//  that has a matching track starts with it; Settings > Audio and Subtitles shows and changes them.
//
//  Languages are kept as base language codes ("it", "en", "pt"), so "pt-BR" and "pt-PT" tracks both match "pt".
//  "Automatic" (nothing remembered) leaves the choice to the system: the user's languages and the
//  Subtitles & Captioning and Audio Descriptions settings in Accessibility.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum TrackPreferences {

    static let audioLanguageKey = "player.audioLanguage"
    static let audioDescriptionKey = "player.audioDescription"
    static let subtitleModeKey = "player.subtitleMode"
    static let subtitleLanguageKey = "player.subtitleLanguage"
    static let subtitleAccessibilityKey = "player.subtitleAccessibility"

    enum SubtitleMode: String, CaseIterable {
        /// The system decides (accessibility settings, a foreign language, forced subtitles).
        case automatic
        /// No subtitles, except forced ones (signs, foreign dialog) in the audio's language.
        case off
        /// Subtitles in `subtitleLanguage` when the item has them.
        case on
    }

    /// The remembered audio language, nil for Automatic.
    static var audioLanguage: String? {
        get { UserDefaults.fluxo.string(forKey: audioLanguageKey).flatMap(baseLanguage) }
        set { UserDefaults.fluxo.set(newValue.flatMap(baseLanguage), forKey: audioLanguageKey) }
    }

    /// The remembered audio track was an audio description.
    static var prefersAudioDescription: Bool {
        get { UserDefaults.fluxo.bool(forKey: audioDescriptionKey) }
        set { UserDefaults.fluxo.set(newValue, forKey: audioDescriptionKey) }
    }

    static var subtitleMode: SubtitleMode {
        get { UserDefaults.fluxo.string(forKey: subtitleModeKey).flatMap(SubtitleMode.init(rawValue:)) ?? .automatic }
        set { UserDefaults.fluxo.set(newValue.rawValue, forKey: subtitleModeKey) }
    }

    static var subtitleLanguage: String? {
        get { UserDefaults.fluxo.string(forKey: subtitleLanguageKey).flatMap(baseLanguage) }
        set { UserDefaults.fluxo.set(newValue.flatMap(baseLanguage), forKey: subtitleLanguageKey) }
    }

    /// The remembered subtitles were SDH or closed captions.
    static var prefersAccessibleSubtitles: Bool {
        get { UserDefaults.fluxo.bool(forKey: subtitleAccessibilityKey) }
        set { UserDefaults.fluxo.set(newValue, forKey: subtitleAccessibilityKey) }
    }

    // MARK: - Remembering a choice

    static func rememberAudio(_ option: AVMediaSelectionOption) {
        guard let language = language(of: option) else {
            return
        }
        audioLanguage = language
        prefersAudioDescription = option.hasMediaCharacteristic(.describesVideoForAccessibility)
    }

    static func rememberSubtitles(_ option: AVMediaSelectionOption) {
        guard let language = language(of: option) else {
            return
        }
        subtitleMode = .on
        subtitleLanguage = language
        prefersAccessibleSubtitles = isAccessible(option)
    }

    static func rememberSubtitlesOff() {
        subtitleMode = .off
    }

    static func rememberAutomaticSubtitles() {
        subtitleMode = .automatic
    }

    static func reset() {
        for key in [audioLanguageKey, audioDescriptionKey, subtitleModeKey, subtitleLanguageKey, subtitleAccessibilityKey] {
            UserDefaults.fluxo.removeObject(forKey: key)
        }
    }

    // MARK: - Applying them

    /// The audio option to start with, or nil to keep the one AVFoundation chose.
    static func preferredAudio(in options: [AVMediaSelectionOption]) -> AVMediaSelectionOption? {
        guard options.count > 1, let audioLanguage else {
            return nil
        }
        let matches = options.filter { language(of: $0) == audioLanguage }
        let wantsDescription = prefersAudioDescription
        return matches.first { $0.hasMediaCharacteristic(.describesVideoForAccessibility) == wantsDescription } ?? matches.first
    }

    /// The subtitle option to start with (from the non-forced options), or nil when the mode is not `.on` or
    /// the item has nothing in that language.
    static func preferredSubtitles(in options: [AVMediaSelectionOption]) -> AVMediaSelectionOption? {
        guard subtitleMode == .on, let subtitleLanguage else {
            return nil
        }
        let matches = options.filter { language(of: $0) == subtitleLanguage }
        let wantsAccessible = prefersAccessibleSubtitles
        return matches.first { isAccessible($0) == wantsAccessible } ?? matches.first
    }

    // MARK: - Languages

    /// The base language code of an option ("en" for "en-US"), or nil when it has none.
    static func language(of option: AVMediaSelectionOption) -> String? {
        if let tag = option.extendedLanguageTag, let language = baseLanguage(tag) {
            return language
        }
        return option.locale.flatMap { $0.language.languageCode?.identifier }.flatMap(baseLanguage)
    }

    /// "pt-BR" → "pt", "eng" → "en"; nil for "und" and empty tags.
    static func baseLanguage(_ tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let code = Locale.Language(identifier: trimmed).languageCode?.identifier.lowercased(), !code.isEmpty, code != "und" else {
            return nil
        }
        return code
    }

    /// The language's name in the user's language ("Italian"), capitalized for a menu.
    static func displayName(forLanguage code: String) -> String {
        guard let name = Locale.current.localizedString(forLanguageCode: code) else {
            return code
        }
        return name.prefix(1).capitalized(with: Locale.current) + name.dropFirst()
    }

    static func isAccessible(_ option: AVMediaSelectionOption) -> Bool {
        option.mediaType == .closedCaption
            || (option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                && option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility))
    }
}

/// The files "Load Subtitle File…" accepts.
enum SubtitleFileTypes {
    static var all: [UTType] {
        let declared = SubtitleFile.fileExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .text) ?? UTType(filenameExtension: $0) }
        // Some SubRip files are saved as .txt.
        return declared + [.plainText]
    }
}
