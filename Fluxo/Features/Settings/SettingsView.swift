//
//  SettingsView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-06.
//

import SwiftData
import SwiftUI

/// Playback, audio and subtitles, TV guide, recordings, storage and about, under a header with the library at a glance. A tab on
/// iOS, the Settings window (⌘,) on macOS.
struct SettingsView: View {

    let player: AVPlayerViewModel

    @Environment(ChannelLibrary.self) private var library

    @AppStorage(PlayerPreferences.timeShiftMinutesKey) private var timeShiftMinutes = PlayerPreferences.defaultTimeShiftMinutes
    @AppStorage(PlayerPreferences.skipBackwardSecondsKey) private var skipBackwardSeconds = PlayerPreferences.defaultSkipBackwardSeconds
    @AppStorage(PlayerPreferences.skipForwardSecondsKey) private var skipForwardSeconds = PlayerPreferences.defaultSkipForwardSeconds
    @AppStorage(PlayerPreferences.autoPictureInPictureKey) private var autoPictureInPicture = PlayerPreferences.defaultAutoPictureInPicture
    @AppStorage(PlayerPreferences.pictureInPictureOnCloseKey) private var pictureInPictureOnClose = PlayerPreferences.defaultPictureInPictureOnClose

    @State private var viewModel = SettingsViewModel()
    @State private var confirmation: Confirmation?

    private enum Confirmation: Identifiable {
        case deleteRecordings
        case clearHistory

