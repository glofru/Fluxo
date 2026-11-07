//
//  RecordingsView.swift
//  Fluxo
//
//  Lists the stream recordings and lets the user play or delete them (they play only in Fluxo: no Share, no Files).
//
//  The pieces are shared by the two places that list recordings: `RecordingsView` (the sheet of the player and the
//  Recordings screen of the iPad and Mac sidebars) and the Recordings section of the Library tab (`LibraryView`):
//  `RecordingRows` (the rows, with their swipe and context menu actions), `recordingPrompts(_:store:onPlay:)` (the
//  confirmations they ask for), `RecordingsMoreMenu` and `RecordingsEmptyState`.
//

import SwiftUI

struct RecordingsView: View {

    let store: RecordingStore
    /// A recording of the live stream is running; playing a recording would stop it.
    var isRecordingActive = false
    /// False when shown as a screen (iPad and macOS sidebars) rather than as a sheet.
    var showsDoneButton = true
    let onPlay: (Recording) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var prompts = RecordingPrompts()

    var body: some View {
        NavigationStack {
            Group {
                if store.recordings.isEmpty {
                    RecordingsEmptyState()
                } else {
                    List {
                        Section {
                            RecordingRows(store: store, isRecordingActive: isRecordingActive, prompts: $prompts, onPlay: onPlay)
                        } footer: {
                            RecordingsFooter(store: store)
                        }
                    }
                    .glassSheetContentBackground()
                }
            }
            .navigationTitle("Recordings")
            .inlineNavigationBar()
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    RecordingsMoreMenu(store: store, isRecordingActive: isRecordingActive, prompts: $prompts)
                }
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .close) {
                            dismiss()
                        }
                    }
                }
            }
            .recordingPrompts($prompts, store: store, onPlay: onPlay)
        }
        .onAppear {
            store.reload()
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

// MARK: - Shared pieces

/// The confirmations a list of recordings asks for: delete one, delete all, or stop the recording in progress to
/// play one. The screen that shows the rows owns it and attaches `recordingPrompts(_:store:onPlay:)`.
struct RecordingPrompts {
    var recordingToDelete: Recording?
    var recordingToPlay: Recording?
    var isConfirmingDeleteAll = false
}

/// One row per recording: a tap plays it (after a confirmation while a recording is in progress), a swipe deletes or
/// shares it, and the context menu has the same actions.
struct RecordingRows: View {
    let store: RecordingStore
    let isRecordingActive: Bool
    @Binding var prompts: RecordingPrompts
    let onPlay: (Recording) -> Void

    var body: some View {
        ForEach(store.recordings) { recording in
            Button {
                requestPlay(recording)
            } label: {
                RecordingRow(recording: recording)
            }
            .buttonStyle(.plain)
            .disabled(recording.isFinalizing)
            .accessibilityHint(hint(for: recording))
            .rowSwipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    prompts.recordingToDelete = recording
                }
                .disabled(recording.isFinalizing)
            }
            .contextMenu {
                RecordingMenuItems(recording: recording, play: { requestPlay(recording) }, delete: { prompts.recordingToDelete = recording })
            }
        }
    }

    private func hint(for recording: Recording) -> Text {
        if recording.isRecording {
            return Text("Still recording", comment: "VoiceOver hint of a recording that is still being recorded.")
        }
        if recording.isFinalizing {
            return Text("Being saved", comment: "VoiceOver hint of a recording that is still being written.")
        }
        return Text("Plays the recording", comment: "VoiceOver hint of a recording in the list.")
    }

    private func requestPlay(_ recording: Recording) {
        if isRecordingActive {
            prompts.recordingToPlay = recording
        } else {
            onPlay(recording)
        }
    }
}

/// Footer of a list of recordings: how many there are and the space they take.
struct RecordingsFooter: View {
    let store: RecordingStore

    var body: some View {
        Text(TextParts.line([
            String(localized: "\(store.recordings.count) recordings", comment: "Footer of the recordings list: the number of recordings, followed by their total size."),
            store.totalBytes.formatted(.byteCount(style: .file)),
        ]))
    }
}

/// "No Recordings", and how to make one.
struct RecordingsEmptyState: View {
    var body: some View {
        ContentUnavailableView(
            "No Recordings",
            systemImage: "record.circle",
            description: Text("Use the record button while watching a live channel.")
        )
    }
}

