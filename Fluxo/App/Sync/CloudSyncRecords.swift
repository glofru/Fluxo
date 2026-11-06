//
//  CloudSyncRecords.swift
//  Fluxo
//
//  The values iCloud sync exchanges between devices: one record per playlist, guide source, favorite, watch
//  progress and setting. Plain values (Foundation only), so `Tools/SyncCheck` can compile and test them without the
//  app. See "iCloud sync" in the README.
//

import CryptoKit
import Foundation

/// What a record describes. The raw value prefixes the CloudKit record name; `recordType` is the CloudKit type.
enum SyncKind: String, Codable, CaseIterable, Sendable {
    case playlist = "pl"
    case guideSource = "gs"
    case channelFavorite = "cf"
    case channelProgress = "cp"
    case seriesFavorite = "sf"
    case seriesProgress = "sp"
    case preference = "pr"

    var recordType: String {
        switch self {
        case .playlist: "Playlist"
        case .guideSource: "GuideSource"
        case .channelFavorite: "ChannelFavorite"
        case .channelProgress: "ChannelProgress"
        case .seriesFavorite: "SeriesFavorite"
        case .seriesProgress: "SeriesProgress"
        case .preference: "Preference"
        }
    }

    /// The order changes are applied in: a favorite needs its playlist on the device first.
    var applyOrder: Int {
        switch self {
        case .playlist: 0
        case .guideSource: 1
        case .preference: 2
        case .channelFavorite, .channelProgress: 3
        case .seriesFavorite, .seriesProgress: 4
        }
    }
}

/// Identity of a record on every device. `name` never contains a stream address: favorites and progress are named
/// by a hash (`SyncIdentity`), since CloudKit record names are not encrypted.
struct SyncRecordID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let kind: SyncKind
    let name: String

    init(_ kind: SyncKind, _ name: String) {
        self.kind = kind
        self.name = name
    }

    /// "<kind>.<name>", the CloudKit record name (at most 255 ASCII characters).
    init?(recordName: String) {
        guard let dot = recordName.firstIndex(of: "."), let kind = SyncKind(rawValue: String(recordName[..<dot])) else {
            return nil
        }
        let name = String(recordName[recordName.index(after: dot)...])
        guard !name.isEmpty else {
            return nil
        }
        self.init(kind, name)
    }

    var recordName: String {
        "\(kind.rawValue).\(name)"
    }

    var description: String {
        recordName
    }

    static func < (lhs: SyncRecordID, rhs: SyncRecordID) -> Bool {
        (lhs.kind.applyOrder, lhs.recordName) < (rhs.kind.applyOrder, rhs.recordName)
    }
}

// MARK: - Payloads

/// A playlist as the user defined it: what another device needs to download it.
struct PlaylistPayload: Codable, Hashable, Sendable {
    var name: String
    var url: URL
    var createdOn: Date
}

/// A TV guide the user added (guides listed by a playlist header follow the playlist and are not synced).
struct GuideSourcePayload: Codable, Hashable, Sendable {
    var name: String
    var url: URL
    var isEnabled: Bool
    var addedOn: Date
}

/// The series an episode belongs to (`EpisodeRef`).
struct EpisodeSnapshot: Codable, Hashable, Sendable {
    var seriesKey: String
    var seriesTitle: String
    var season: Int?
    var episode: Int
    var episodeTitle: String?
}

/// Enough of a channel to show and play it before its playlist was read again (`ChannelBookmark`'s snapshot).
struct ChannelSnapshot: Codable, Hashable, Sendable {
    /// `SyncRecordID.name` of the playlist record.
    var playlist: String
    var url: URL
    var name: String?
    var logo: String?
    var groupName: String
    var kind: Int
    var tvgID: String?
    var episode: EpisodeSnapshot?
}

struct ChannelFavoritePayload: Codable, Hashable, Sendable {
    var channel: ChannelSnapshot
    var favoritedOn: Date?
    var order: Double
}

struct ChannelProgressPayload: Codable, Hashable, Sendable {
    var channel: ChannelSnapshot
    var lastWatchedAt: Date?
    var watchCount: Int
    /// Seconds; 0 when not started or watched to the end.
    var resumePosition: Double
    var knownDuration: Double
}

struct SeriesSnapshot: Codable, Hashable, Sendable {
    var playlist: String
    var seriesKey: String
    var title: String
    var artwork: String?
    var groupName: String
}