        var id: Self {
            self
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                #if DEBUG
                // Debug harness (`settings-section:<name>`): scrolls to a section for screenshots.
                .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugSettingsSection)) { notification in
                    if let section = notification.object as? String {
                        proxy.scrollTo(section, anchor: .top)
                    }
                }
                #endif
        }
    }

    private var form: some View {
        Form {
            Section {
                SettingsHeader(recordingCount: player.recordings.recordings.count)
            }
            playbackSection
            TrackSettingsSection()
            #if !os(macOS)
            pictureInPictureSection
            #endif
            GuideSettingsSection()
            IntelligenceSettingsSection()
            SiriSettingsSection()
            DownloadSettingsSection()
                .id("downloads")
            recordingsSection
            storageSection
            aboutSection
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 520)
        .frame(minHeight: 480)
        #endif
        .task {
            await viewModel.refresh()
        }
        .onChange(of: player.recordings.recordings) {
            Task {
                await viewModel.refresh()
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: confirmationBinding, titleVisibility: .visible, presenting: confirmation) { item in
            switch item {
            case .deleteRecordings:
                Button("Delete All Recordings", role: .destructive) {
                    player.recordings.deleteAll()
                }
            case .clearHistory:
                Button("Clear History", role: .destructive) {
                    library.clearHistory()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            switch item {
            case .deleteRecordings:
                Text("\(player.recordings.recordings.count) recordings (\(Self.bytes(player.recordings.totalBytes))) will be deleted. This cannot be undone.")
            case .clearHistory:
                Text("Continue Watching will be emptied. Favorites are kept.")
            }
        }
    }

    // MARK: - Sections

    private var playbackSection: some View {
        Section {
            Picker(selection: $timeShiftMinutes) {
                ForEach(PlayerPreferences.timeShiftChoices, id: \.self) { minutes in
                    Text(Self.minutes(minutes)).tag(minutes)
                }
            } label: {
                SettingsLabel("Time-shift buffer", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90", tint: Theme.timeShift)
            }

            Picker(selection: $skipBackwardSeconds) {
                ForEach(PlayerPreferences.skipChoices, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            } label: {
                SettingsLabel("Skip back", systemImage: "gobackward", tint: Theme.accent)
            }

            Picker(selection: $skipForwardSeconds) {
                ForEach(PlayerPreferences.skipChoices, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            } label: {
                SettingsLabel("Skip forward", systemImage: "goforward", tint: Theme.accent)
            }
        } header: {
            Text("Playback")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("How far back you can go in a live channel. Applies the next time a channel starts. The buffer uses at most \(Self.bytes(PlayerPreferences.timeShiftBytes)) and never more than a tenth of the free space.")
                // What the app does differently to save energy (`PlaybackEnergyProfile`, `EPGStore`).
                if PowerMonitor.shared.thermalState.isThrottling {
                    Text("Your device is warm: streams that offer several qualities play at a lower one, and the TV guide waits to refresh until it cools down.", comment: "Settings, Playback footer: shown while the device is hot (serious or critical thermal state).")
                } else if PowerMonitor.shared.isLowPowerModeEnabled {
                    Text("Low Power Mode is on: streams that offer several qualities play in 1080p at most, and the TV guide refreshes less often.", comment: "Settings, Playback footer: shown while Low Power Mode is on.")
                }
            }
        }
    }

    #if !os(macOS)
    private var pictureInPictureSection: some View {
        Section {
            Toggle(isOn: $autoPictureInPicture) {
                SettingsLabel("Start Picture in Picture automatically", systemImage: "pip.enter", tint: Theme.lilac)
            }
            Toggle(isOn: $pictureInPictureOnClose) {
                SettingsLabel("Picture in Picture when closing the player", systemImage: "pip.swap", tint: Theme.lilac)
            }
        } header: {
            Text("Picture in Picture")
        } footer: {
            Text("Start automatically: the video continues in a small window when you leave Fluxo. When closing the player: the chevron or a swipe down moves the video into a small window. The X always stops playback.")
        }
    }
    #endif

    private var recordingsSection: some View {
        let store = player.recordings
        return Section {
            LabeledContent {
                Text(TextParts.line([store.recordings.count.formatted(), Self.bytes(store.totalBytes)]))
                    .monospacedDigit()
            } label: {
                SettingsLabel("Recordings", systemImage: "record.circle", tint: Theme.recording)
            }

            LabeledContent {
                Text(recordingsLocation)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } label: {
                SettingsLabel("Location", systemImage: "folder", tint: Theme.cyan)
            }

            #if os(macOS)
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.directory])
            }
            #endif

            Button("Delete All Recordings…", systemImage: "trash", role: .destructive) {
                confirmation = .deleteRecordings
            }
            .disabled(store.recordings.isEmpty || player.isRecording)
        } header: {
            Text("Recordings")
        } footer: {
            if player.isRecording {
                Text("Stop the current recording to delete recordings.")
            }
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent {
                Text(Self.bytes(Int64(viewModel.streamFilesSize)))
                    .monospacedDigit()
            } label: {
                SettingsLabel("Temporary stream files", systemImage: "externaldrive", tint: .gray)
            }
            Button("Clear Stream Files", systemImage: "trash") {
                viewModel.deleteStreamFiles()
            }
            .disabled(!canClearStreamFiles || viewModel.streamFilesSize == 0)

            LabeledContent {
                Text(Self.bytes(Int64(viewModel.logoCacheSize)))
                    .monospacedDigit()
            } label: {
                SettingsLabel("Channel logos", systemImage: "photo.on.rectangle", tint: Theme.pink)
            }
            Button("Clear Logo Cache", systemImage: "photo.on.rectangle") {
                viewModel.clearLogoCache()
            }
            .disabled(viewModel.logoCacheSize == 0)

            Button("Clear Watch History…", systemImage: "clock.arrow.circlepath", role: .destructive) {
                confirmation = .clearHistory
            }
        } header: {
            Text("Storage")
        } footer: {
            if player.currentChannel != nil {
                Text("Stream files are in use while a channel plays. They are removed automatically when playback stops.")
            } else if !AppInstanceLock.isPrimaryInstance {
                Text("Another copy of Fluxo is running and may be using the stream files.")
            }
        }
    }

    /// Nothing plays here, and no other instance sharing this container can be using the files.
    private var canClearStreamFiles: Bool {
        player.currentChannel == nil && AppInstanceLock.isPrimaryInstance
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent {
                Text(SettingsViewModel.appVersion)
            } label: {
                SettingsLabel("Version", systemImage: "info.circle", tint: Theme.accent)
            }
            LabeledContent {
                Text(SettingsViewModel.ffmpegVersion)
            } label: {
                SettingsLabel("FFmpeg", systemImage: "film.stack", tint: .gray)
            }
        }
    }

    // MARK: - Helpers

    private var recordingsLocation: String {
        #if os(macOS)
        return (player.recordings.directory.path as NSString).abbreviatingWithTildeInPath
        #else
        // One string per device, because several languages decline the device name ("Na moim iPhonie",
        // "iPhone'umda"). The folder is passed in: its name on disk is the same in every language.
        let folder = RecordingStore.folderName
        if UIDevice.current.userInterfaceIdiom == .pad {
            return String(localized: "Files › On My iPad › Fluxo › \(folder)", comment: "Where recordings are on an iPad, as a path in the Files app. Use the names the Files app shows in this language ('Files', 'On My iPad'). Fluxo is the app's folder; the placeholder is the name of the recordings folder on disk ('Recordings'), which is never translated.")
        }
        return String(localized: "Files › On My iPhone › Fluxo › \(folder)", comment: "Where recordings are on an iPhone, as a path in the Files app. Use the names the Files app shows in this language ('Files', 'On My iPhone'). Fluxo is the app's folder; the placeholder is the name of the recordings folder on disk ('Recordings'), which is never translated.")
        #endif
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .deleteRecordings:
            return String(localized: "Delete All Recordings?", comment: "Title of the confirmation in Settings.")
        case .clearHistory:
            return String(localized: "Clear Watch History?", comment: "Title of the confirmation in Settings.")
        case nil:
            return ""
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    private static func minutes(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}

/// A settings row title with its symbol on a small colored tile, as in the system Settings.
struct SettingsLabel: View {
    let title: Text
    let systemImage: String
    let tint: Color

    init(_ title: LocalizedStringKey, systemImage: String, tint: Color) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.tint = tint
    }

    /// A title localized already (`String(localized:)`). A distinct label, so string literals keep
    /// resolving to the `LocalizedStringKey` initializer above and stay looked up in the catalog.
    init(localized title: String, systemImage: String, tint: Color) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            title
        } icon: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: .rect(cornerRadius: 7, style: .continuous))
        }
    }
}

