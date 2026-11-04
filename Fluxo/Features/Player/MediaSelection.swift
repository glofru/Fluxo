//
//  MediaSelection.swift
//  Fluxo
//
//  Audio tracks and subtitles / closed captions of the item that plays (AVMediaSelection), and the player's
//  menu to choose them.
//
//  AVPlayer keeps `appliesMediaSelectionCriteriaAutomatically` on, so by default it follows the system settings:
//  Settings > Accessibility > Subtitles & Captioning ("Closed Captions + SDH" picks the SDH subtitles or the
//  closed captions when there are any) and Audio Descriptions (picks the described audio track), and the user's
//  languages. The captions are drawn by the AVPlayerLayer itself, in the caption style chosen there (font, size,
//  colors, background), also in Picture in Picture. A choice in the menu overrides the automatic selection for
//  that item; "Automatic" in Subtitles gives it back to the system.
//
//  What is listed is what the stream has: the renditions of an HLS playlist (EXT-X-MEDIA audio, subtitles and
//  closed captions), the tracks of an MP4 / MOV file, and the CEA-608 captions carried in the video of a live
//  MPEG-TS channel (the remux engine copies them with the video).
//

import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MediaSelectionController {

    /// One audio track or subtitle option, as the menu lists it.
    struct Track: Identifiable, Hashable {
        /// Index of the option in its group.
        let id: Int
        /// The option's name in the user's language ("English", "Italiano", "English (SDH)").
        let title: String
        /// "Audio Description", "SDH", "CC".
        let badge: String?
        /// The title with the badge, unless the name already has it (AVFoundation names an audio description
        /// "English AD" and SDH subtitles "English SDH").
        var menuTitle: String {
            guard let badge, !title.localizedCaseInsensitiveContains(badge) else {
                return title
            }
            return "\(title) (\(badge))"
        }
        /// Spoken by VoiceOver: the title and what the badge means.
        var accessibilityLabel: String {
            [title, badgeDescription].compactMap { $0 }.joined(separator: ", ")
        }
        fileprivate let badgeDescription: String?
    }

    /// Choices of the Subtitles menu.
    enum SubtitleChoice: Hashable {
        /// The system decides (accessibility settings, languages, forced subtitles).
        case automatic
        case off
        case track(Int)
    }

    private(set) var audioTracks: [Track] = []
    private(set) var subtitleTracks: [Track] = []
    private(set) var selectedAudioTrack: Int?
    private(set) var subtitleChoice: SubtitleChoice = .automatic
    /// Whether subtitles can be switched off (the group allows an empty selection).
    private(set) var canTurnSubtitlesOff = false

    /// Whether there is anything to choose: two audio tracks or more, or any subtitles.
    var hasChoices: Bool {
        audioTracks.count > 1 || !subtitleTracks.isEmpty
    }

    @ObservationIgnored private weak var item: AVPlayerItem?
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    /// The listed options, in the order of `audioTracks` / `subtitleTracks`.
    @ObservationIgnored private var audioOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var subtitleOptions: [AVMediaSelectionOption] = []
    /// Set once the user picks a subtitle option (or Off) for this item: the menu then shows the choice
    /// rather than "Automatic".
    @ObservationIgnored private var subtitlesChosenByUser = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var selectionObserver: NSObjectProtocol?

    /// Follows `item` (nil: nothing plays). Its groups load in the background.
    func attach(_ item: AVPlayerItem?) {
        guard item !== self.item else {
            return
        }
        loadTask?.cancel()
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        selectionObserver = nil
        self.item = item
        audioGroup = nil
        legibleGroup = nil
        audioOptions = []
        subtitleOptions = []
        subtitlesChosenByUser = false
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrack = nil
        subtitleChoice = .automatic
        canTurnSubtitlesOff = false

        guard let item else {
            return
        }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSelection()
            }
        }
        loadTask = Task { [weak self] in
            await self?.load(item)
        }
    }

    /// Loads the groups again (a live HLS stream can add renditions once its playlist is read).
    func reload() {
        guard let item else {
            return
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.load(item)
        }
    }

    func selectAudioTrack(_ id: Int) {
        guard let item, let audioGroup, audioOptions.indices.contains(id) else {
            return
        }
        item.select(audioOptions[id], in: audioGroup)
        refreshSelection()
    }

    func selectSubtitles(_ choice: SubtitleChoice) {
        guard let item, let legibleGroup else {
            return
        }
        switch choice {
        case .automatic:
            subtitlesChosenByUser = false
            item.selectMediaOptionAutomatically(in: legibleGroup)
        case .off:
            guard legibleGroup.allowsEmptySelection else {
                return
            }
            subtitlesChosenByUser = true
            item.select(nil, in: legibleGroup)
        case .track(let id):
            guard subtitleOptions.indices.contains(id) else {
                return
            }
            subtitlesChosenByUser = true
            item.select(subtitleOptions[id], in: legibleGroup)
        }
        refreshSelection()
    }

    private func load(_ item: AVPlayerItem) async {
        let asset = item.asset
        let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled, item === self.item else {
            return
        }
        audioGroup = audible
        legibleGroup = legible

        audioOptions = audible.map { AVMediaSelectionGroup.playableMediaSelectionOptions(from: $0.options) } ?? []
        audioTracks = Self.tracks(for: audioOptions, kind: .audio)

        // Forced subtitles (signs, foreign dialog) are shown automatically with their audio: they are not a choice.
        subtitleOptions = legible.map { group in
            AVMediaSelectionGroup.mediaSelectionOptions(
                from: AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options),
                withoutMediaCharacteristics: [.containsOnlyForcedSubtitles]
            )
        } ?? []
        subtitleTracks = Self.tracks(for: subtitleOptions, kind: .subtitles)
        canTurnSubtitlesOff = legible?.allowsEmptySelection ?? false
        refreshSelection()
    }

    private func refreshSelection() {
        guard let item else {
            return
        }
        let selection = item.currentMediaSelection
        if let audioGroup, let option = selection.selectedMediaOption(in: audioGroup) {
            selectedAudioTrack = audioOptions.firstIndex(of: option)
        } else {
            selectedAudioTrack = nil
        }
        guard !subtitlesChosenByUser else {
            if let legibleGroup, let option = selection.selectedMediaOption(in: legibleGroup), let index = subtitleOptions.firstIndex(of: option) {
                subtitleChoice = .track(index)
            } else {
                subtitleChoice = .off
            }
            return
        }
        subtitleChoice = .automatic
    }

    /// What the system shows while Subtitles is on Automatic ("Off", "English"), for the menu.
    var automaticSubtitleDescription: String {
        guard let item, let legibleGroup, let option = item.currentMediaSelection.selectedMediaOption(in: legibleGroup) else {
            return String(localized: "Off")
        }
        if let index = subtitleOptions.firstIndex(of: option) {
            return subtitleTracks[index].title
        }
        // Forced subtitles only.
        return String(localized: "Off")
    }

    private enum Kind {
        case audio
        case subtitles
    }

    private static func tracks(for options: [AVMediaSelectionOption], kind: Kind) -> [Track] {
        var seen: [String: Int] = [:]
        return options.enumerated().map { index, option in
            var title = option.displayName.isEmpty ? String(localized: "Track \(index + 1)") : option.displayName
            // Two tracks of the same name ("English", "English") get a number.
            let count = (seen[title] ?? 0) + 1
            seen[title] = count
            if count > 1 {
                title += " \(count)"
            }
            let badge: (short: String, spoken: String)?
            switch kind {
            case .audio:
                badge = option.hasMediaCharacteristic(.describesVideoForAccessibility)
                    ? (String(localized: "AD"), String(localized: "Audio Description"))
                    : nil
            case .subtitles:
                if option.mediaType == .closedCaption {
                    badge = (String(localized: "CC"), String(localized: "Closed Captions"))
                } else if option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                    && option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) {
                    badge = (String(localized: "SDH"), String(localized: "Subtitles for the Deaf and Hard of Hearing"))
                } else {
                    badge = nil
                }
            }
            return Track(id: index, title: title, badge: badge?.short, badgeDescription: badge?.spoken)
        }
    }
}

