//
//  RecommendationTypes.swift
//  Fluxo
//
//  Values shared by the recommendation engine, its views and the App Intents.
//

import CryptoKit
import Foundation

/// A channel suggested on Home ("For You"), with the reason shown under it.
struct ChannelRecommendation: Identifiable, Hashable, Sendable {
    let item: ChannelItem
    let reason: String
    /// What it shows now, when it is a live channel with a guide.
    let programme: GuideProgramme?

    var id: String {
        item.bookmarkKey ?? item.id.uuidString
    }
}

/// A programme suggested in the Guide ("For You Tonight").
struct ProgrammeRecommendation: Identifiable, Hashable, Sendable {
    let programme: GuideProgramme
    let channel: GuideChannel
    let reason: String

    var id: String {
        "\(programme.id)|\(channel.id.uuidString)"
    }
}

/// A list of suggestions and how it was made.
struct RecommendationList<Item: Hashable & Sendable>: Hashable, Sendable {
    let items: [Item]
    /// True when Apple Intelligence chose and explained the items; false for the built-in ranking.
    let isPersonalized: Bool
    let fingerprint: String
    let createdAt: Date
}

/// What a recommendation request covers: the visible imports of the playlists Home or the Guide shows.
struct RecommendationScope: Hashable, Sendable {
    let importIDs: [UUID]

    init(importIDs: [UUID]) {
        self.importIDs = importIDs
    }

    init(_ scope: LibraryScope) {
        importIDs = scope.importIDs
    }
}

/// The viewer's taste, read from the favorites and the watch history.
struct TasteProfile: Sendable {

    /// A group the viewer watches, with its weight (watch count, recency, favorites).
    struct GroupTaste: Hashable, Sendable {
        let playlistID: UUID
        let groupName: String
        let kind: ChannelContentKind
        let weight: Double
    }

    let history: [BookmarkSnapshot]
    let favorites: [BookmarkSnapshot]
    /// Heaviest first.
    let groups: [GroupTaste]
    /// Weight of each watched or favorite channel, by bookmark key.
    let channelWeights: [String: Double]

    init(history: [BookmarkSnapshot], favorites: [BookmarkSnapshot], now: Date = .now) {
        self.history = history
        self.favorites = favorites
        var groupWeights: [String: (GroupTaste, Double)] = [:]
        var channelWeights: [String: Double] = [:]
        func add(_ item: ChannelItem, weight: Double) {
            let key = "\(item.playlistID.uuidString)|\(item.groupName)"
            let taste = GroupTaste(playlistID: item.playlistID, groupName: item.groupName, kind: item.kind, weight: 0)
            groupWeights[key] = (taste, (groupWeights[key]?.1 ?? 0) + weight)
            if let bookmarkKey = item.bookmarkKey {
                channelWeights[bookmarkKey, default: 0] += weight
            }
        }
        for entry in history {
            let days = entry.lastWatchedAt.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 30
            // Watched often and recently counts most; a channel watched once a month ago counts little.
            let weight = (1 + log(1 + Double(entry.watchCount))) * exp(-days / 14)
            add(entry.item, weight: weight)
        }
        for entry in favorites {
            add(entry.item, weight: 1.5)
        }
        groups = groupWeights.values
            .map { GroupTaste(playlistID: $0.0.playlistID, groupName: $0.0.groupName, kind: $0.0.kind, weight: $0.1) }
            .sorted { $0.weight > $1.weight }
        self.channelWeights = channelWeights
    }

    var isEmpty: Bool {
        history.isEmpty && favorites.isEmpty
    }

    /// The group weight relative to the heaviest group (0...1).
    func groupScore(playlistID: UUID, groupName: String) -> Double {
        guard let top = groups.first?.weight, top > 0 else {
            return 0
        }
        let weight = groups.first { $0.playlistID == playlistID && $0.groupName == groupName }?.weight ?? 0
        return weight / top
    }

    /// Identifies the taste for caching: the channels that weigh most (as a set: watching them again in another order
    /// changes nothing), the favorites and the categories watched most. A model run is worth it only when one of these
    /// changes, not after every channel watched once more.
    ///
    /// The value is persisted with the stored picks, so it must be the same in every process: a SHA-256 digest,
    /// never `Hasher` or `hashValue` (both are seeded randomly per launch).
    var fingerprint: String {
        let heaviest = channelWeights
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(Self.fingerprintChannels)
            .map(\.key)
            .sorted()
        let favorite = favorites.compactMap(\.item.bookmarkKey).sorted()
        let topGroups = groups.prefix(Self.fingerprintGroups).map { "\($0.playlistID.uuidString)|\($0.groupName)" }.sorted()
        // A newline cannot appear in a bookmark key (playlist UUID and stream URL), so it separates them safely.
        let text = heaviest.joined(separator: "\n") + "\n--\n" + favorite.joined(separator: "\n") + "\n--\n" + topGroups.joined(separator: "\n")
        return Self.stableDigest(text)
    }

    /// The channels and categories `fingerprint` reads.
    static let fingerprintChannels = 8
    static let fingerprintGroups = 3

    /// A short hex digest of `text` that is identical across launches and devices.
    static func stableDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Short, readable time context for the model and the cache ("Friday evening, 21:10").
enum ViewingMoment {

    enum Part: String, Sendable {
        case morning
        case afternoon
        case evening
        case night
    }

    static func part(of date: Date, calendar: Calendar = .current) -> Part {
        switch calendar.component(.hour, from: date) {
        case 5..<12:
            return .morning
        case 12..<18:
            return .afternoon
        case 18..<23:
            return .evening
        default:
            return .night
        }
    }

    /// For the prompts: always in English (the instructions are English), e.g. "Friday evening, 21:10".
    static func description(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEEE"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH:mm"
        return "\(day) \(part(of: date, calendar: calendar).rawValue), \(formatter.string(from: date))"
    }

    /// Changes every few hours (and with the day), so suggestions follow the time of day without being
    /// recomputed on every visit.
    static func bucket(of date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)-\((components.hour ?? 0) / 3)"
    }
}
