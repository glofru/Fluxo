//
//  ChannelPreview.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-04.
//

import SwiftUI

struct ChannelPreview: View {

    let channel: PlaylistChannel
    let onClick: () -> Void

    init(channel: PlaylistChannel, onClick: @escaping () -> Void) {
        self.channel = channel
        self.onClick = onClick
    }

    private let borderShape = RoundedRectangle(cornerSize: .init(width: 10, height: 10))

    var body: some View {
        VStack(alignment: .leading) {
            Button(action: {
                onClick()
            }, label: {
                ZStack {
                    ChannelArtwork(
                        logo: channel.logo,
                        name: channel.name ?? "No channel name",
                        isLiveContent: channel.isLiveContent
                    )
                }
                .frame(width: channel.isLiveContent ? 250 : 180, height: channel.isLiveContent ? 150 : 266)
                .background(Color.artworkPlaceholder)
                .clipShape(borderShape)
            })

            Text(channel.name ?? "")
                .bold()
                .lineLimit(2, reservesSpace: true)
        }
        .frame(width: channel.isLiveContent ? 250 : 180)
        .padding()
        .contextMenuPreviewShape(borderShape)
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

/// Logo of a live channel (fitted, centered) or poster of an on-demand item (filling the card).
/// Decoded at the displayed size by the shared logo loader.
private struct ChannelArtwork: View {

    static let liveLogoSize = CGSize(width: 75, height: 75)
    static let posterSize = CGSize(width: 180, height: 266)

    let logo: String?
    let name: String
    let isLiveContent: Bool

    var body: some View {
        LogoImage(
            source: logo,
            size: isLiveContent ? Self.liveLogoSize : Self.posterSize,
            contentMode: isLiveContent ? .fit : .fill,
            accessibilityLabel: name
        ) { phase in
            switch phase {
            case .loading:
                ProgressView()
            case .unavailable:
                Text("No image preview")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

#Preview {
    ScrollView {
        VStack {
            ChannelPreview(channel: PlaylistChannel(uuid: UUID(), name: "Channel name", logo: "https://i.imgur.com/Vx1F4o5.png", url: URL(string: "https://test.com/1234"), playlistID: UUID())) {}
            ChannelPreview(channel: PlaylistChannel(uuid: UUID(), name: "Channel name", logo: "invalid", url: URL(string: "https://test.com/1234"), playlistID: UUID())) {}
            ChannelPreview(channel: PlaylistChannel(uuid: UUID(), name: "Channel name with very long long long name like crazy long", logo: "https://image.tmdb.org/t/p/w600_and_h900_bestv2/6JVhFwg6lhnmjLndT18idG7rwwg.jpg", url: URL(string: "https://test.com/1234.mp4"), playlistID: UUID())) {}
            ChannelPreview(channel: PlaylistChannel(uuid: UUID(), name: "Channel name with very long long long name like crazy long", logo: "invalid", url: URL(string: "https://test.com/1234.mp4"), playlistID: UUID())) {}
        }
    }
}
