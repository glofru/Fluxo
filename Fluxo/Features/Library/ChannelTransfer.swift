//
//  ChannelTransfer.swift
//  Fluxo
//
//  Drag and drop of channels (iPad, macOS): a channel card or row can be dragged onto the Favorites tab (the iPad
//  sidebar or the tab bar), the Favorites row of Home or the Favorites screen, which adds it to the favorites.
//  Other apps only receive the channel's name as text: the full channel, with its stream URL (which can embed
//  account credentials), never leaves the app.
//

import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A channel dragged within Fluxo (declared in Info.plist under `UTExportedTypeDeclarations`).
    static let fluxoChannel = UTType(exportedAs: "dev.watermelon.Fluxo.channel")
}

/// A channel being dragged.
struct ChannelTransfer: Codable, Hashable, Sendable, Transferable {
    let id: UUID
    let playlistID: UUID
    let name: String?
    let logo: String?
    let url: URL?
    let groupName: String
    let kindRawValue: Int
    let tvgID: String?
    let number: Int?

    init(_ item: ChannelItem) {
        id = item.id
        playlistID = item.playlistID
        name = item.name
        logo = item.logo
        url = item.url
        groupName = item.groupName
        kindRawValue = item.kind.rawValue
        tvgID = item.tvgID
        number = item.number
    }

    var item: ChannelItem {
        ChannelItem(
            id: id,
            playlistID: playlistID,
            name: name,
            logo: logo,
            url: url,
            groupName: groupName,
            kind: ChannelContentKind(rawValue: kindRawValue) ?? .live,
            tvgID: tvgID,
            number: number
        )
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .fluxoChannel)
            .visibility(.ownProcess)
        ProxyRepresentation(exporting: \.displayName)
    }

    private var displayName: String {
        item.displayName
    }
}

extension View {
    /// Lets the channel be dragged on iPad and macOS, with its artwork as the preview. Not on iPhone: there a long
    /// press opens the context menu, and moving the finger would turn it into a drag.
    @ViewBuilder
    func channelDraggable(_ item: ChannelItem) -> some View {
        #if os(iOS)
        if DeviceIdiom.isPad {
            draggable(ChannelTransfer(item)) {
                ChannelDragPreview(item: item)
            }
        } else {
            self
        }
        #else
        draggable(ChannelTransfer(item)) {
            ChannelDragPreview(item: item)
        }
        #endif
    }

    /// Adds the channels dropped on this view to the favorites. `isTargeted` reports a drag hovering over it.
    func favoritesDropDestination(library: ChannelLibrary, isTargeted: Binding<Bool>? = nil) -> some View {
        dropDestination(for: ChannelTransfer.self) { channels, _ in
            ChannelTransfer.addToFavorites(channels, library: library)
        } isTargeted: { targeted in
            isTargeted?.wrappedValue = targeted
        }
    }
}

extension ChannelTransfer {
    /// Adds the dropped channels to the favorites; false when none could be added (no stream URL).
    @MainActor
    @discardableResult
    static func addToFavorites(_ channels: [ChannelTransfer], library: ChannelLibrary) -> Bool {
        let items = channels.map(\.item).filter { $0.url != nil }
        for item in items where !library.isFavorite(item) {
            library.toggleFavorite(item)
        }
        return !items.isEmpty
    }
}

/// The preview under the finger or pointer while a channel is dragged.
private struct ChannelDragPreview: View {
    let item: ChannelItem

    var body: some View {
        HStack(spacing: 10) {
            ChannelLogoTile(item: item, size: CGSize(width: 54, height: 36), cornerRadius: 8)
            Text(item.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(8)
        .padding(.trailing, 6)
        .background(.regularMaterial, in: .capsule)
    }
}

#Preview {
    ChannelDragPreview(item: PreviewSampleData.sampleItems[0])
        .padding()
}