struct SeriesFavoritePayload: Codable, Hashable, Sendable {
    var series: SeriesSnapshot
    var favoritedOn: Date?
    var order: Double
}

struct SeriesProgressPayload: Codable, Hashable, Sendable {
    var series: SeriesSnapshot
    var lastWatchedAt: Date?
    var lastEpisodeURL: URL?
    var lastSeason: Int?
    var lastEpisode: Int?
    /// `EpisodeCode` raw values, sorted.
    var watchedEpisodeCodes: [String]
}

// Favorites and progress compare by what the user did, not by the channel's name, logo or group: those come from
// the playlist and change with its refreshes, on each device at its own time. A cosmetic difference is therefore no
// change to sync (the newest one travels with the next real change).

extension ChannelFavoritePayload {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channel.playlist == rhs.channel.playlist && lhs.channel.url == rhs.channel.url
            && lhs.favoritedOn == rhs.favoritedOn && lhs.order == rhs.order
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(channel.playlist)
        hasher.combine(channel.url)
        hasher.combine(favoritedOn)
        hasher.combine(order)
    }
}

extension ChannelProgressPayload {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channel.playlist == rhs.channel.playlist && lhs.channel.url == rhs.channel.url
            && lhs.lastWatchedAt == rhs.lastWatchedAt && lhs.watchCount == rhs.watchCount
            && lhs.resumePosition == rhs.resumePosition && lhs.knownDuration == rhs.knownDuration
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(channel.playlist)
        hasher.combine(channel.url)
        hasher.combine(lastWatchedAt)
        hasher.combine(resumePosition)
    }
}

extension SeriesFavoritePayload {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.series.playlist == rhs.series.playlist && lhs.series.seriesKey == rhs.series.seriesKey
            && lhs.favoritedOn == rhs.favoritedOn && lhs.order == rhs.order
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(series.playlist)
        hasher.combine(series.seriesKey)
        hasher.combine(favoritedOn)
        hasher.combine(order)
    }
}

extension SeriesProgressPayload {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.series.playlist == rhs.series.playlist && lhs.series.seriesKey == rhs.series.seriesKey
            && lhs.lastWatchedAt == rhs.lastWatchedAt && lhs.lastEpisodeURL == rhs.lastEpisodeURL
            && lhs.lastSeason == rhs.lastSeason && lhs.lastEpisode == rhs.lastEpisode
            && lhs.watchedEpisodeCodes == rhs.watchedEpisodeCodes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(series.playlist)
        hasher.combine(series.seriesKey)
        hasher.combine(lastWatchedAt)
        hasher.combine(watchedEpisodeCodes)
    }
}

/// A setting (`UserDefaults.fluxo`), one of the property list types the app stores.
enum PreferenceValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)
}

/// What a record holds. A record without a payload is a deletion (a playlist or guide removed, a favorite removed,
/// an item cleared from the history, a setting back to its default): it is kept, so a device that was offline learns
/// of it and an older change from another device cannot bring the item back.
enum SyncPayload: Codable, Hashable, Sendable {
    case playlist(PlaylistPayload)
    case guideSource(GuideSourcePayload)
    case channelFavorite(ChannelFavoritePayload)
    case channelProgress(ChannelProgressPayload)
    case seriesFavorite(SeriesFavoritePayload)
    case seriesProgress(SeriesProgressPayload)
    case preference(PreferenceValue)

    var kind: SyncKind {
        switch self {
        case .playlist: .playlist
        case .guideSource: .guideSource
        case .channelFavorite: .channelFavorite
        case .channelProgress: .channelProgress
        case .seriesFavorite: .seriesFavorite
        case .seriesProgress: .seriesProgress
        case .preference: .preference
        }
    }

    /// The playlist record a favorite or progress belongs to.
    var playlistName: String? {
        switch self {
        case .channelFavorite(let value): value.channel.playlist
        case .channelProgress(let value): value.channel.playlist
        case .seriesFavorite(let value): value.series.playlist
        case .seriesProgress(let value): value.series.playlist
        case .playlist, .guideSource, .preference: nil
        }
    }
}

// MARK: - Records

