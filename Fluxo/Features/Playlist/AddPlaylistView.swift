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

    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = PlaylistViewModel()

    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var actualUrl: URL?
    @State private var loading = false
    @State private var error: String?

    private var showUrlError: Bool {
        !url.isEmpty && actualUrl == nil
    }

    private var title: String {
        if playlist != nil {
            return "Edit Playlist"
        }

        return "Add Playlist"
    }

    @FocusState private var focusField: Field?

    var playlist: Playlist?

    var body: some View {
        NavigationView {
            ZStack {
                Color(themeManager.selectedTheme.primary)
                    .ignoresSafeArea(.all)

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
                        .keyboardType(.URL)
                        .disabled(loading || playlist != nil)

                    FluxoButton(label: title, loading: loading) {
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

                        loading = true

                        Task {
                            let result = await viewModel.addPlaylist(.init(name: name, url: actualUrl), context: modelContext)

                            switch result {
                            case .failure(let error):
                                self.error = error.localizedDescription
                            case .success:
                                dismiss()
                            }

                            await MainActor.run {
                                loading = false
                            }
                        }
                    }
                    .disabled(loading || actualUrl == nil || name.isEmpty)

                    if let progress = viewModel.progress {
                        ProgressView(progress.message, value: progress.percentage, total: 1)
                            .progressViewStyle(.linear)
                            .tint(themeManager.selectedTheme.accentPrimary)
                    }

                    Spacer()
                }
                .textFieldStyle(.roundedBorder)
                .padding()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: {
                            dismiss()
                        }, label: {
                            Text("Cancel")
                        })
                    }
                }
                .toolbarBackground(themeManager.selectedTheme.secondary, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .alert(isPresented: .init(get: { error != nil }, set: { _ in error = nil })) {
                    Alert(title: Text("Error"), message: Text(error ?? ""))
                }
                .onAppear {
                    guard let playlist else {
                        return
                    }

                    self.name = playlist.name
                    self.url = playlist.url.absoluteString
                    self.actualUrl = URL(string: url)
                }
            }
        }.foregroundStyle(themeManager.selectedTheme.textColor)
    }
}

#Preview {
    AddPlaylistView()
        .environmentObject(ThemeManager())
}
