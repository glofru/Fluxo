//
//  ContentView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-05-31.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var viewModel = AVPlayerViewModel()

    var body: some View {
        TabView {
            Tab("Watch", systemImage: "play.tv") {
                WatchView(viewModel: viewModel)
            }

            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }

            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                List(0..<100) { i in
                    Text("Row \(i)")
                }
                .searchable(text: .init(get: { "test" }, set: { _ in }))
            }
        }
        .playerAccessory(isVisible: viewModel.currentChannel != nil) {
            PlayerBottomAccessory(viewModel: viewModel)
        }
        .playerPresentation(isPresented: $viewModel.isPresented) {
            WatchChannelView(viewModel: viewModel)
        }
    }
}

struct PlayerBottomAccessory: View {
    @ObservedObject var viewModel: AVPlayerViewModel

    var body: some View {
        if let channel = viewModel.currentChannel {
            HStack {
                if let logo = channel.logo, let url = URL(string: logo) {
                    if let image = Image(dataURL: url) {
                        image
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerSize: .init(width: 6, height: 6)))
                            .padding(.leading, 16)
                            .padding(.trailing, 6)
                            .padding(.vertical, 6)
                            .accessibilityLabel(Text(channel.name ?? "No channel name"))
                    } else {
                        AsyncImage(url: url) { result in
                            if result.error != nil {
                                EmptyView()
                            } else if let image = result.image {
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .clipShape(RoundedRectangle(cornerSize: .init(width: 6, height: 6)))
                                        .padding(.leading, 16)
                                        .padding(.trailing, 6)
                                        .padding(.vertical, 6)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                } else {
                    EmptyView()
                }

                Text(channel.name ?? "No channel name")
                    .bold()

                Spacer()
            }
            .ignoresSafeArea(.all)
            .onTapGesture {
                viewModel.isPresented = true
            }
        } else {
            EmptyView()
        }
    }
}

#Preview {
    ContentView()
}
