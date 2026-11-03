//
//  SettingsView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-06.
//

import SwiftUI

/// Playback, TV guide, recordings, storage and about. A tab on iOS, the Settings window (⌘,) on macOS.
struct SettingsView: View {

    let player: AVPlayerViewModel

    @Environment(ChannelLibrary.self) private var library

    @AppStorage(PlayerPreferences.timeShiftMinutesKey) private var timeShiftMinutes = PlayerPreferences.defaultTimeShiftMinutes
    @AppStorage(PlayerPreferences.skipBackwardSecondsKey) private var skipBackwardSeconds = PlayerPreferences.defaultSkipBackwardSeconds
    @AppStorage(PlayerPreferences.skipForwardSecondsKey) private var skipForwardSeconds = PlayerPreferences.defaultSkipForwardSeconds
    @AppStorage(PlayerPreferences.autoPictureInPictureKey) private var autoPictureInPicture = PlayerPreferences.defaultAutoPictureInPicture

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
        Form {
            playbackSection
            GuideSettingsSection()
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
            Picker("Time-shift buffer", selection: $timeShiftMinutes) {
                ForEach(PlayerPreferences.timeShiftChoices, id: \.self) { minutes in
                    Text(Self.minutes(minutes)).tag(minutes)
                }
            }

            Picker("Skip back", selection: $skipBackwardSeconds) {
                ForEach(PlayerPreferences.skipChoices, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }

            Picker("Skip forward", selection: $skipForwardSeconds) {
                ForEach(PlayerPreferences.skipChoices, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }

            #if !os(macOS)
            Toggle("Start Picture in Picture automatically", isOn: $autoPictureInPicture)
            #endif
        } header: {
            Text("Playback")
        } footer: {
            Text("How far back you can go in a live channel. Applies the next time a channel starts. The buffer uses at most \(Self.bytes(PlayerPreferences.timeShiftBytes)) and never more than a tenth of the free space.")
        }
    }

    private var recordingsSection: some View {
        let store = player.recordings
        return Section {
            LabeledContent("Recordings") {
                Text("\(store.recordings.count) · \(Self.bytes(store.totalBytes))")
                    .monospacedDigit()
            }

            LabeledContent("Location") {
                Text(recordingsLocation)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
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
            LabeledContent("Temporary stream files") {
                Text(Self.bytes(Int64(viewModel.streamFilesSize)))
                    .monospacedDigit()
            }
            Button("Clear Stream Files", systemImage: "trash") {
                viewModel.deleteStreamFiles()
            }
            .disabled(!canClearStreamFiles || viewModel.streamFilesSize == 0)

            LabeledContent("Channel logos") {
                Text(Self.bytes(Int64(viewModel.logoCacheSize)))
                    .monospacedDigit()
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
            LabeledContent("Version", value: SettingsViewModel.appVersion)
            LabeledContent("FFmpeg", value: SettingsViewModel.ffmpegVersion)
        }
    }

    // MARK: - Helpers

    private var recordingsLocation: String {
        #if os(macOS)
        return (player.recordings.directory.path as NSString).abbreviatingWithTildeInPath
        #else
        return "Files › On My \(UIDevice.current.model) › Fluxo › Recordings"
        #endif
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .deleteRecordings:
            return "Delete All Recordings?"
        case .clearHistory:
            return "Clear Watch History?"
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

#Preview {
    NavigationStack {
        SettingsView(player: AVPlayerViewModel())
    }
    .fluxoPreviewEnvironment()
}
