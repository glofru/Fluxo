//
//  AddPlaylistView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-03.
//

import SwiftUI

struct AddPlaylistView: View {

    private enum Field {
        case name
        case url
    }

    @EnvironmentObject private var themeManager: ThemeManager

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var actualUrl: URL?
    var showUrlError: Bool {
        !url.isEmpty && actualUrl == nil
    }

    @FocusState private var focusField: Field?
    @Environment(\.dismiss) private var dismiss

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

                    FluxoTextField("URL", text: .init(get: { url }, set: { url = $0; actualUrl = URL(string: $0) }), placeholder: "http://myplaylist.com/playlist.m3u", error: showUrlError ? "InvalidURL" : nil)
                        .focused($focusField, equals: .url)
                        .textContentType(.URL)
                        .keyboardType(.URL)

                    if showUrlError {
                        Text("Invalid URL")
                            .bold()
                            .underline(color: themeManager.selectedTheme.errorTextColor)
                    }

                    FluxoButton(label: "Add playlist") {
                        print("add playlist")
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
            }
        }.foregroundStyle(themeManager.selectedTheme.textColor)
    }
}

#Preview {
    AddPlaylistView()
        .environmentObject(ThemeManager())
}
