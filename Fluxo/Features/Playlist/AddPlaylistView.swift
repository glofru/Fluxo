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
    /// The address a new playlist starts with (a link dropped on the window, the demo playlist).
    var initialURL: URL?
    /// The name a new playlist starts with (the demo playlist).
    var initialName: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(tvOS)
    @Environment(CloudSync.self) private var cloudSync: CloudSync?
    #endif

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

                // The buttons under the field at the accessibility text sizes: next to them the field is a few
                // characters wide.
                AdaptiveStack(spacing: 8) {
                    TextField("URL", text: $urlText, prompt: Text(verbatim: "https://example.com/playlist.m3u"))
                        .focused($focusedField, equals: .url)
                        .textContentType(.URL)
                        .urlKeyboard()
                        .submitLabel(.go)
                        .onSubmit(submit)

                    HStack(spacing: 8) {
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

                        #if !os(tvOS)
                        // No clipboard on Apple TV (`PlatformFeatures.pasteboard`): the URL is typed, or dictated.
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
                        #endif
                    }
                }
            } header: {
                Text("Playlist")
            } footer: {
                if showsValidation, let message = validation.message {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.error)
                } else {
                    #if os(tvOS)
                    // Typing an address with the Siri Remote is slow: the faster ways, instead of the format note (iCloud
                    // only when this Apple TV can sync).
                    if let cloudSync, cloudSync.isEnabled, cloudSync.isConfigured, cloudSync.availability == .available {
                        Text("Type with your iPhone: open its Apple TV Keyboard notification. Or add the playlist on another device, and iCloud brings it here.", comment: "Apple TV, Add Playlist: how to avoid typing the address with the remote (the Continuity Keyboard on an iPhone or iPad, or iCloud sync).")
                    } else {
                        Text("Type with your iPhone: open its Apple TV Keyboard notification.", comment: "Apple TV, Add Playlist: how to avoid typing the address with the remote (the Continuity Keyboard on an iPhone or iPad), when iCloud sync is off or unavailable.")
                    }
                    #else
                    Text("M3U and M3U8 playlists over HTTP or HTTPS. Channels, groups and logos are imported on this device.")
                    #endif
                }
            }
            .disabled(isImporting)

            if showsUnencryptedLoginWarning {
                Section {
                    Label {
                        Text("This address isn't encrypted: your provider's user name and password in it travel as plain text. Use https:// if your provider offers it.", comment: "Add Playlist: warning for an http:// playlist address that contains an account name or password.")
                    } icon: {
                        Image(systemName: "lock.open.trianglebadge.exclamationmark")
                            .foregroundStyle(Theme.warning)
                    }
                    .font(.callout)
                }
            }

            if !isEditing {
                Section {
                    Text(ContentNotice.text)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .readableWithRemote()
                    if validation.url != DemoPlaylist.url {
                        Button {
                            name = DemoPlaylist.name
                            urlText = DemoPlaylist.url.absoluteString
                            showsValidation = true
                        } label: {
                            Label {
                                Text("Use the Demo Playlist", comment: "Add Playlist: fills in the demo playlist (free test streams and Creative Commons films).")
                            } icon: {
                                Image(systemName: "sparkles.tv")
                            }
                        }
                        .disabled(isImporting)
                    }
                } footer: {
                    Text("The demo playlist has a live test stream and open movies from the Blender Foundation, free to watch.", comment: "Add Playlist: what the demo playlist contains.")
                }
            }

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
            #if os(tvOS)
            // Apple TV: the sheet's bar is too narrow for the title and two buttons, so Add is the last row (and
            // Menu on the remote cancels, as everywhere on tvOS).
            Section {
                if isImporting {
                    ProgressView()
                } else {
                    Button(isEditing ? "Save" : "Add", systemImage: isEditing ? "checkmark" : "plus", action: submit)
                        .disabled(!canSubmit)
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .glassSheetContentBackground()
        .navigationTitle(isEditing ? "Edit Playlist" : "Add Playlist")
        .inlineNavigationBar()
        #if !os(tvOS)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // The cancel role draws as a glass close button (Liquid Glass).
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
                    ConfirmToolbarButton(title: isEditing ? String(localized: "Save") : String(localized: "Add"), textSize: dynamicTypeSize, action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        #endif
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

    /// An http address with an account name or password in it (`StreamLink.hasCredentials`): they would travel
    /// unencrypted.
    private var showsUnencryptedLoginWarning: Bool {
        guard let url = validation.url, url.scheme?.lowercased() == "http" else {
            return false
        }
        return StreamLink.hasCredentials(url)
    }

    private var namePlaceholder: String {
        validation.url.map(PlaylistURLValidation.suggestedName(for:)) ?? String(localized: "My playlist", comment: "Placeholder of the playlist name field.")
    }

    private func prefill() {
        guard let playlist else {
            if let initialURL, urlText.isEmpty {
                urlText = initialURL.absoluteString
                name = initialName ?? ""
                showsValidation = true
                focusedField = .name
                return
            }
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
