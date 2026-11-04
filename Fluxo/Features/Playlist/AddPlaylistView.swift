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

    /// - Parameter localURL: the address of the playlist being edited when it was imported from a file (drag and
    ///   drop, Open in Fluxo): the app's copy of the file, the only file address the form accepts.
    init(_ text: String, localURL: URL? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .empty
            return
        }
        if let localURL, trimmed == localURL.absoluteString {
            self = .valid(localURL)
            return
        }
        guard trimmed.contains("://") else {
            self = .invalid(String(localized: "Start the address with http:// or https://.", comment: "Validation message of the playlist address field."))
            return
        }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            self = .invalid(String(localized: "This is not a valid web address.", comment: "Validation message of the playlist address field."))
            return
        }
        guard scheme == "http" || scheme == "https" else {
            self = .invalid(String(localized: "Only http:// and https:// playlists are supported.", comment: "Validation message of the playlist address field."))
            return
        }
        guard let host = components.host, !host.isEmpty, let url = components.url else {
            self = .invalid(String(localized: "The address has no server name.", comment: "Validation message of the playlist address field."))
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
        return url.host() ?? String(localized: "Playlist", comment: "Default name of a playlist whose address has no usable name.")
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
    /// The address a new playlist starts with (a link dropped on the window).
    var initialURL: URL?

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
        PlaylistURLValidation(urlText, localURL: playlist.flatMap { LocalPlaylistFiles.isLocal($0.url) ? $0.url : nil })
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
                    TextField("URL", text: $urlText, prompt: Text(verbatim: "https://example.com/playlist.m3u"))
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
                                .foregroundStyle(Theme.secondaryText)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
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
                        .foregroundStyle(Theme.error)
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
                                .foregroundStyle(Theme.secondaryText)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.error)
                    }
                    Button("Try Again", systemImage: "arrow.clockwise", action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        .formStyle(.grouped)
        .glassSheetContentBackground()
        .navigationTitle(isEditing ? "Edit Playlist" : "Add Playlist")
        .inlineNavigationBar()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // iOS 26 draws the cancel role as a glass close button.
                Button(role: .cancel) {
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
                    Button(isEditing ? "Save" : "Add", role: .confirm, action: submit)
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
        validation.url.map(PlaylistURLValidation.suggestedName(for:)) ?? String(localized: "My playlist", comment: "Placeholder of the playlist name field.")
    }

    private func prefill() {
        guard let playlist else {
            if let initialURL, urlText.isEmpty {
                urlText = initialURL.absoluteString
                showsValidation = true
                focusedField = .name
                return
            }
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
