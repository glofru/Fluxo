//
//  ChannelEntityID.swift
//  Fluxo
//
//  The opaque identifiers of `ChannelEntity`.
//
//  A channel is identified by its bookmark key (playlist + stream URL), but the key must not leave the app:
//  the system keeps entity identifiers in Spotlight, Siri donations and Shortcuts parameters (and a shared
//  shortcut carries them), and Xtream-style stream URLs contain the account's user name and password. The
//  identifier is therefore "<playlist UUID>.<HMAC-SHA256 of the stream URL>", keyed with a random secret of this
//  installation, so it says nothing about the URL. It resolves through a cache of the keys this process handed
//  out, then the favorites and history of the playlist, then a scan of the playlist's channels.
//

import CryptoKit
import Foundation
import Synchronization
import SwiftData

enum ChannelEntityID {

    private static let secretKey = "intents.channelIdentifierSecret"

    /// Identifier → bookmark key, for every identifier made in this process (Siri resolves what it just got).
    private static let known = Mutex<[String: String]>([:])

    /// The opaque identifier of a bookmark key, or nil for a malformed key.
    static func make(forKey key: String) -> String? {
        guard let (playlistID, url) = LibraryLookup.parse(key: key) else {
            return nil
        }
        let identifier = "\(playlistID.uuidString).\(digest(url))"
        known.withLock { cache in
            if cache.count > 5_000 {
                cache.removeAll(keepingCapacity: true)
            }
            cache[identifier] = key
        }
        return identifier
    }

    /// The bookmark key an identifier stands for, when the channel is still in the library.
    static func key(for identifier: String, in container: ModelContainer) -> String? {
        if let key = known.withLock({ $0[identifier] }) {
            return key
        }
        guard let dot = identifier.firstIndex(of: "."),
              let playlistID = UUID(uuidString: String(identifier[..<dot])) else {
            return nil
        }
        let wanted = String(identifier[identifier.index(after: dot)...])
        let context = LibraryLookup.makeContext(container)

        // Favorites and history first: they are what Siri suggests and Spotlight indexes.
        let bookmarks = (try? context.fetch(FetchDescriptor<ChannelBookmark>(predicate: #Predicate { $0.playlistID == playlistID }))) ?? []
        if let bookmark = bookmarks.first(where: { digest($0.url) == wanted }) {
            return remember(identifier, ChannelBookmark.key(playlistID: playlistID, url: bookmark.url))
        }

        // Then every channel of the playlist's visible import, a page at a time.
        guard let importID = try? context.fetch(HomeQueries.playlist(uuid: playlistID)).first?.currentImportID else {
            return nil
        }
        let pageSize = 5_000
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<PlaylistChannel>(predicate: #Predicate { $0.importID == importID }, sortBy: [SortDescriptor(\.sortIndex)])
            descriptor.propertiesToFetch = [\.url]
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            let page = (try? context.fetch(descriptor)) ?? []
            if let url = page.lazy.compactMap(\.url).first(where: { digest($0) == wanted }) {
                return remember(identifier, ChannelBookmark.key(playlistID: playlistID, url: url))
            }
            guard page.count == pageSize else {
                return nil
            }
            offset += pageSize
        }
    }

    private static func remember(_ identifier: String, _ key: String) -> String {
        known.withLock { $0[identifier] = key }
        return key
    }

    /// 128 bits of HMAC-SHA256 of the URL, in hex.
    private static func digest(_ url: URL) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(url.absoluteString.utf8), using: secret)
        return code.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// A random key made once per installation (and per isolated debug store).
    private static let secret: SymmetricKey = {
        let defaults = UserDefaults.fluxo
        if let data = defaults.data(forKey: secretKey), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        defaults.set(key.withUnsafeBytes { Data($0) }, forKey: secretKey)
        return key
    }()
}