/// The top of Settings: the app, its version, and the library at a glance.
private struct SettingsHeader: View {

    let recordingCount: Int

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @Environment(ChannelLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 14) {
            AdaptiveStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Theme.brandGradient)
                    Image(systemName: "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: Theme.pink.opacity(0.6), radius: 6)
                    Capsule()
                        .fill(Theme.streamGradient)
                        .frame(width: 36, height: 3)
                        .offset(y: 20)
                }
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Fluxo")
                        .font(.title2.bold())
                    Text("Version \(SettingsViewModel.appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Four tiles side by side; one row each at the accessibility text sizes.
            let layout = dynamicTypeSize.prefersStackedLayout ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                stat(value: playlists.count, title: "Playlists", systemImage: "list.bullet.rectangle")
                stat(value: playlists.reduce(0) { $0 + $1.channelCount }, title: "Channels", systemImage: "play.tv")
                stat(value: library.favoriteKeys.count, title: "Favorites", systemImage: "star.fill")
                stat(value: recordingCount, title: "Recordings", systemImage: "record.circle")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stat(value: Int, title: LocalizedStringKey, systemImage: String) -> some View {
        if dynamicTypeSize.prefersStackedLayout {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(value, format: .number.notation(.compactName))
                    .font(.headline.monospacedDigit())
                Text(title)
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface, in: .rect(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        } else {
            statTile(value: value, title: title, systemImage: systemImage)
        }
    }

    private func statTile(value: Int, title: LocalizedStringKey, systemImage: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(value, format: .number.notation(.compactName))
                .font(.headline.monospacedDigit())
                .lineLimit(1)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.surface, in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        SettingsView(player: AVPlayerViewModel())
    }
    .fluxoPreviewEnvironment()
}

#if DEBUG
extension Notification.Name {
    /// Debug harness: scrolls Settings to the section whose id is the object (`settings-section:downloads`).
    static let fluxoDebugSettingsSection = Notification.Name("FluxoDebugSettingsSection")
}
#endif