/// One synced item with the time it was last changed and the device that changed it.
///
/// Conflicts are resolved per record, last writer wins: the later `modifiedAt` (the device clocks are set by the
/// network), then the larger `deviceID` so that every device picks the same winner. Favorites and watch progress are
/// separate records, so a favorite added on the iPhone and a movie watched on the Apple TV at the same time both
/// survive.
struct SyncRecord: Codable, Hashable, Sendable {
    let id: SyncRecordID
    /// nil: deleted (see `SyncPayload`).
    var payload: SyncPayload?
    var modifiedAt: Date
    var deviceID: String

    var isDeletion: Bool {
        payload == nil
    }

    func supersedes(_ other: SyncRecord) -> Bool {
        if modifiedAt != other.modifiedAt {
            return modifiedAt > other.modifiedAt
        }
        return deviceID > other.deviceID
    }

    /// The JSON that CloudKit stores, encrypted (`CKRecord.encryptedValues`).
    func encodedPayload() throws -> Data {
        try SyncCoding.encoder.encode(payload)
    }

    static func decodePayload(_ data: Data) throws -> SyncPayload? {
        try SyncCoding.decoder.decode(SyncPayload?.self, from: data)
    }
}

enum SyncCoding {
    /// Dates are whole milliseconds since 1970 (`Date.syncRounded`), so a value read back from the cloud or the
    /// ledger is equal to the one the device compared.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.syncMilliseconds)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(syncMilliseconds: try container.decode(Int64.self))
        }
        return decoder
    }()
}

extension Date {
    var syncMilliseconds: Int64 {
        let milliseconds = (timeIntervalSince1970 * 1_000).rounded()
        return milliseconds.isFinite ? Int64(max(-8.6e15, min(8.6e15, milliseconds))) : 0
    }

    init(syncMilliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(syncMilliseconds) / 1_000)
    }

    /// The date as sync stores it (whole milliseconds).
    var syncRounded: Date {
        Date(syncMilliseconds: syncMilliseconds)
    }
}

// MARK: - Identity

/// Record names. Playlists and guides are named after their address the first time they are synced, so the same
/// playlist added on two devices before sync was on becomes one record; the name then stays when the address is
/// edited (`SyncLinks`). Favorites and progress are named after their playlist record and stream address, hashed.
enum SyncIdentity {
    static func playlistName(for url: URL) -> String {
        "u" + digest(normalized(url))
    }

    static func guideSourceName(for url: URL) -> String {
        "u" + digest(normalized(url))
    }

    /// A playlist whose address another playlist of the device already uses.
    static func playlistName(forLocalID id: UUID) -> String {
        "l" + id.uuidString.lowercased()
    }

    static func channelName(playlist: String, url: URL) -> String {
        digest("\(playlist)|\(url.absoluteString)")
    }

    static func seriesName(playlist: String, seriesKey: String) -> String {
        digest("\(playlist)|\(seriesKey)")
    }

    /// A watched channel or episode of this device (by local playlist and stream address), for the history the user
    /// removes (`SyncDeletionJournal.noteHistoryRemoved`): the library does not know the playlist's record name, the
    /// reconciler finds it through the links. A hash, so the defaults hold no address.
    static func localHistoryKey(playlistID: UUID, url: URL) -> String {
        "c" + digest("\(playlistID.uuidString)|\(url.absoluteString)")
    }

    /// The watch state of a series of this device (by local playlist and series key), for the same journal.
    static func localHistoryKey(playlistID: UUID, seriesKey: String) -> String {
        "s" + digest("\(playlistID.uuidString)|\(seriesKey)")
    }

    /// The scheme and host are case-insensitive; the path and query (which carry the account) are kept as they are.
    static func normalized(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return (components.string ?? url.absoluteString).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 128 bits of SHA-256, hex: short record names that do not reveal the address.
    private static func digest(_ text: String) -> String {
        let hex = Array("0123456789abcdef")
        var result = ""
        for byte in SHA256.hash(data: Data(text.utf8)).prefix(16) {
            result.append(hex[Int(byte >> 4)])
            result.append(hex[Int(byte & 0x0F)])
        }
        return result
    }
}

/// Which local playlist and guide source each synced record stands for, on this device. Local IDs differ between
/// devices (each device creates its own rows); the record names are shared.
struct SyncLinks: Codable, Hashable, Sendable {
    var playlists: [String: UUID] = [:]
    var guideSources: [String: UUID] = [:]

    func playlistName(forLocalID id: UUID) -> String? {
        playlists.first { $0.value == id }?.key
    }

    func guideSourceName(forLocalID id: UUID) -> String? {
        guideSources.first { $0.value == id }?.key
    }
}
