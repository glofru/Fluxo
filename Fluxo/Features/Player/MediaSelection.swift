//
//  MediaSelection.swift
//  Fluxo
//
//  Audio tracks and subtitles / closed captions of the item that plays (AVMediaSelection), external subtitle
//  files, the tracks of a Chromecast, and the player's menu to choose them.
//
//  AVPlayer keeps `appliesMediaSelectionCriteriaAutomatically` on, so by default it follows the system settings:
//  Settings > Accessibility > Subtitles & Captioning ("Closed Captions + SDH" picks the SDH subtitles or the
//  closed captions when there are any) and Audio Descriptions (picks the described audio track), and the user's
//  languages. The captions are drawn by the AVPlayerLayer itself, in the caption style chosen there (font, size,
//  colors, background), also in Picture in Picture. A choice in the menu overrides the automatic selection and is
//  remembered (`TrackPreferences`): the next channel, movie or episode with a track in that language starts
//  with it. "Automatic" in Subtitles gives the choice back to the system. "Off" still shows forced subtitles
//  (signs, foreign dialog) in the language of the audio, as the system does.
//
//  What is listed is what the stream has: the renditions of an HLS playlist (EXT-X-MEDIA audio, subtitles and
//  closed captions), the tracks of an MP4 / MOV file, the CEA-608 captions carried in the video of a live
//  MPEG-TS channel, and, for channels and files the remux engine plays (MPEG-TS, Matroska), their extra audio
//  tracks and text subtitles, which the engine turns into HLS renditions. Movies, episodes and recordings can
//  also show a SubRip or WebVTT file the user picks (`ExternalSubtitles`), drawn over the video in the
//  system caption style; it is remembered for that item.
//
//  While a Chromecast plays the item, the menu lists the receiver's tracks instead (the HLS renditions it reads
//  itself) and changes them on the receiver.
//

