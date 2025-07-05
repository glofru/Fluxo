//
//  ChannelPreview.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-04.
//

import SwiftUI

struct ChannelPreview: View {

    let channel: PlaylistChannel

    @EnvironmentObject private var themeManager: ThemeManager

    private let borderShape = RoundedRectangle(cornerSize: .init(width: 10, height: 10))

    var body: some View {
        VStack(alignment: .leading) {
            Button(action: {
                print("\(channel.name): \(channel.logo)")
            }, label: {
                ZStack {
                    Group {
                        if let logo = channel.logo, let logoUrl = URL(string: logo) {
                            ChannelPreviewImage(url: logoUrl, name: channel.name ?? "No channel name", isLiveContent: channel.isLiveContent)
                        } else {
                            Text("No image preview")
                        }
                    }
                }
                .frame(width: channel.isLiveContent ? 250 : 180, height: channel.isLiveContent ? 150 : 266)
                .background(themeManager.selectedTheme.primary.opacity(0.8))
                .clipShape(borderShape)
            })

            Text(channel.name ?? "")
                .bold()
                .lineLimit(2, reservesSpace: true)
        }
        .frame(width: channel.isLiveContent ? 250 : 180)
        .padding()
        .contentShape(.contextMenuPreview, borderShape)
        .contextMenu {
            Text(channel.name ?? "No channel name")
                .bold()

            Button(action: {
                print("Add to favorites")
            }, label: {
                Text("Add to favorites")
            })
        }
    }
}

private struct ChannelPreviewImage: View {

    let url: URL
    let name: String
    let isLiveContent: Bool

    var body: some View {
        Group {
            if url.absoluteString.hasPrefix("data:image") == true, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .if(isLiveContent) { image in
                        image.scaledToFit()
                    }
                    .if(!isLiveContent) { image in
                        image.scaledToFill()
                    }
                    .accessibilityLabel(Text(name))
                    .frame(width: isLiveContent ? 75 : nil, height: isLiveContent ? 75 : nil)
            } else {
                AsyncImage(url: url) { result in
                    if result.error == nil {
                        if let image = result.image {
                            image
                                .resizable()
                                .if(isLiveContent) { image in
                                    image.scaledToFit()
                                }
                                .if(!isLiveContent) { image in
                                    image.scaledToFill()
                                }
                                .frame(width: isLiveContent ? 75 : nil, height: isLiveContent ? 75 : nil)
                        } else {
                            ProgressView()
                        }
                    } else {
                        Text("No image preview")
                    }
                }
            }
        }
    }
}

#Preview {
    ScrollView {
        VStack {
            ChannelPreview(channel: PlaylistChannel(uuid: UUID(), name: "Channel name", logo: "https://i.imgur.com/Vx1F4o5.png", url: URL(string: "https://test.com/1234"), playlist: .init(uuid: UUID(), name: "Test", url: .applicationDirectory, createdOn: .init(timeIntervalSince1970: 0))))
            ChannelPreview(channel: PlaylistChannel(uuid: UUID(), name: "Channel name", logo: "invalid", url: URL(string: "https://test.com/1234"), playlist: .init(uuid: UUID(), name: "Test", url: .applicationDirectory, createdOn: .init(timeIntervalSince1970: 0))))
            ChannelPreview(channel: PlaylistChannel(uuid: UUID(), name: "Channel name with very long long long name like crazy long", logo: "https://image.tmdb.org/t/p/w600_and_h900_bestv2/6JVhFwg6lhnmjLndT18idG7rwwg.jpg", url: URL(string: "https://test.com/1234.mp4"), playlist: .init(uuid: UUID(), name: "Test", url: .applicationDirectory, createdOn: .init(timeIntervalSince1970: 0))))
            ChannelPreview(channel: PlaylistChannel(uuid: UUID(), name: "Channel name with very long long long name like crazy long", logo: "invalid", url: URL(string: "https://test.com/1234.mp4"), playlist: .init(uuid: UUID(), name: "Test", url: .applicationDirectory, createdOn: .init(timeIntervalSince1970: 0))))
        }
    }
    .environmentObject(ThemeManager())
}