/// The "More" menu of a list of recordings: Delete All Recordings.
struct RecordingsMoreMenu: View {
    let store: RecordingStore
    let isRecordingActive: Bool
    @Binding var prompts: RecordingPrompts

    var body: some View {
        Menu {
            Button("Delete All Recordings…", systemImage: "trash", role: .destructive) {
                prompts.isConfirmingDeleteAll = true
            }
            .disabled(store.recordings.isEmpty || isRecordingActive)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}

extension View {
    /// The confirmations of `RecordingRows` and `RecordingsMoreMenu`, and the alert of a recording that could not be
    /// saved.
    func recordingPrompts(_ prompts: Binding<RecordingPrompts>, store: RecordingStore, onPlay: @escaping (Recording) -> Void) -> some View {
        modifier(RecordingPromptsModifier(prompts: prompts, store: store, onPlay: onPlay))
    }
}

private struct RecordingPromptsModifier: ViewModifier {
    @Binding var prompts: RecordingPrompts
    let store: RecordingStore
    let onPlay: (Recording) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Delete this recording?", isPresented: deleteAlertBinding, presenting: prompts.recordingToDelete) { recording in
                Button("Delete", role: .destructive) {
                    store.delete(recording)
                }
                Button("Cancel", role: .cancel) {}
            } message: { recording in
                Text(recording.title)
            }
            .alert("Delete all recordings?", isPresented: $prompts.isConfirmingDeleteAll) {
                Button("Delete All", role: .destructive) {
                    store.deleteAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(store.recordings.count) recordings will be deleted from this device.")
            }
            .alert("Stop the current recording?", isPresented: playAlertBinding, presenting: prompts.recordingToPlay) { recording in
                Button("Stop and Play", role: .destructive) {
                    onPlay(recording)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Playing a recording stops the live channel and saves the recording in progress.")
            }
            .alert(Text("Recording", comment: "Title of the alert that shows a recording error."), isPresented: errorAlertBinding) {
                Button("OK", role: .cancel) {
                    store.clearError()
                }
            } message: {
                Text(store.lastError ?? "")
            }
    }

    private var playAlertBinding: Binding<Bool> {
        Binding(get: { prompts.recordingToPlay != nil }, set: { if !$0 { prompts.recordingToPlay = nil } })
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { prompts.recordingToDelete != nil }, set: { if !$0 { prompts.recordingToDelete = nil } })
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { store.lastError != nil }, set: { if !$0 { store.clearError() } })
    }
}

/// Play and delete entries of a recording. Recordings play only in Fluxo: there is no Share or Show in Finder (they
/// are copies of the user's provider's streams, for personal viewing; App Review guideline 5.2.3).
private struct RecordingMenuItems: View {
    let recording: Recording
    let play: () -> Void
    let delete: () -> Void

    var body: some View {
        Button("Play", systemImage: "play.fill", action: play)
            .disabled(recording.isFinalizing)

        Divider()

        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            .disabled(recording.isFinalizing)
    }
}

private struct RecordingRow: View {
    let recording: Recording

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility text sizes the duration and size move under the title, which may then wrap.
        AdaptiveStack(verticalAlignment: .center, spacing: 12) {
            HStack(alignment: dynamicTypeSize.prefersStackedLayout ? .top : .center, spacing: 12) {
                icon
                    .font(.title2)
                    .frame(width: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.title)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 1)
                    Text(recording.createdOn, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            if !dynamicTypeSize.prefersStackedLayout {
                Spacer(minLength: 8)
            }

            VStack(alignment: dynamicTypeSize.prefersStackedLayout ? .leading : .trailing, spacing: 2) {
                if recording.isRecording {
                    Text("Recording…", comment: "A recording in the list that is still being recorded.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.recording)
                } else if recording.isFinalizing {
                    Text("Saving…")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                } else if let duration = recording.duration {
                    Text(Duration.seconds(duration), format: .time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
                        .font(.caption.monospacedDigit())
                }
                Text(recording.bytes.formatted(.byteCount(style: .file)))
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if recording.isRecording {
            Image(systemName: "record.circle")
                .foregroundStyle(Theme.recording)
                .ambientSymbolEffect(.pulse)
        } else if recording.isFinalizing {
            Image(systemName: "hourglass")
                .foregroundStyle(.tint)
        } else {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(.tint)
        }
    }
}
