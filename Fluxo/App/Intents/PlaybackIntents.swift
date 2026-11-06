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
/// On iOS and from macOS 27 it adopts the system `open` schema (see `AppSchemaAdoption.swift`).
struct PlayChannelIntent: OpenIntent, PredictableIntent {

    static let title: LocalizedStringResource = "Play Channel"
    static let description = IntentDescription("Plays a channel, movie or episode from your playlists.", categoryName: "Playback", searchKeywords: ["Watch", "TV", "Channel", "Movie", "Episode", "Stream"])

    @Parameter(title: "Channel", requestValueDialog: "Which channel?")
    var target: ChannelEntity

    @Dependency
    var services: AppServices

    init() {}

    init(channel: ChannelEntity) {
        target = channel
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$target)")
    }

    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: \.$target) { channel in
            DisplayRepresentation(title: "Watch \(channel)", subtitle: "\(channel.group)", image: .init(systemName: "play.tv"))
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        services.play(target.item)
        return .result()
    }
}

/// "Play … in Fluxo" with any words: a channel by name ("Sky Sport F1", "Rai Uno"), the channel airing a programme
/// with that title, or a channel number ("channel 5"). The system "play video" intent, so Siri can hand it the
/// words it heard even when they are not one of the channels it knows by name.
struct PlayByNameIntent: PlayVideoIntent {

    static let title: LocalizedStringResource = "Play by Name"
    static let description = IntentDescription("Finds a channel by name or number, or a programme on now by title, and plays it.", categoryName: "Playback", searchKeywords: ["Watch", "TV", "Channel", "Number"])
    static let supportedCategories: [VideoCategory] = [.tv, .movies]

    @Parameter(title: "Name", requestValueDialog: "What would you like to watch?")
    var term: String

    @Dependency
    var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$term)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !services.allImportIDs().isEmpty else {
            throw FluxoIntentError.noPlaylists
        }
        guard let resolution = await services.resolveChannel(term) else {
            throw FluxoIntentError.channelNotFound(term.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        services.play(resolution.item)
        switch resolution.reason {
        case .programme(let programme):
            return .result(dialog: "Playing \(programme.title) on \(resolution.item.displayName).")
        case .name, .number, .closest:
            return .result(dialog: "Playing \(resolution.item.displayName).")
        }
    }
}

/// "Continue watching in Fluxo": the movie or episode watched last that was not finished, from where it stopped
/// (else the channel watched last).
struct ContinueWatchingIntent: AppIntent {

    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Resumes the movie or episode you watched last, where you left it. Without one, plays the channel you watched last.", categoryName: "Playback", searchKeywords: ["Resume", "Continue", "Last", "Series", "Episode"])
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Dependency
    var services: AppServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let entry = services.continueWatchingItem() else {
            throw FluxoIntentError.nothingWatched
        }
        services.play(entry.item)
        guard let progress = entry.progress else {
            return .result(dialog: "Playing \(entry.item.displayName).")
        }
        return .result(dialog: "Resuming \(entry.item.displayName), \(WatchProgressFormat.remaining(progress)).")
    }
}

/// Stops playback and closes the player.
struct StopPlaybackIntent: AppIntent {

    static let title: LocalizedStringResource = "Stop Playback"
    static let description = IntentDescription("Stops what Fluxo is playing and closes the player. A recording in progress is saved.", categoryName: "Playback")
    static let supportedModes: IntentModes = .background

    @Dependency
    var services: AppServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard services.player.currentChannel != nil else {
            throw FluxoIntentError.nothingPlaying
        }
        services.player.stop()
        return .result(dialog: "Stopped playback.")
    }
}

struct PausePlaybackIntent: AppIntent {

    static let title: LocalizedStringResource = "Pause Playback"
    static let description = IntentDescription("Pauses what Fluxo is playing. Live channels keep buffering, so you can resume where you paused.", categoryName: "Playback")
    static let supportedModes: IntentModes = .background

    @Dependency
    var services: AppServices

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
    var services: AppServices

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

/// Start or stop a recording.
enum RecordingAction: String, AppEnum {
    case start
    case stop

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Recording Action"
    }

    static var caseDisplayRepresentations: [RecordingAction: DisplayRepresentation] {
        [
            .start: DisplayRepresentation(title: "Start Recording", image: .init(systemName: "record.circle"), synonyms: ["Begin Recording", "Record"]),
            .stop: DisplayRepresentation(title: "Stop Recording", image: .init(systemName: "stop.circle"), synonyms: ["End Recording", "Stop the Recording"]),
        ]
    }
}

/// Starts recording the live channel that plays (or plays a channel and records it), or stops the recording.
/// One intent for both, so the Siri phrases "Start recording in Fluxo" and "Stop recording in Fluxo" share one App
/// Shortcut (an app has at most ten).
struct RecordingIntent: AppIntent {

    static let title: LocalizedStringResource = "Start or Stop Recording"
    static let description = IntentDescription("Records the live channel that is playing, or plays a channel and records it, or stops the recording. Recordings are saved in Recordings.", categoryName: "Recording", searchKeywords: ["Record", "DVR", "Save"])
    /// In the background for the channel that plays; a new channel needs the app in front.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Action", default: .start)
    var action: RecordingAction

    @Parameter(title: "Channel", description: "Leave empty to record the channel that is playing.")
    var channel: ChannelEntity?

    @Dependency
    var services: AppServices

    init() {}

    init(action: RecordingAction, channel: ChannelEntity? = nil) {
        self.action = action
        self.channel = channel
    }

    static var parameterSummary: some ParameterSummary {
        Switch(\.$action) {
            Case(.stop) {
                Summary("\(\.$action)")
            }
            DefaultCase {
                Summary("\(\.$action) on \(\.$channel)")
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let (dialog, view) = switch action {
        case .start:
            try await start()
        case .stop:
            try stop()
        }
        return .result(dialog: dialog, view: view)
    }

    @MainActor
    private func start() async throws -> (IntentDialog, ConfirmationSnippetView) {
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
        return (dialog, ConfirmationSnippetView(systemImage: "record.circle.fill", title: title, subtitle: String(localized: "Say “Stop recording in Fluxo” to stop.", comment: "Siri and Shortcuts confirmation after a recording starts. Translate the phrase in quotes as the Stop Recording shortcut phrase of this language."), tint: Theme.recording))
    }

    @MainActor
    private func stop() throws -> (IntentDialog, ConfirmationSnippetView) {
        let player = services.player
        guard player.isRecording else {
            throw FluxoIntentError.notRecording
        }
        let name = player.currentChannel?.name
        player.stopRecording()
        let dialog: IntentDialog = name.map { "Stopped recording \($0). It's in Recordings." } ?? "Stopped recording. It's in Recordings."
        return (dialog, ConfirmationSnippetView(systemImage: "stop.circle.fill", title: name ?? String(localized: "Recording saved", comment: "Siri and Shortcuts confirmation title after a recording stops, when the channel has no name."), subtitle: String(localized: "Saved in Recordings", comment: "Siri and Shortcuts confirmation after a recording stops."), tint: Theme.recording))
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
