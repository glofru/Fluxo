//
//  SettingsView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-06.
//

import SwiftUI

struct SettingsView: View {

    @State private var viewModel = SettingsViewModel()

    var body: some View {
        Form {
            Section("Cache") {
                Text("Size: \(viewModel.appFolderSize)")

                Button(role: .destructive) {
                    viewModel.deleteAllDataInAppDirectory()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            Section("Channel logos") {
                Text("Size: \(Int64(viewModel.logoCacheSize).formatted(.byteCount(style: .file)))")

                Button(role: .destructive) {
                    viewModel.clearLogoCache()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
        }
        .task {
            await viewModel.refresh()
        }
    }
}

#Preview {
    SettingsView()
}
