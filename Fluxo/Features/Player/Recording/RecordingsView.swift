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
                    List(store.recordings) { recording in
                        Button {
                            requestPlay(recording)
                        } label: {
                            RecordingRow(recording: recording)
                        }
                        .buttonStyle(.plain)
                        .disabled(recording.isFinalizing)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                recordingToDelete = recording
                            }
                            .disabled(recording.isFinalizing)
                        }
                        .contextMenu {
                            Button("Play", systemImage: "play.fill") {
                                requestPlay(recording)
                            }
                            .disabled(recording.isFinalizing)

                            Button("Delete", systemImage: "trash", role: .destructive) {
                                recordingToDelete = recording
                            }
                            .disabled(recording.isFinalizing)
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .inlineNavigationBar()
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
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
            .alert("Stop the current recording?", isPresented: playAlertBinding, presenting: recordingToPlay) { recording in
                Button("Stop and Play", role: .destructive) {
                    onPlay(recording)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Playing a recording stops the live channel and saves the recording in progress.")
            }
            .alert("Recording", isPresented: errorAlertBinding) {
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
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if recording.isFinalizing {
                    Text("Saving…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let duration = recording.duration {
                    Text(Duration.seconds(duration), format: .time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
                        .font(.caption.monospacedDigit())
                }
                Text(ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}
