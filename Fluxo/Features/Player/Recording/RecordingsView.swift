//
//  RecordingsView.swift
//  Fluxo
//
//  Lists the stream recordings and lets the user play or delete them.
//

import SwiftUI

struct RecordingsView: View {

    let store: RecordingStore
    /// A recording of the live stream is running; playing a recording would stop it.
    var isRecordingActive = false
    /// False when shown as a screen (macOS sidebar) rather than as a sheet.
    var showsDoneButton = true
    let onPlay: (Recording) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recordingToDelete: Recording?
    @State private var recordingToPlay: Recording?
    @State private var isConfirmingDeleteAll = false

    var body: some View {
        NavigationStack {
            Group {
                if store.recordings.isEmpty {
                    ContentUnavailableView(
                        "No Recordings",
                        systemImage: "record.circle",
                        description: Text("Use the record button while watching a live channel.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(store.recordings) { recording in
                                Button {
                                    requestPlay(recording)
                                } label: {
                                    RecordingRow(recording: recording)
                                }
                                .buttonStyle(.plain)
                                .disabled(recording.isFinalizing)
                                .accessibilityHint(recording.isFinalizing ? Text("Being saved", comment: "VoiceOver hint of a recording that is still being written.") : Text("Plays the recording", comment: "VoiceOver hint of a recording in the list."))
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        recordingToDelete = recording
                                    }
                                    .disabled(recording.isFinalizing)
                                }
                                .swipeActions(edge: .leading) {
                                    if !recording.isFinalizing {
                                        ShareLink(item: recording.url) {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                        .tint(Theme.accentFill)
                                    }
                                }
                                .contextMenu {
                                    RecordingMenuItems(recording: recording, play: { requestPlay(recording) }, delete: { recordingToDelete = recording })
                                }
                            }
                        } footer: {
                            Text(TextParts.line([
                                String(localized: "\(store.recordings.count) recordings", comment: "Footer of the recordings list: the number of recordings, followed by their total size."),
                                store.totalBytes.formatted(.byteCount(style: .file)),
                            ]))
                        }
                    }
                    .glassSheetContentBackground()
                }
            }
            .navigationTitle("Recordings")
            .inlineNavigationBar()
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        #if os(macOS)
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.directory])
                        }
                        #endif
                        Button("Delete All Recordings…", systemImage: "trash", role: .destructive) {
                            isConfirmingDeleteAll = true
                        }
                        .disabled(store.recordings.isEmpty || isRecordingActive)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .close) {
                            dismiss()
                        }
                    }
                }
            }
            .alert("Delete this recording?", isPresented: deleteAlertBinding, presenting: recordingToDelete) { recording in
                Button("Delete", role: .destructive) {
                    store.delete(recording)
                }
                Button("Cancel", role: .cancel) {}
            } message: { recording in
                Text(recording.title)
            }
            .alert("Delete all recordings?", isPresented: $isConfirmingDeleteAll) {
                Button("Delete All", role: .destructive) {
                    store.deleteAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(store.recordings.count) recordings will be deleted from this device.")
            }
            .alert("Stop the current recording?", isPresented: playAlertBinding, presenting: recordingToPlay) { recording in
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
        .onAppear {
            store.reload()
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func requestPlay(_ recording: Recording) {
        if isRecordingActive {
            recordingToPlay = recording
        } else {
            onPlay(recording)
        }
    }

    private var playAlertBinding: Binding<Bool> {
        Binding(get: { recordingToPlay != nil }, set: { if !$0 { recordingToPlay = nil } })
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { recordingToDelete != nil }, set: { if !$0 { recordingToDelete = nil } })
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { store.lastError != nil }, set: { if !$0 { store.clearError() } })
    }
}

/// Play, share, reveal and delete entries of a recording.
private struct RecordingMenuItems: View {
    let recording: Recording
    let play: () -> Void
    let delete: () -> Void

    var body: some View {
        Button("Play", systemImage: "play.fill", action: play)
            .disabled(recording.isFinalizing)

        if !recording.isFinalizing {
            ShareLink(item: recording.url) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }

        #if os(macOS)
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([recording.url])
        }
        #endif

        Divider()

        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            .disabled(recording.isFinalizing)
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: recording.isFinalizing ? "hourglass" : "play.rectangle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(recording.createdOn, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if recording.isFinalizing {
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
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
