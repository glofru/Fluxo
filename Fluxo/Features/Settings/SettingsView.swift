//
//  SettingsView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-06.
//

import SwiftUI

struct SettingsView: View {

    @StateObject private var viewModel = SettingsViewModel()

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
        }
    }
}

#Preview {
    SettingsView()
}