import AVFoundation
import Observation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Player")

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
            return String(localized: "\(title) (\(badge))", comment: "Audio or subtitle track in the player menu: the track name, then a short badge such as AD, CC or SDH.")
        }
        /// Spoken by VoiceOver: the title and what the badge means.
        var accessibilityLabel: String {
            TextParts.spoken([title, badgeDescription])
        }
        fileprivate let badgeDescription: String?
    }

    /// Choices of the Subtitles menu.
    enum SubtitleChoice: Hashable {
        /// The system decides (accessibility settings, languages, forced subtitles).
        case automatic
        case off
        case track(Int)
        /// The subtitle file the user loaded.
        case external
    }

    private(set) var audioTracks: [Track] = []
    private(set) var subtitleTracks: [Track] = []
    private(set) var selectedAudioTrack: Int?
    private(set) var subtitleChoice: SubtitleChoice = .automatic
    /// Whether subtitles can be switched off (the group allows an empty selection).
    private(set) var canTurnSubtitlesOff = false

    /// The item is a movie, an episode or a recording: a subtitle file can be loaded for it.
    private(set) var allowsExternalSubtitles = false
    /// The subtitle file loaded for the item, and its playback while it is the chosen subtitles.
    private(set) var externalSubtitles: ExternalSubtitleTrack?
    private(set) var externalPlayback: ExternalSubtitlePlayback?
    /// The file importer of the player screen is open (set by the menu, which may close meanwhile).
    var isImportingSubtitleFile = false
    /// Why the last subtitle file could not be loaded; dismissed by the user.
    var externalSubtitleError: String?
    /// The size of the picture, for drawing external subtitles on it (not on the letterbox bars).
    private(set) var presentationSize: CGSize = .zero

    /// The menu lists a Chromecast's tracks (see "Chromecast" below).
    private(set) var isShowingCastTracks = false

    /// Whether there is anything to choose: two audio tracks or more, or any subtitles, or a file can be loaded.
    var hasChoices: Bool {
        audioTracks.count > 1 || !subtitleTracks.isEmpty || externalSubtitles != nil || (allowsExternalSubtitles && !isShowingCastTracks)
    }

    /// "Automatic" is offered for local playback (a Chromecast has no automatic subtitle selection).
    var offersAutomaticSubtitles: Bool {
        !isShowingCastTracks
    }

    /// The player, for its media selection criteria and the timing of external subtitles.
    @ObservationIgnored weak var player: AVPlayer?

    @ObservationIgnored private weak var item: AVPlayerItem?
    /// Identifies what plays for the external subtitle file kept for it (its stream URL).
    @ObservationIgnored private var contentKey: String?
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    /// The listed options, in the order of `audioTracks` / `subtitleTracks`.
    @ObservationIgnored private var audioOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var subtitleOptions: [AVMediaSelectionOption] = []
    /// Forced-only options, shown with the audio of their language when subtitles are Off.
    @ObservationIgnored private var forcedOptions: [AVMediaSelectionOption] = []
    /// Set once the user picks a subtitle option (or Off) for this item, or a remembered choice was applied:
    /// the menu then shows the choice rather than "Automatic".
    @ObservationIgnored private var subtitlesChosenByUser = false
    /// Remembered choices are applied once per item (the groups load again when it is ready).
    @ObservationIgnored private var appliedPreferences = false
    /// When the audio track last changed (by the user or a remembered choice), for `playbackFailed(_:)`.
    @ObservationIgnored private var lastAudioSwitch: Date?
    /// The items (content keys) whose remembered audio language failed to decode: they start with their
    /// default track for the rest of the session. The remembered language itself stays.
    @ObservationIgnored private var audioPreferenceFailed: Set<String> = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var externalTask: Task<Void, Never>?
    @ObservationIgnored private var selectionObserver: NSObjectProtocol?
    @ObservationIgnored private var presentationObserver: NSKeyValueObservation?

    // Chromecast
    @ObservationIgnored private var castTracks: [CastTrack] = []
    @ObservationIgnored private var castActiveTrackIDs: [Int] = []
    @ObservationIgnored private var castSelect: (([Int]) -> Void)?
    /// The receiver content the remembered choices were applied to.
    @ObservationIgnored private var castPreferencesAppliedTo: URL?
    /// The subtitle file was shown when casting began: it is shown again when casting ends.
    @ObservationIgnored private var externalShownBeforeCast = false

    /// Follows `item` (nil: nothing plays). Its groups load in the background.
    /// - Parameters:
    ///   - contentKey: identifies what plays (its stream URL), for the subtitle file kept for it.
    ///   - allowsExternalSubtitles: a movie, an episode or a recording, for which a subtitle file can be loaded.
    func attach(_ item: AVPlayerItem?, contentKey: String? = nil, allowsExternalSubtitles: Bool = false) {
        guard item !== self.item else {
            return
        }
        loadTask?.cancel()
        externalTask?.cancel()
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        selectionObserver = nil
        presentationObserver?.invalidate()
        presentationObserver = nil
        self.item = item
        audioGroup = nil
        legibleGroup = nil
        audioOptions = []
        subtitleOptions = []
        forcedOptions = []
        subtitlesChosenByUser = false
        appliedPreferences = false
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrack = nil
        subtitleChoice = .automatic
        canTurnSubtitlesOff = false
        presentationSize = .zero
        stopExternalPlayback()
        externalSubtitles = nil
        externalSubtitleError = nil

        guard let item else {
            self.contentKey = nil
            self.allowsExternalSubtitles = false
            return
        }
        self.contentKey = contentKey
        self.allowsExternalSubtitles = allowsExternalSubtitles
        applyAudioCriteria()

        selectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSelection()
            }
        }
        presentationObserver = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor in
                if self?.presentationSize != size {
                    self?.presentationSize = size
                }
            }
        }
        loadTask = Task { [weak self] in
            await self?.load(item)
        }
        if allowsExternalSubtitles, let contentKey {
            externalTask = Task { [weak self] in
                guard let track = await ExternalSubtitleStore.load(for: contentKey), !Task.isCancelled else {
                    return
                }
                self?.restoreExternalSubtitles(track, for: item)
            }
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
        if isShowingCastTracks {
            selectCastAudio(id)
            return
        }
        guard let item, let audioGroup, audioOptions.indices.contains(id) else {
            return
        }
        let option = audioOptions[id]
        item.select(option, in: audioGroup)
        lastAudioSwitch = Date()
        TrackPreferences.rememberAudio(option)
        if let contentKey {
            // The user's own choice for this content again.
            audioPreferenceFailed.remove(contentKey)
        }
        applyAudioCriteria()
        if subtitleChoice == .off || subtitleChoice == .external {
            // Forced subtitles follow the language of the audio.
            selectForcedSubtitles(for: option)
        }
        refreshSelection()
    }

    func selectSubtitles(_ choice: SubtitleChoice) {
        if isShowingCastTracks {
            selectCastSubtitles(choice)
            return
        }
        guard let item else {
            return
        }
        if choice != .external, externalPlayback != nil {
            // Other subtitles replace the file: it stays in the menu, but is no longer loaded the next time.
            stopExternalPlayback()
            if let contentKey {
                ExternalSubtitleStore.remove(for: contentKey)
            }
        }
        switch choice {
        case .automatic:
            subtitlesChosenByUser = false
            TrackPreferences.rememberAutomaticSubtitles()
            if let legibleGroup {
                item.selectMediaOptionAutomatically(in: legibleGroup)
            }
        case .off:
            // Only the stream's own subtitles are a choice to remember: turning a loaded file off concerns
            // this item alone.
            if legibleGroup != nil {
                guard turnSubtitlesOff() else {
                    refreshSelection()
                    return
                }
                TrackPreferences.rememberSubtitlesOff()
            }
            subtitlesChosenByUser = true
        case .track(let id):
            guard let legibleGroup, subtitleOptions.indices.contains(id) else {
                return
            }
            subtitlesChosenByUser = true
            item.select(subtitleOptions[id], in: legibleGroup)
            TrackPreferences.rememberSubtitles(subtitleOptions[id])
        case .external:
            guard let externalSubtitles else {
                return
            }
            if externalPlayback == nil, let contentKey {
                ExternalSubtitleStore.keep(externalSubtitles, for: contentKey)
            }
            showExternal(externalSubtitles)
        }
        refreshSelection()
    }

    // MARK: - Loading

    private func load(_ item: AVPlayerItem) async {
        let asset = item.asset
        let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled, item === self.item else {
            return
        }
        audioGroup = audible
        legibleGroup = legible

        // A downloaded HLS stream (a .movpkg) plays offline only the renditions that were downloaded with it.
        let cache = (asset as? AVURLAsset)?.assetCache
        func available(_ options: [AVMediaSelectionOption], in group: AVMediaSelectionGroup) -> [AVMediaSelectionOption] {
            guard let cache else {
                return options
            }
            let offline = cache.mediaSelectionOptions(in: group)
            return offline.isEmpty ? options : options.filter(offline.contains)
        }

        audioOptions = audible.map { available(AVMediaSelectionGroup.playableMediaSelectionOptions(from: $0.options), in: $0) } ?? []
        audioTracks = Self.tracks(for: audioOptions, kind: .audio)

        // Forced subtitles (signs, foreign dialog) are shown automatically with their audio: they are not a choice.
        let playableSubtitles = legible.map { available(AVMediaSelectionGroup.playableMediaSelectionOptions(from: $0.options), in: $0) } ?? []
        subtitleOptions = AVMediaSelectionGroup.mediaSelectionOptions(from: playableSubtitles, withoutMediaCharacteristics: [.containsOnlyForcedSubtitles])
        forcedOptions = AVMediaSelectionGroup.mediaSelectionOptions(from: playableSubtitles, withMediaCharacteristics: [.containsOnlyForcedSubtitles])
        subtitleTracks = Self.tracks(for: subtitleOptions, kind: .subtitles)
        canTurnSubtitlesOff = legible?.allowsEmptySelection ?? false
        applyPreferencesOnce()
        refreshSelection()
    }

    /// The remembered languages, for the first load of the item (and the ones that find new renditions).
    private func applyPreferencesOnce() {
        guard let item, !appliedPreferences, !audioOptions.isEmpty || !subtitleOptions.isEmpty else {
            return
        }
        appliedPreferences = true
        if !skipsAudioPreference, let audioGroup, let option = TrackPreferences.preferredAudio(in: audioOptions),
           item.currentMediaSelection.selectedMediaOption(in: audioGroup) != option {
            item.select(option, in: audioGroup)
            lastAudioSwitch = Date()
        }
        guard externalSubtitles == nil, legibleGroup != nil else {
            return
        }
        switch TrackPreferences.subtitleMode {
        case .automatic:
            break
        case .off:
            if turnSubtitlesOff() {
                subtitlesChosenByUser = true
            }
        case .on:
            if let legibleGroup, let option = TrackPreferences.preferredSubtitles(in: subtitleOptions) {
                item.select(option, in: legibleGroup)
                subtitlesChosenByUser = true
            }
        }
    }

    /// The item failed with `error`. When it is a decoding or format error right after the audio track
    /// changed, the track is the likely cause (a codec this device does not decode): the item the player
    /// recovers with starts with its default track, and so does this content for the rest of the session. The
    /// remembered language stays for other content (a network failure or a reclaimed socket never changes it).
    /// Returns whether the audio track was the likely cause.
    @discardableResult
    func playbackFailed(_ error: Error?) -> Bool {
        guard let lastAudioSwitch, Date().timeIntervalSince(lastAudioSwitch) < 15,
              let error, Self.isDecodingFailure(error as NSError) else {
            return false
        }
        self.lastAudioSwitch = nil
        logger.error("Playback failed to decode after an audio track change: this item starts with its default audio")
        if let contentKey {
            audioPreferenceFailed.insert(contentKey)
        }
        applyAudioCriteria()
        return true
    }

    /// The remembered audio language failed for what plays.
    private var skipsAudioPreference: Bool {
        contentKey.map(audioPreferenceFailed.contains) ?? false
    }

    /// An error of the media itself (format, codec), in `error` or the errors under it; not a network failure.
    nonisolated static func isDecodingFailure(_ error: NSError, depth: Int = 0) -> Bool {
        if error.domain == AVFoundationErrorDomain {
            let codes: [AVError.Code] = [.decodeFailed, .decoderNotFound, .fileFormatNotRecognized, .fileFailedToParse, .failedToParse, .formatUnsupported]
            if codes.contains(where: { $0.rawValue == error.code }) {
                return true
            }
        }
        // kAudioFormatUnsupportedFormatError, 'fmt?'.
        if error.domain == NSOSStatusErrorDomain, error.code == 0x666D_743F {
            return true
        }
        guard depth < 4 else {
            return false
        }
        var underlying = error.underlyingErrors as [NSError]
        if underlying.isEmpty, let single = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            underlying = [single]
        }
        return underlying.contains { isDecodingFailure($0, depth: depth + 1) }
    }

    /// The remembered audio language as AVPlayer's own criteria too, so a new item starts with it rather than
    /// switching after the first seconds.
    private func applyAudioCriteria() {
        guard let player else {
            return
        }
        guard !skipsAudioPreference, let language = TrackPreferences.audioLanguage else {
            player.setMediaSelectionCriteria(nil, forMediaCharacteristic: .audible)
            return
        }
        let characteristics: [AVMediaCharacteristic]? = TrackPreferences.prefersAudioDescription ? [.describesVideoForAccessibility] : nil
        player.setMediaSelectionCriteria(
            AVPlayerMediaSelectionCriteria(preferredLanguages: [language], preferredMediaCharacteristics: characteristics),
            forMediaCharacteristic: .audible
        )
    }

    /// Selects no subtitles, or the forced ones of the audio's language. Returns false when the group requires a
    /// selection and has no forced option.
    @discardableResult
    private func turnSubtitlesOff() -> Bool {
        guard let item, let legibleGroup else {
            return false
        }
        let audio = audioGroup.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
        if let forced = forcedOption(for: audio) {
            item.select(forced, in: legibleGroup)
            return true
        }
        guard legibleGroup.allowsEmptySelection else {
            return false
        }
        item.select(nil, in: legibleGroup)
        return true
    }

    private func selectForcedSubtitles(for audio: AVMediaSelectionOption) {
        guard let item, let legibleGroup else {
            return
        }
        if let forced = forcedOption(for: audio) {
            item.select(forced, in: legibleGroup)
        } else if legibleGroup.allowsEmptySelection {
            item.select(nil, in: legibleGroup)
        }
    }

    private func forcedOption(for audio: AVMediaSelectionOption?) -> AVMediaSelectionOption? {
        guard !forcedOptions.isEmpty else {
            return nil
        }
        guard let language = audio.flatMap(TrackPreferences.language(of:)) else {
            return forcedOptions.count == 1 ? forcedOptions.first : nil
        }
        return forcedOptions.first { TrackPreferences.language(of: $0) == language }
    }

    private func refreshSelection() {
        if isShowingCastTracks {
            refreshCastSelection()
            return
        }
        guard let item else {
            return
        }
        let selection = item.currentMediaSelection
        if let audioGroup, let option = selection.selectedMediaOption(in: audioGroup) {
            selectedAudioTrack = audioOptions.firstIndex(of: option)
        } else {
            selectedAudioTrack = nil
        }
        if externalPlayback != nil {
            subtitleChoice = .external
            return
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
        guard !isShowingCastTracks, let item, let legibleGroup, let option = item.currentMediaSelection.selectedMediaOption(in: legibleGroup) else {
            return String(localized: "Off", comment: "Subtitles menu: no subtitles are shown.")
        }
        if let index = subtitleOptions.firstIndex(of: option), subtitleTracks.indices.contains(index) {
            return subtitleTracks[index].title
        }
        // Forced subtitles only.
        return String(localized: "Off", comment: "Subtitles menu: no subtitles are shown.")
    }

    // MARK: - External subtitle files

    /// Loads a subtitle file the user picked (SubRip or WebVTT) and shows it; it is kept for this item.
    func loadExternalSubtitles(from url: URL) {
        guard allowsExternalSubtitles, let item else {
            return
        }
        externalSubtitleError = nil
        let key = contentKey
        externalTask?.cancel()
        externalTask = Task { [weak self] in
            do {
                let track = try await ExternalSubtitleStore.importFile(at: url, for: key)
                guard let self, !Task.isCancelled, item === self.item else {
                    return
                }
                logger.info("Loaded a subtitle file: \(track.file.cues.count) cues")
                self.externalSubtitles = track
                self.showExternal(track)
                self.refreshSelection()
            } catch {
                guard let self, !Task.isCancelled else {
                    return
                }
                logger.error("Subtitle file not loaded: \(error.localizedDescription, privacy: .public)")
                self.externalSubtitleError = error.localizedDescription
            }
        }
    }

    /// Delay of the external subtitles (positive: later), in half-second steps from the menu.
    var externalSubtitleOffset: TimeInterval {
        externalPlayback?.offset ?? 0
    }

    func adjustExternalSubtitleOffset(by delta: TimeInterval) {
        externalPlayback?.offset += delta
    }

    func resetExternalSubtitleOffset() {
        externalPlayback?.offset = 0
    }

    /// Forgets the subtitle file of this item (also from the menu).
    func removeExternalSubtitles() {
        stopExternalPlayback()
        externalSubtitles = nil
        if let contentKey {
            ExternalSubtitleStore.remove(for: contentKey)
        }
        refreshSelection()
    }

    private func restoreExternalSubtitles(_ track: ExternalSubtitleTrack, for item: AVPlayerItem) {
        guard item === self.item else {
            return
        }
        externalSubtitles = track
        guard !isShowingCastTracks else {
            // Shown on this device once casting ends.
            externalShownBeforeCast = true
            return
        }
        showExternal(track)
        refreshSelection()
    }

    private func showExternal(_ track: ExternalSubtitleTrack) {
        guard let player else {
            return
        }
        stopExternalPlayback()
        // The file replaces the stream's own subtitles (forced ones stay, in the audio's language).
        if let item, legibleGroup != nil {
            let audio = audioGroup.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
            if let audio {
                selectForcedSubtitles(for: audio)
            } else {
                turnSubtitlesOff()
            }
        }
        subtitlesChosenByUser = true
        externalPlayback = ExternalSubtitlePlayback(file: track.file, player: player)
    }

    private func stopExternalPlayback() {
        externalPlayback?.stop()
        externalPlayback = nil
    }

    // MARK: - Chromecast

    /// Lists the receiver's tracks while a Chromecast plays the item; `select` changes its active tracks. The
    /// remembered languages are applied once per content.
    func showCastTracks(_ status: CastMediaStatus?, select: @escaping ([Int]) -> Void) {
        let wasShowing = isShowingCastTracks
        isShowingCastTracks = true
        castSelect = select
        castTracks = status?.tracks ?? []
        castActiveTrackIDs = status?.activeTrackIDs ?? []
        if !wasShowing {
            externalShownBeforeCast = externalPlayback != nil
            stopExternalPlayback()
        }
        audioTracks = castTracks.filter { $0.kind == .audio }.enumerated().map { index, track in
            Self.castTrack(track, index: index, kind: .audio)
        }
        subtitleTracks = castTracks.filter { $0.kind == .text }.enumerated().map { index, track in
            Self.castTrack(track, index: index, kind: .subtitles)
        }
        canTurnSubtitlesOff = !subtitleTracks.isEmpty
        if let status, let content = status.contentURL, castPreferencesAppliedTo != content, !castTracks.isEmpty {
            castPreferencesAppliedTo = content
            applyCastPreferences()
        }
        refreshCastSelection()
    }

    /// Back to the local item's tracks (casting ended).
    func hideCastTracks() {
        guard isShowingCastTracks else {
            return
        }
        isShowingCastTracks = false
        castTracks = []
        castActiveTrackIDs = []
        castSelect = nil
        castPreferencesAppliedTo = nil
        audioTracks = Self.tracks(for: audioOptions, kind: .audio)
        subtitleTracks = Self.tracks(for: subtitleOptions, kind: .subtitles)
        canTurnSubtitlesOff = legibleGroup?.allowsEmptySelection ?? false
        // The file comes back only when it was the choice before casting, never over a track of the stream.
        if let externalSubtitles, externalShownBeforeCast {
            showExternal(externalSubtitles)
        }
        externalShownBeforeCast = false
        refreshSelection()
    }

    private var castAudio: [CastTrack] { castTracks.filter { $0.kind == .audio } }
    private var castText: [CastTrack] { castTracks.filter { $0.kind == .text } }

    private func selectCastAudio(_ index: Int) {
        guard castAudio.indices.contains(index) else {
            return
        }
        let track = castAudio[index]
        var active = castActiveTrackIDs.filter { id in !castAudio.contains { $0.id == id } }
        active.append(track.id)
        if let language = track.language.flatMap(TrackPreferences.baseLanguage) {
            TrackPreferences.audioLanguage = language
            TrackPreferences.prefersAudioDescription = false
        }
        setCastActive(active)
    }

    private func selectCastSubtitles(_ choice: SubtitleChoice) {
        var active = castActiveTrackIDs.filter { id in !castText.contains { $0.id == id } }
        switch choice {
        case .track(let index) where castText.indices.contains(index):
            let track = castText[index]
            active.append(track.id)
            if let language = track.language.flatMap(TrackPreferences.baseLanguage) {
                TrackPreferences.subtitleMode = .on
                TrackPreferences.subtitleLanguage = language
                TrackPreferences.prefersAccessibleSubtitles = track.isCaptions
            }
        case .off:
            TrackPreferences.rememberSubtitlesOff()
        default:
            return
        }
        setCastActive(active)
    }

    private func setCastActive(_ ids: [Int]) {
        castActiveTrackIDs = ids
        castSelect?(ids)
        refreshCastSelection()
    }

    private func applyCastPreferences() {
        var active = castActiveTrackIDs
        if let language = TrackPreferences.audioLanguage, castAudio.count > 1,
           let track = castAudio.first(where: { $0.language.flatMap(TrackPreferences.baseLanguage) == language }) {
            active.removeAll { id in castAudio.contains { $0.id == id } }
            active.append(track.id)
        }
        if TrackPreferences.subtitleMode == .on, let language = TrackPreferences.subtitleLanguage {
            let matches = castText.filter { $0.language.flatMap(TrackPreferences.baseLanguage) == language }
            if let track = matches.first(where: { $0.isCaptions == TrackPreferences.prefersAccessibleSubtitles }) ?? matches.first {
                active.removeAll { id in castText.contains { $0.id == id } }
                active.append(track.id)
            }
        } else if TrackPreferences.subtitleMode == .off {
            active.removeAll { id in castText.contains { $0.id == id } }
        }
        if Set(active) != Set(castActiveTrackIDs) {
            setCastActive(active)
        }
    }

    private func refreshCastSelection() {
        selectedAudioTrack = castAudio.firstIndex { castActiveTrackIDs.contains($0.id) }
        if let index = castText.firstIndex(where: { castActiveTrackIDs.contains($0.id) }) {
            subtitleChoice = .track(index)
        } else {
            subtitleChoice = .off
        }
    }

    private static func castTrack(_ track: CastTrack, index: Int, kind: Kind) -> Track {
        var title = track.name?.trimmingCharacters(in: .whitespaces) ?? ""
        if title.isEmpty || title == track.language {
            title = track.language.flatMap(TrackPreferences.baseLanguage).map(TrackPreferences.displayName(forLanguage:))
                ?? String(localized: "Track \(index + 1)", comment: "Name of an audio or subtitle track that has no name; the number is its position.")
        }
        let badge: (short: String, spoken: String)? = kind == .subtitles && track.isCaptions
            ? (String(localized: "CC", comment: "Short badge for closed captions. Keep it very short."), String(localized: "Closed Captions", comment: "Spoken meaning of the CC badge on a subtitle track."))
            : nil
        return Track(id: index, title: title, badge: badge?.short, badgeDescription: badge?.spoken)
    }

    // MARK: - Names

    private enum Kind {
        case audio
        case subtitles
    }

    /// The name of an option: AVFoundation's, or the language in the user's language when the stream only gives a
    /// language code or a number (the renditions of the remux engine without a title).
    private static func title(for option: AVMediaSelectionOption, index: Int) -> String {
        let name = option.displayName.trimmingCharacters(in: .whitespaces)
        let language = TrackPreferences.language(of: option)
        if name.isEmpty || name.allSatisfy(\.isNumber) {
            if let language {
                return TrackPreferences.displayName(forLanguage: language)
            }
            return String(localized: "Track \(index + 1)", comment: "Name of an audio or subtitle track that has no name; the number is its position.")
        }
        if let language, name.caseInsensitiveCompare(language) == .orderedSame || name.caseInsensitiveCompare(option.extendedLanguageTag ?? "") == .orderedSame {
            return TrackPreferences.displayName(forLanguage: language)
        }
        return name
    }

    private static func tracks(for options: [AVMediaSelectionOption], kind: Kind) -> [Track] {
        var seen: [String: Int] = [:]
        return options.enumerated().map { index, option in
            var title = title(for: option, index: index)
            // Two tracks of the same name ("English", "English") get a number.
            let count = (seen[title] ?? 0) + 1
            seen[title] = count
            if count > 1 {
                title = String(localized: "\(title) \(count)", comment: "A second audio or subtitle track with the same name gets a number, as in 'English 2'.")
            }
            let badge: (short: String, spoken: String)?
            switch kind {
            case .audio:
                badge = option.hasMediaCharacteristic(.describesVideoForAccessibility)
                    ? (String(localized: "AD", comment: "Short badge for an audio description track. Keep it very short."), String(localized: "Audio Description", comment: "Spoken meaning of the AD badge on an audio track."))
                    : nil
            case .subtitles:
                if option.mediaType == .closedCaption {
                    badge = (String(localized: "CC", comment: "Short badge for closed captions. Keep it very short."), String(localized: "Closed Captions", comment: "Spoken meaning of the CC badge on a subtitle track."))
                } else if option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                    && option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) {
                    badge = (String(localized: "SDH", comment: "Short badge for subtitles for the deaf and hard of hearing. Keep it very short."), String(localized: "Subtitles for the Deaf and Hard of Hearing", comment: "Spoken meaning of the SDH badge on a subtitle track."))
                } else {
                    badge = nil
                }
            }
            return Track(id: index, title: title, badge: badge?.short, badgeDescription: badge?.spoken)
        }
    }
}

