//
//  TopShelfSnapshot.swift
//  Fluxo
//
//  What the Apple TV Top Shelf shows, as the app hands it to its Top Shelf extension (FluxoTopShelf): a small JSON
//  file and finished images in the App Group container both can read. The extension never opens the SwiftData
//  store (a second process on the same SQLite file, possibly mid-migration or mid-import) and never touches the
//  network: everything it shows was decided and drawn by the app (`TopShelfPublisher`).
//
//  Nothing in it can reach a stream: channels are named by their opaque App Intents identifier
//  (`ChannelEntityID`, a keyed digest of the stream URL), never by the URL, which often carries the account's user
//  name and password. The deep links of the items carry the same identifiers.
//
//  This file is compiled into both the app and the extension (a membership exception of the FluxoTopShelf target),
//  so the format is defined once.
//

#if os(tvOS)
import Foundation

struct TopShelfSnapshot: Codable, Sendable, Equatable {

    /// Bumped when the format changes incompatibly; the extension ignores snapshots of another version (and shows
    /// the static Top Shelf image) until the app writes a new one.
    static let currentVersion = 1

    var version = Self.currentVersion
    var generatedAt: Date
    var sections: [Section]

    struct Section: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case continueWatching
            case favorites
            case onNow
        }

        var kind: Kind
        /// Localized by the app, in the language it ran in (the extension has no strings of its own).
        var title: String
        var items: [Item]
    }

    struct Item: Codable, Sendable, Equatable {
        /// Unique in the snapshot.
        var id: String
        /// The line under the image.
        var title: String
        /// File names in `TopShelfStorage.imagesDirectory`, at 1x and 2x.
        var image: String?
        var image2x: String?
        /// How far it was watched (movies and episodes), 0...1.
        var progress: Double?
        /// Pressing Play/Pause on the item.
        var playURL: URL?
        /// Selecting the item.
        var displayURL: URL?
        /// A live channel in On Now: what it shows over the next hours, so the shelf stays right after the app was
        /// closed. The extension shows the programme on air and hides the item when none is.
        var airings: [Airing]?
    }

    struct Airing: Codable, Sendable, Equatable {
        var title: String
        var start: Date
        var stop: Date

        func isOnAir(at date: Date) -> Bool {
            start <= date && date < stop
        }

        func progress(at date: Date) -> Double {
            let duration = stop.timeIntervalSince(start)
            return duration > 0 ? min(1, max(0, date.timeIntervalSince(start) / duration)) : 0
        }
    }
}

/// Where the snapshot lives: the App Group container shared by the app and the extension.
enum TopShelfStorage {

    /// The App Group of the tvOS app and its Top Shelf extension (`Fluxo-tvOS.entitlements`,
    /// `FluxoTopShelf.entitlements`).
    static let appGroupIdentifier = "group.dev.watermelon.Fluxo"

    /// `Library/Caches/TopShelf` of the group container: derived data the app writes again at every launch, so
    /// tvOS may purge it. Nil when the group is not available (the app or the extension was signed without it).
    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: "Library/Caches/TopShelf", directoryHint: .isDirectory)
    }

    static var snapshotURL: URL? {
        directory?.appending(path: "snapshot.json", directoryHint: .notDirectory)
    }

    static var imagesDirectory: URL? {
        directory?.appending(path: "Images", directoryHint: .isDirectory)
    }

    static func read() -> TopShelfSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(TopShelfSnapshot.self, from: data), snapshot.version == TopShelfSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    static func encode(_ snapshot: TopShelfSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }
}

/// The links of the Top Shelf items, opened in the app (`onOpenURL`, see `TopShelfDeepLinks`):
///
///   fluxo://play?channel=<ChannelEntity id>                     plays a channel, movie or episode
///   fluxo://play?playlist=<UUID>&series=<series key>&title=…    plays a series where the viewer left off
///   fluxo://open?playlist=<UUID>&series=<series key>&title=…    opens the page of a series
///
/// The scheme is registered in Info-tvOS.plist only: iPhone, iPad and Mac do not handle these links.
enum TopShelfLink: Equatable, Sendable {
    case playChannel(id: String)
    case playSeries(playlistID: UUID, key: String, title: String)
    case openSeries(playlistID: UUID, key: String, title: String)

    static let scheme = "fluxo"

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .playChannel(let id):
            components.host = "play"
            components.queryItems = [URLQueryItem(name: "channel", value: id)]
        case .playSeries(let playlistID, let key, let title):
            components.host = "play"
            components.queryItems = Self.seriesItems(playlistID, key, title)
        case .openSeries(let playlistID, let key, let title):
            components.host = "open"
            components.queryItems = Self.seriesItems(playlistID, key, title)
        }
        return components.url
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        switch components.host?.lowercased() {
        case "play":
            if let id = query["channel"], !id.isEmpty {
                self = .playChannel(id: id)
            } else if let (playlistID, key, title) = Self.series(query) {
                self = .playSeries(playlistID: playlistID, key: key, title: title)
            } else {
                return nil
            }
        case "open":
            guard let (playlistID, key, title) = Self.series(query) else {
                return nil
            }
            self = .openSeries(playlistID: playlistID, key: key, title: title)
        default:
            return nil
        }
    }

    private static func seriesItems(_ playlistID: UUID, _ key: String, _ title: String) -> [URLQueryItem] {
        [URLQueryItem(name: "playlist", value: playlistID.uuidString), URLQueryItem(name: "series", value: key), URLQueryItem(name: "title", value: title)]
    }

    private static func series(_ query: [String: String]) -> (UUID, String, String)? {
        guard let playlistID = query["playlist"].flatMap(UUID.init(uuidString:)), let key = query["series"], !key.isEmpty else {
            return nil
        }
        return (playlistID, key, query["title"] ?? "")
    }
}
#endif
