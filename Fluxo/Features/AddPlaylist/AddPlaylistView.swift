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
        get {
            !url.isEmpty && actualUrl == nil
        }
    }
    
    @FocusState private var focusField: Field?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(themeManager.selectedTheme.backgroundColor)
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
                    
                    if (showUrlError) {
                        Text("Invalid URL")
                            .bold()
                            .underline(color: themeManager.selectedTheme.errorTextColor)
                    }
                    
                    Button(action: {}) {
                        Text("Add playlist")
                    }
                    .buttonStyle(.borderedProminent)
                    
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
                        }) {
                            Text("Cancel")
                        }
                    }
                }
                .toolbarBackground(themeManager.selectedTheme.backgroundColor.opacity(0.8), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)

            }
        }.foregroundStyle(themeManager.selectedTheme.textColor)
    }
}

#Preview {
    AddPlaylistView()
        .environmentObject(ThemeManager())
}
