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

    var showUrlError: Bool {
        !url.isEmpty && actualUrl == nil
    }

    @FocusState private var focusField: Field?

    var body: some View {
        NavigationView {
            ZStack {
                Color(themeManager.selectedTheme.primary)
                    .ignoresSafeArea(.all)

                VStack(alignment: .center) {
                    Text("Support M3U playlists")

                    FluxoTextField("Name", text: $name, placeholder: "optional")
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
                        .disabled(loading)

                    if showUrlError {
                        Text("Invalid URL")
                            .bold()
                            .underline(color: themeManager.selectedTheme.errorTextColor)
                    }

                    FluxoButton(label: "Add playlist", loading: loading) {
                        guard let actualUrl else {
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
                    .disabled(loading)

                    if let progress = viewModel.progress {
                        ProgressView(progress.message, value: progress.percentage, total: 1)
                            .progressViewStyle(.linear)
                            .tint(themeManager.selectedTheme.accentPrimary)
                    }

                    Spacer()
                }
                .textFieldStyle(.roundedBorder)
                .padding()
                .navigationTitle("Add playlist")
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
            }
        }.foregroundStyle(themeManager.selectedTheme.textColor)
    }
}

#Preview {
    AddPlaylistView()
        .environmentObject(ThemeManager())
}