/// The player's Audio & Subtitles menu: audio tracks (with Audio Description marked) and subtitles (Automatic,
/// Off, then each option, with SDH and closed captions marked, and a loaded subtitle file). Shows nothing while
/// the item has no choice.
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
            parts.append(String(localized: "Audio: \(controller.audioTracks[audio].accessibilityLabel)", comment: "VoiceOver value of the Audio and Subtitles button; the placeholder is the audio track name."))
        }
        if !controller.subtitleTracks.isEmpty || controller.externalSubtitles != nil {
            switch controller.subtitleChoice {
            case .automatic:
                parts.append(String(localized: "Subtitles: Automatic, \(controller.automaticSubtitleDescription)", comment: "VoiceOver value of the Audio and Subtitles button; the placeholder is what the system shows, such as Off or English."))
            case .off:
                parts.append(String(localized: "Subtitles: Off", comment: "VoiceOver value of the Audio and Subtitles button."))
            case .track(let id) where controller.subtitleTracks.indices.contains(id):
                parts.append(String(localized: "Subtitles: \(controller.subtitleTracks[id].accessibilityLabel)", comment: "VoiceOver value of the Audio and Subtitles button; the placeholder is the subtitle track name."))
            case .external:
                if let title = controller.externalSubtitles?.title {
                    parts.append(String(localized: "Subtitles: \(title)", comment: "VoiceOver value of the Audio and Subtitles button; the placeholder is the subtitle track name."))
                }
            case .track:
                break
            }
        }
        return TextParts.sentences(parts)
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

        if !controller.subtitleTracks.isEmpty || controller.externalSubtitles != nil {
            Section("Subtitles") {
                subtitlePicker
            }
        }

        if controller.subtitleChoice == .external, controller.externalPlayback != nil {
            Section("Subtitle Timing") {
                timingControls
            }
        }

        if controller.allowsExternalSubtitles && !controller.isShowingCastTracks {
            Section {
                Button("Load Subtitle File…", systemImage: "doc.badge.plus") {
                    controller.isImportingSubtitleFile = true
                }
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
        if controller.offersAutomaticSubtitles && !controller.subtitleTracks.isEmpty {
            choice(isSelected: controller.subtitleChoice == .automatic) {
                controller.selectSubtitles(.automatic)
            } label: {
                // What the system shows is only known while Automatic is the choice.
                if controller.subtitleChoice == .automatic {
                    Text("Automatic (\(controller.automaticSubtitleDescription))")
                } else {
                    Text("Automatic")
                }
            }
        }
        if controller.canTurnSubtitlesOff || controller.externalSubtitles != nil {
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
        if let external = controller.externalSubtitles, !controller.isShowingCastTracks {
            choice(isSelected: controller.subtitleChoice == .external) {
                controller.selectSubtitles(.external)
            } label: {
                Label(external.title, systemImage: "doc.text")
            }
            .accessibilityLabel(String(localized: "\(external.title), subtitle file", comment: "VoiceOver label of a loaded subtitle file in the player's Subtitles menu; the placeholder is its name."))
        }
    }

    @ViewBuilder
    private var timingControls: some View {
        Button("Show Earlier", systemImage: "minus.circle") {
            controller.adjustExternalSubtitleOffset(by: -0.5)
        }
        Button("Show Later", systemImage: "plus.circle") {
            controller.adjustExternalSubtitleOffset(by: 0.5)
        }
        if controller.externalSubtitleOffset != 0 {
            Button {
                controller.resetExternalSubtitleOffset()
            } label: {
                Text("Reset (\(Self.offsetText(controller.externalSubtitleOffset)))")
            }
        }
    }

    /// "+1.5 s", "−0.5 s".
    static func offsetText(_ offset: TimeInterval) -> String {
        Measurement(value: offset, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1)).sign(strategy: .always())))
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

/// The file importer for "Load Subtitle File…" and its error alert, attached to a view that stays on screen.
struct SubtitleFileImporter: ViewModifier {
    @Bindable var controller: MediaSelectionController

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $controller.isImportingSubtitleFile, allowedContentTypes: SubtitleFileTypes.all) { result in
                if case .success(let url) = result {
                    controller.loadExternalSubtitles(from: url)
                }
            }
            .alert(
                "Couldn't Load the Subtitles",
                isPresented: Binding(get: { controller.externalSubtitleError != nil }, set: { if !$0 { controller.externalSubtitleError = nil } }),
                presenting: controller.externalSubtitleError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }
}

extension View {
    func subtitleFileImporter(_ controller: MediaSelectionController) -> some View {
        modifier(SubtitleFileImporter(controller: controller))
    }
}

#Preview("Audio and subtitles") {
    // Without an item there is nothing to choose: the menu shows nothing.
    MediaSelectionMenu(controller: MediaSelectionController()) {
        Image(systemName: "captions.bubble")
    }
    .padding()
}
