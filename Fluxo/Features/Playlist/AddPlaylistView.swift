//
//  AddPlaylistView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-03.
//

import SwiftData
import SwiftUI

struct AddPlaylistView: View {

    private enum Field {
        case name
        case url
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Environment(PlaylistImportCenter.self) private var importCenter

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var actualUrl: URL?
    @State private var loading = false
    @State private var error: String?
    @State private var importTask: Task<Void, Never>?
    @State private var importingPlaylistID: UUID?

    private var showUrlError: Bool {
        !url.isEmpty && actualUrl == nil
    }

    private var title: String {
        if playlist != nil {
            return "Rename Playlist"
        }

        return "Add Playlist"
    }

    @FocusState private var focusField: Field?

    var playlist: Playlist?

    var body: some View {
        VStack(alignment: .center) {
            Text("Support M3U playlists")

            FluxoTextField("Name", text: .init(get: { name }, set: { name = $0.trimmingCharacters(in: .whitespacesAndNewlines) }), placeholder: "Name of the playlist")
                .focused($focusField, equals: .name)
                .onSubmit {
                    focusField = .url
                }
                .onAppear {
                    focusField = .name
                }
                .submitLabel(.next)
                .textFieldStyle(.roundedBorder)
                .disabled(loading)

            FluxoTextField("URL", text: .init(get: { url }, set: { url = $0; actualUrl = URL(string: $0) }), placeholder: "https://myplaylist.com/playlist.m3u", error: showUrlError ? "InvalidURL" : nil)
                .focused($focusField, equals: .url)
                .textContentType(.URL)
                .urlKeyboard()
                .disabled(loading || playlist != nil)

            FluxoButton(label: playlist == nil ? "Add Playlist" : "Save", loading: loading) {
                guard let actualUrl, !name.isEmpty else {
                    return
                }

                if let playlist {
                    playlist.name = name
                    playlist.url = actualUrl
                    try? modelContext.save()
                    dismiss()
                    return
                }

                startImport(name: name, url: actualUrl)
            }
            .disabled(loading || actualUrl == nil || name.isEmpty)

            if loading {
                PlaylistImportProgressView(progress: importingPlaylistID.flatMap { importCenter.progress[$0] } ?? .connecting)
            }

            Spacer()
        }
        .textFieldStyle(.roundedBorder)
        .padding()
        .navigationTitle(title)
        .inlineNavigationBar()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: {
                    // Cancelling stops the download and removes everything imported so far.
                    importTask?.cancel()
                    dismiss()
                }, label: {
                    Text("Cancel")
                })
            }
        }
        // Keep the sheet up while importing so the import is either finished or explicitly cancelled.
        .interactiveDismissDisabled(loading)
        .alert(isPresented: .init(get: { error != nil }, set: { _ in error = nil })) {
            Alert(title: Text("Error"), message: Text(error ?? ""))
        }
        .onAppear {
            guard let playlist else {
                #if DEBUG
                // Debug builds start with a small public playlist to speed up testing.
                self.name = "Test"
                self.url = "https://raw.githubusercontent.com/joaoguidugli/FTA-IPTV-Brasil/master/playlist.m3u8"
                self.actualUrl = URL(string: self.url)
                #endif
                return
            }

            self.name = playlist.name
            self.url = playlist.url.absoluteString
            self.actualUrl = URL(string: url)
        }
    }

    private func startImport(name: String, url: URL) {
        let uuid = UUID()
        loading = true
        importingPlaylistID = uuid

        importTask = Task {
            defer {
                loading = false
                importingPlaylistID = nil
                importTask = nil
            }

            do {
                try await importCenter.addPlaylist(uuid: uuid, name: name, url: url)
                dismiss()
            } catch is CancellationError {
                // The user cancelled; the sheet is already being dismissed.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Linear progress for an import; indeterminate when the server did not send a length.
struct PlaylistImportProgressView: View {
    let progress: PlaylistImportProgress

    var body: some View {
        if let fraction = progress.fractionCompleted {
            ProgressView(progress.message, value: fraction, total: 1)
                .progressViewStyle(.linear)
        } else {
            ProgressView(progress.message)
                .progressViewStyle(.linear)
        }
    }
}

#Preview {
    NavigationStack {
        AddPlaylistView()
    }
    .fluxoPreviewEnvironment()
}