/// The player's Audio & Subtitles menu: audio tracks (with Audio Description marked) and subtitles (Automatic,
/// Off, then each option, with SDH and closed captions marked). Shows nothing while the item has no choice.
struct MediaSelectionMenu<Label: View>: View {
    let controller: MediaSelectionController
    @ViewBuilder var label: () -> Label

    var body: some View {
        if controller.hasChoices {
            Menu {
                MediaSelectionMenuContent(controller: controller)
            } label: {
                label()
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Audio and Subtitles")
            .accessibilityValue(accessibilityValue)
            .accessibilityInputLabels([Text("Subtitles"), Text("Audio"), Text("Captions")])
            .help("Audio and Subtitles")
        }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let audio = controller.selectedAudioTrack, controller.audioTracks.count > 1, controller.audioTracks.indices.contains(audio) {
            parts.append(String(localized: "Audio: \(controller.audioTracks[audio].accessibilityLabel)"))
        }
        if !controller.subtitleTracks.isEmpty {
            switch controller.subtitleChoice {
            case .automatic:
                parts.append(String(localized: "Subtitles: Automatic, \(controller.automaticSubtitleDescription)"))
            case .off:
                parts.append(String(localized: "Subtitles: Off"))
            case .track(let id) where controller.subtitleTracks.indices.contains(id):
                parts.append(String(localized: "Subtitles: \(controller.subtitleTracks[id].accessibilityLabel)"))
            case .track:
                break
            }
        }
        return parts.joined(separator: ". ")
    }
}

/// The sections of the menu, also used inside other menus.
struct MediaSelectionMenuContent: View {
    let controller: MediaSelectionController

