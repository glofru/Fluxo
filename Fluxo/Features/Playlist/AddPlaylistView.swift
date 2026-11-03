//
//  AddPlaylistView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-03.
//

import SwiftData
import SwiftUI

/// Validation of the URL typed in the playlist form.
enum PlaylistURLValidation: Equatable {
    case empty
    case invalid(String)
    case valid(URL)

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .empty
            return
        }
        guard trimmed.contains("://") else {
            self = .invalid("Start the address with http:// or https://.")
            return
        }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            self = .invalid("This is not a valid web address.")
            return
        }
        guard scheme == "http" || scheme == "https" else {
            self = .invalid("Only http:// and https:// playlists are supported.")
            return
        }
        guard let host = components.host, !host.isEmpty, let url = components.url else {
            self = .invalid("The address has no server name.")
            return
        }
        self = .valid(url)
    }

    var url: URL? {
        if case .valid(let url) = self {
            return url
        }
        return nil
    }

    var message: String? {
        if case .invalid(let message) = self {
            return message
        }
        return nil
    }

    /// A readable default name for a playlist at `url`, e.g. "example.com" or "playlist" from the file name.
    static func suggestedName(for url: URL) -> String {
        let file = url.deletingPathExtension().lastPathComponent
        if !file.isEmpty, file != "/", !["get", "playlist", "index", "get.php"].contains(file.lowercased()) {
            return file
        }
        return url.host() ?? "Playlist"
    }
}

/// Add a playlist (name + M3U URL, imported right away) or edit one (name and URL; a new URL is re-imported).
struct AddPlaylistView: View {

    private enum Field {
        case name
        case url
    }

    private enum Phase: Equatable {
        case editing
        case importing(UUID)
        case failed(String)
    }

    var playlist: Playlist?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaylistImportCenter.self) private var importCenter

    @State private var name = ""
    @State private var urlText = ""
    /// Shows the URL error only once the user left the field or tried to submit.
    @State private var showsValidation = false
    @State private var phase: Phase = .editing
    @State private var importTask: Task<Void, Never>?
    @State private var didFinish = false
    @FocusState private var focusedField: Field?

    private var validation: PlaylistURLValidation {
        PlaylistURLValidation(urlText)
    }

    private var isImporting: Bool {
        if case .importing = phase {
            return true
        }
        return false
    }

    private var isEditing: Bool {
        playlist != nil
    }

    private var canSubmit: Bool {
        validation.url != nil && !isImporting
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(namePlaceholder))
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit {
                        focusedField = .url
                    }

                HStack(spacing: 8) {
                    TextField("URL", text: $urlText, prompt: Text("https://example.com/playlist.m3u"))
                        .focused($focusedField, equals: .url)
                        .textContentType(.URL)
                        .urlKeyboard()
                        .submitLabel(.go)
                        .onSubmit(submit)

                    if !urlText.isEmpty && !isImporting {
                        Button {
                            urlText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear URL")
                    }

                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                            return
                        }
                        urlText = text
                        showsValidation = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .disabled(isImporting)
                }
            } header: {
                Text("Playlist")
            } footer: {
                if showsValidation, let message = validation.message {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("M3U and M3U8 playlists over HTTP or HTTPS. Channels, groups and logos are imported on this device.")
                }
            }
            .disabled(isImporting)

            switch phase {
            case .editing:
                EmptyView()

            case .importing(let uuid):
                Section("Importing") {
                    PlaylistImportProgressView(progress: importCenter.progress[uuid] ?? .connecting)
                    Button("Cancel Import", systemImage: "xmark.circle", role: .destructive) {
                        cancelImport()
                    }
                }

            case .failed(let message):
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("The playlist couldn't be imported")
                                .font(.headline)
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    Button("Try Again", systemImage: "arrow.clockwise", action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isEditing ? "Edit Playlist" : "Add Playlist")
        .inlineNavigationBar()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    // Cancelling stops the download and removes everything imported so far.
                    importTask?.cancel()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(isEditing ? "Save" : "Add", action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        // Keep the sheet up while importing so the import is either finished or explicitly cancelled.
        .interactiveDismissDisabled(isImporting)
        .onChange(of: focusedField) { previous, _ in
            if previous == .url {
                showsValidation = true
            }
        }
        .sensoryFeedback(.success, trigger: didFinish)
        .sensoryFeedback(.error, trigger: phase) { _, new in
            if case .failed = new {
                return true
            }
            return false
        }
        .onAppear(perform: prefill)
    }

    private var namePlaceholder: String {
        validation.url.map(PlaylistURLValidation.suggestedName(for:)) ?? "My playlist"
    }

    private func prefill() {
        guard let playlist else {
            #if DEBUG
            // Debug builds start with a small public playlist to speed up testing.
            if urlText.isEmpty {
                name = "Test"
                urlText = "https://raw.githubusercontent.com/joaoguidugli/FTA-IPTV-Brasil/master/playlist.m3u8"
            }
            #endif
            focusedField = .url
            return
        }
        name = playlist.name
        urlText = playlist.url.absoluteString
        focusedField = .name
    }

    private func submit() {
        showsValidation = true
        guard let url = validation.url, !isImporting else {
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? PlaylistURLValidation.suggestedName(for: url) : trimmedName

        if let playlist {
            let urlChanged = playlist.url != url
            playlist.name = finalName
            playlist.url = url
            do {
                try modelContext.save()
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            if urlChanged {
                // A different address: download it again (the current channels stay until it succeeds). An
                // update that is still downloading the old address is replaced.
                importCenter.restartRefresh(playlist)
            }
            didFinish.toggle()
            dismiss()
            return
        }

        startImport(name: finalName, url: url)
    }

    private func startImport(name: String, url: URL) {
        let uuid = UUID()
        phase = .importing(uuid)
        focusedField = nil

        importTask = Task {
            defer {
                importTask = nil
            }
            do {
                try await importCenter.addPlaylist(uuid: uuid, name: name, url: url)
                phase = .editing
                didFinish.toggle()
                dismiss()
            } catch is CancellationError {
                // Cancelled from the form: back to editing. (Cancel in the toolbar dismisses the sheet.)
                phase = .editing
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        phase = .editing
    }
}

/// Linear progress for an import; indeterminate when the server did not send a length.
struct PlaylistImportProgressView: View {
    let progress: PlaylistImportProgress

    var body: some View {
        if let fraction = progress.fractionCompleted {
            ProgressView(value: fraction, total: 1) {
                Text(progress.message)
            } currentValueLabel: {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .progressViewStyle(.linear)
        } else {
            ProgressView {
                Text(progress.message)
            }
            .progressViewStyle(.linear)
        }
    }
}

#Preview("Add") {
    NavigationStack {
        AddPlaylistView()
    }
    .fluxoPreviewEnvironment()
}
