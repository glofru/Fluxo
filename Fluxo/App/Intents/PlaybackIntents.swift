//
//  PlaybackIntents.swift
//  Fluxo
//
//  Siri and Shortcuts actions for the player: play a channel (also what Spotlight runs for a channel), play by
//  name (the system "play video" intent), pause, resume, and start or stop recording.
//

import AppIntents
import Foundation

/// Plays a channel. As an `OpenIntent` on `ChannelEntity`, it is also what opening a channel from Spotlight does.
struct PlayChannelIntent: OpenIntent {

    static let title: LocalizedStringResource = "Play Channel"
    static let description = IntentDescription("Plays a channel, movie or episode from your playlists.", categoryName: "Playback")

    @Parameter(title: "Channel", requestValueDialog: "Which channel?")
    var target: ChannelEntity

    @Dependency
    private var services: AppServices

    init() {}

    init(channel: ChannelEntity) {
        target = channel
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$target)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        services.play(target.item)
        return .result()
    }
}

/// "Play … in Fluxo" with any words: a channel by name, or the channel airing a programme with that title.
struct PlayByNameIntent: PlayVideoIntent {

    static let title: LocalizedStringResource = "Play by Name"
    static let description = IntentDescription("Finds a channel by name, or a programme on now by title, and plays it.", categoryName: "Playback")
    static let supportedCategories: [VideoCategory] = [.tv, .movies]

    @Parameter(title: "Name", requestValueDialog: "What would you like to watch?")
    var term: String

    @Dependency
    private var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$term)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let importIDs = services.allImportIDs()
        guard !importIDs.isEmpty else {
            throw FluxoIntentError.noPlaylists
        }
        let channels = await LibraryLookup.searchChannels(term, importIDs: importIDs, limit: 5, in: services.container)
        // A channel whose name has every word of the term ("BBC News" → "BBC News HD") wins outright.
        let termTokens = Set(ChannelNameNormalizer.tokens(term))
        if !termTokens.isEmpty, let channel = channels.first(where: { termTokens.isSubset(of: ChannelNameNormalizer.tokens($0.displayName)) }) {
            services.play(channel)
            return .result(dialog: "Playing \(channel.displayName).")
        }
        // Then a programme on air with that title ("Play the Formula 1 race"), before a fuzzy channel match. Only
        // titles count: a description that mentions the term is no reason to switch to that channel.
        let termWords = SmartSearchRules.words(term)
        if !termWords.isEmpty, await services.waitForGuide(),
           let onAir = await services.epg.searchProgrammes(term, importIDs: importIDs, limit: 20).first(where: { result in
               let titleWords = SmartSearchRules.words(result.programme.title)
               return result.programme.isOnAir(at: .now) && termWords.allSatisfy { word in titleWords.contains { $0.hasPrefix(word) } }
           }) {
            services.play(onAir.channel)
            return .result(dialog: "Playing \(onAir.programme.title) on \(onAir.channel.displayName).")
        }
        guard let channel = channels.first else {
            throw FluxoIntentError.channelNotFound(term)
        }
        services.play(channel)
        return .result(dialog: "Playing \(channel.displayName).")
    }
}

struct PausePlaybackIntent: AppIntent {

    static let title: LocalizedStringResource = "Pause Playback"
    static let description = IntentDescription("Pauses what Fluxo is playing. Live channels keep buffering, so you can resume where you paused.", categoryName: "Playback")
    static let supportedModes: IntentModes = .background

    @Dependency
    private var services: AppServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let channel = services.player.currentChannel else {
            throw FluxoIntentError.nothingPlaying
        }
        services.player.pause()
        guard let name = channel.name else {
            return .result(dialog: "Paused playback.")
        }
        return .result(dialog: "Paused \(name).")
    }
}

struct ResumePlaybackIntent: AppIntent {

    static let title: LocalizedStringResource = "Resume Playback"
    static let description = IntentDescription("Resumes playback in Fluxo.", categoryName: "Playback")
    static let supportedModes: IntentModes = .background

    @Dependency
    private var services: AppServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let channel = services.player.currentChannel else {
            throw FluxoIntentError.nothingPlaying
        }
        services.player.play()
        guard let name = channel.name else {
            return .result(dialog: "Resuming playback.")
        }
        return .result(dialog: "Resuming \(name).")
    }
}

/// Records the live channel that plays, or plays a channel and records it.
struct StartRecordingIntent: AppIntent {

    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Records the live channel that is playing, or plays a channel and records it. Recordings are saved in Recordings.", categoryName: "Recording")
    /// In the background for the channel that plays; a new channel needs the app in front.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Channel", description: "Leave empty to record the channel that is playing.")
    var channel: ChannelEntity?

    @Dependency
    private var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Record \(\.$channel)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let player = services.player
        if let channel, player.currentItem?.bookmarkKey != channel.item.bookmarkKey {
            try await continueInForeground(alwaysConfirm: false)
            services.play(channel.item)
        }
        guard let playing = player.currentChannel else {
            throw FluxoIntentError.nothingPlaying
        }
        if !player.isRecording {
            // A channel that just started can record once the engine has its first segment.
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(20)
            while !player.canRecord, clock.now < deadline {
                if case .failed = player.playbackState {
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard player.canRecord else {
                throw FluxoIntentError.recordingUnavailable(Self.reason(for: playing))
            }
            player.startRecording()
            if let error = player.recordingError {
                throw FluxoIntentError.cannotRecord(error)
            }
        }
        let dialog: IntentDialog
        let title: String
        if let name = playing.name {
            dialog = "Recording \(name)."
            title = String(localized: "Recording \(name)", comment: "Siri and Shortcuts confirmation title; the placeholder is the channel name.")
        } else {
            dialog = "Recording this channel."
            title = String(localized: "Recording", comment: "Siri and Shortcuts confirmation title when the channel has no name.")
        }
        return .result(
            dialog: dialog,
            view: ConfirmationSnippetView(systemImage: "record.circle.fill", title: title, subtitle: String(localized: "Say “Stop recording in Fluxo” to stop.", comment: "Siri and Shortcuts confirmation after a recording starts. Translate the phrase in quotes as the Stop Recording shortcut phrase of this language."), tint: Theme.recording)
        )
    }

    /// Why a channel cannot be recorded (see `PlaybackRoute`).
    private static func reason(for channel: PlayableChannel) -> LocalizedStringResource {
        switch channel.url?.pathExtension.lowercased() ?? "" {
        case "m3u8", "m3u":
            return LocalizedStringResource("Fluxo can't record this channel: it plays straight from its HLS playlist.", comment: "Siri and Shortcuts error. HLS is a streaming format name.")
        case "", "ts":
            return LocalizedStringResource("Fluxo can't record this channel: the stream did not start.", comment: "Siri and Shortcuts error.")
        default:
            return LocalizedStringResource("Fluxo can't record this channel: only live channels can be recorded.", comment: "Siri and Shortcuts error: movies and series cannot be recorded.")
        }
    }
}

struct StopRecordingIntent: AppIntent {

    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the recording in progress and saves it in Recordings.", categoryName: "Recording")
    static let supportedModes: IntentModes = .background

    @Dependency
    private var services: AppServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = services.player
        guard player.isRecording else {
            throw FluxoIntentError.notRecording
        }
        let name = player.currentChannel?.name
        player.stopRecording()
        guard let name else {
            return .result(dialog: "Stopped recording. It's in Recordings.")
        }
        return .result(dialog: "Stopped recording \(name). It's in Recordings.")
    }
}