    var body: some View {
        if controller.audioTracks.count > 1 {
            Section("Audio") {
                audioPicker
            }
        }

        if !controller.subtitleTracks.isEmpty {
            Section("Subtitles") {
                subtitlePicker
            }
        }
    }

    // Toggles rather than inline pickers: a menu shows them with a checkmark under the section titles (an inline
    // picker in a menu drops the title), and VoiceOver reads them as selected or not.

    @ViewBuilder
    private var audioPicker: some View {
        ForEach(controller.audioTracks) { track in
            choice(isSelected: controller.selectedAudioTrack == track.id) {
                controller.selectAudioTrack(track.id)
            } label: {
                trackLabel(track)
            }
        }
    }

    @ViewBuilder
    private var subtitlePicker: some View {
        choice(isSelected: controller.subtitleChoice == .automatic) {
            controller.selectSubtitles(.automatic)
        } label: {
            Text("Automatic (\(controller.automaticSubtitleDescription))")
        }
        if controller.canTurnSubtitlesOff {
            choice(isSelected: controller.subtitleChoice == .off) {
                controller.selectSubtitles(.off)
            } label: {
                Text("Off")
            }
        }
        ForEach(controller.subtitleTracks) { track in
            choice(isSelected: controller.subtitleChoice == .track(track.id)) {
                controller.selectSubtitles(.track(track.id))
            } label: {
                trackLabel(track)
            }
        }
    }

    private func choice<Label: View>(isSelected: Bool, select: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Toggle(isOn: Binding(get: { isSelected }, set: { _ in select() })) {
            label()
        }
    }

    private func trackLabel(_ track: MediaSelectionController.Track) -> some View {
        Text(track.menuTitle)
            .accessibilityLabel(track.accessibilityLabel)
    }
}

#Preview("Audio and subtitles") {
    // Without an item there is nothing to choose: the menu shows nothing.
    MediaSelectionMenu(controller: MediaSelectionController()) {
        Image(systemName: "captions.bubble")
    }
    .padding()
}
