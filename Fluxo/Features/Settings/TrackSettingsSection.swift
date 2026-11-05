//
//  TrackSettingsSection.swift
//  Fluxo
//
//  Settings > Audio and Subtitles: the languages the player starts with (`TrackPreferences`). The player's Audio
//  and Subtitles menu changes them too: a track chosen there is remembered.
//

import SwiftUI

struct TrackSettingsSection: View {

    @AppStorage(TrackPreferences.audioLanguageKey) private var audioLanguage = ""
    @AppStorage(TrackPreferences.subtitleModeKey) private var subtitleMode = TrackPreferences.SubtitleMode.automatic.rawValue
    @AppStorage(TrackPreferences.subtitleLanguageKey) private var subtitleLanguage = ""

    /// A subtitle choice: Automatic, Off or a language.
    private enum SubtitleSetting: Hashable {
        case automatic
        case off
        case language(String)
    }

    var body: some View {
        Section {
            Picker(selection: audioSelection) {
                Text("Automatic").tag("")
                ForEach(Self.languages(including: audioLanguage), id: \.self) { code in
                    Text(TrackPreferences.displayName(forLanguage: code)).tag(code)
                }
            } label: {
                SettingsLabel("Audio language", systemImage: "waveform", tint: Theme.accent)
            }

            Picker(selection: subtitleSelection) {
                Text("Automatic").tag(SubtitleSetting.automatic)
                Text("Off").tag(SubtitleSetting.off)
                ForEach(Self.languages(including: subtitleLanguage), id: \.self) { code in
                    Text(TrackPreferences.displayName(forLanguage: code)).tag(SubtitleSetting.language(code))
                }
            } label: {
                SettingsLabel("Subtitles", systemImage: "captions.bubble", tint: Theme.accent)
            }
        } header: {
            Text("Audio and Subtitles")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        #if os(macOS)
        String(localized: "Channels, movies and episodes start with these languages when they have them; a track you choose in the player is remembered. Automatic follows your preferred languages and the Captions settings in System Settings > Accessibility, which also set the subtitle style.", comment: "Footer of the Audio and Subtitles settings on the Mac.")
        #else
        String(localized: "Channels, movies and episodes start with these languages when they have them; a track you choose in the player is remembered. Automatic follows your preferred languages and Settings > Accessibility > Subtitles & Captioning, which also sets the subtitle style.", comment: "Footer of the Audio and Subtitles settings on iPhone and iPad.")
        #endif
    }

    private var audioSelection: Binding<String> {
        Binding {
            TrackPreferences.audioLanguage ?? ""
        } set: { code in
            audioLanguage = code
            if code.isEmpty {
                UserDefaults.fluxo.removeObject(forKey: TrackPreferences.audioLanguageKey)
                TrackPreferences.prefersAudioDescription = false
            }
        }
    }

    private var subtitleSelection: Binding<SubtitleSetting> {
        Binding {
            switch TrackPreferences.SubtitleMode(rawValue: subtitleMode) ?? .automatic {
            case .automatic:
                return .automatic
            case .off:
                return .off
            case .on:
                return TrackPreferences.subtitleLanguage.map(SubtitleSetting.language) ?? .automatic
            }
        } set: { setting in
            switch setting {
            case .automatic:
                subtitleMode = TrackPreferences.SubtitleMode.automatic.rawValue
            case .off:
                subtitleMode = TrackPreferences.SubtitleMode.off.rawValue
            case .language(let code):
                subtitleLanguage = code
                subtitleMode = TrackPreferences.SubtitleMode.on.rawValue
            }
        }
    }

    /// The user's own languages first, then common languages of TV and film, with the remembered one if it is
    /// another, sorted by name after the user's own.
    private static func languages(including current: String) -> [String] {
        let preferred = Locale.preferredLanguages.compactMap(TrackPreferences.baseLanguage)
        var codes: [String] = []
        for code in preferred where !codes.contains(code) {
            codes.append(code)
        }
        let common = ["ar", "de", "el", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "pl", "pt", "ru", "sv", "tr", "uk", "zh"]
        var others = common.filter { !codes.contains($0) }
        if let current = TrackPreferences.baseLanguage(current), !codes.contains(current), !others.contains(current) {
            others.append(current)
        }
        others.sort { TrackPreferences.displayName(forLanguage: $0).localizedStandardCompare(TrackPreferences.displayName(forLanguage: $1)) == .orderedAscending }
        return codes + others
    }
}
