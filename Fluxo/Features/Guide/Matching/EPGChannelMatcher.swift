//
//  EPGChannelMatcher.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation

/// The guide channels of the enabled sources, indexed for matching playlist channels.
///
/// A channel is matched, in order, by:
/// 1. the user's manual choice (`EPGChannelOverride`), including "no guide";
/// 2. its `tvg-id` against the XMLTV channel ids (case-insensitive, with or without a "@feed" suffix);
/// 3. its normalized name against the normalized `<display-name>`s (`ChannelNameNormalizer.key`);
/// 4. its `tvg-id` read as a name, and the loose name key ("Rai Uno" = "Rai 1").
///
/// Sources are tried in priority order for each step: the guides of the channel's own playlist first, then the
/// guides the user added, then the guides of other playlists.
struct EPGChannelMatcher: Sendable {

    /// What the matcher needs to know about one XMLTV channel.
    struct Channel: Sendable {
        let channelID: String
        let names: [String]
    }

    struct Source: Sendable {
        let sourceID: UUID
        let importID: UUID
        let playlistID: UUID?
    }

    enum Override: Sendable, Equatable {
        case channel(GuideChannelRef)
        case none
    }

    private struct SourceIndex: Sendable {
        let source: Source
        var ids: [String: String] = [:]
        var names: [String: String] = [:]
        var looseNames: [String: String] = [:]
    }

    private let indexes: [SourceIndex]
    private let overrides: [String: Override]

    static let empty = EPGChannelMatcher(sources: [], overrides: [:])

    var isEmpty: Bool {
        indexes.isEmpty
    }

    init(sources: [(Source, [Channel])], overrides: [String: Override]) {
        self.overrides = overrides
        indexes = sources.map { source, channels in
            var index = SourceIndex(source: source)
            index.ids.reserveCapacity(channels.count * 2)
            index.names.reserveCapacity(channels.count * 2)
            for channel in channels {
                for key in ChannelNameNormalizer.idKeys(channel.channelID) where index.ids[key] == nil {
                    index.ids[key] = channel.channelID
                }
                // Explicit display names first, then the name hidden in the id.
                for name in channel.names + [ChannelNameNormalizer.nameFromID(channel.channelID)] {
                    let keys = ChannelNameNormalizer.keys(name)
                    if !keys.strict.isEmpty, index.names[keys.strict] == nil {
                        index.names[keys.strict] = channel.channelID
                    }
                    if !keys.loose.isEmpty, index.looseNames[keys.loose] == nil {
                        index.looseNames[keys.loose] = channel.channelID
                    }
                }
            }
            return index
        }
    }

    /// The guide channel of a playlist channel, or nil when it has none.
    func match(_ item: ChannelItem) -> GuideChannelRef? {
        if let key = item.bookmarkKey, let override = overrides[key] {
            switch override {
            case .channel(let ref):
                // The override names a source; follow it to the source's current import.
                if let index = indexes.first(where: { $0.source.sourceID == ref.sourceID }) {
                    return GuideChannelRef(sourceID: ref.sourceID, importID: index.source.importID, channelID: ref.channelID)
                }
                return nil
            case .none:
                return nil
            }
        }
        return automaticMatch(tvgID: item.tvgID, name: item.name, playlistID: item.playlistID)
    }

    func automaticMatch(tvgID: String?, name: String?, playlistID: UUID) -> GuideChannelRef? {
        guard !indexes.isEmpty else {
            return nil
        }
        let ordered = orderedIndexes(for: playlistID)
        let idKeys = tvgID.map(ChannelNameNormalizer.idKeys) ?? []
        for key in idKeys {
            for index in ordered {
                if let channelID = index.ids[key] {
                    return ref(index, channelID)
                }
            }
        }

        let nameKeys = name.map(ChannelNameNormalizer.keys)
        if let strict = nameKeys?.strict, !strict.isEmpty {
            for index in ordered {
                if let channelID = index.names[strict] {
                    return ref(index, channelID)
                }
            }
        }

        // Some playlists put a name in tvg-id ("Sky Sport F1") or an id that differs only by its suffix.
        let idNameKeys = tvgID.map { ChannelNameNormalizer.keys(ChannelNameNormalizer.nameFromID($0)) }
        if let strict = idNameKeys?.strict, !strict.isEmpty {
            for index in ordered {
                if let channelID = index.names[strict] {
                    return ref(index, channelID)
                }
            }
        }

        for loose in [nameKeys?.loose, idNameKeys?.loose].compactMap({ $0 }) where !loose.isEmpty {
            for index in ordered {
                if let channelID = index.looseNames[loose] {
                    return ref(index, channelID)
                }
            }
        }
        return nil
    }

    private func ref(_ index: SourceIndex, _ channelID: String) -> GuideChannelRef {
        GuideChannelRef(sourceID: index.source.sourceID, importID: index.source.importID, channelID: channelID)
    }

    private func orderedIndexes(for playlistID: UUID) -> [SourceIndex] {
        guard indexes.count > 1 else {
            return indexes
        }
        return indexes.sorted { lhs, rhs in
            rank(lhs.source, playlistID) < rank(rhs.source, playlistID)
        }
    }

    private func rank(_ source: Source, _ playlistID: UUID) -> Int {
        if source.playlistID == playlistID {
            return 0
        }
        return source.playlistID == nil ? 1 : 2
    }
}

/// The playlist channels a guide download should keep programmes for, so that a guide of thousands of channels
/// only stores the few hundred the user can actually watch.
struct EPGWantedChannels: Sendable {
    private(set) var ids: Set<String> = []
    private(set) var names: Set<String> = []
    private(set) var looseNames: Set<String> = []
    /// XMLTV channel ids picked by hand (`EPGChannelOverride`) for this source.
    var overrideIDs: Set<String> = []

    var isEmpty: Bool {
        ids.isEmpty && names.isEmpty && overrideIDs.isEmpty
    }

    /// Changes when the wanted channels change, so an unchanged guide file is read again for new channels.
    var fingerprint: String {
        let joined = (ids.sorted() + ["|"] + names.sorted() + ["|"] + overrideIDs.sorted()).joined(separator: "\n")
        return String(Self.fnv1a(joined), radix: 16)
    }

    /// 64-bit FNV-1a: stable across launches, unlike `Hasher`.
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    mutating func add(tvgID: String?, name: String?) {
        if let tvgID, !tvgID.isEmpty {
            ids.formUnion(ChannelNameNormalizer.idKeys(tvgID))
            let keys = ChannelNameNormalizer.keys(ChannelNameNormalizer.nameFromID(tvgID))
            insert(keys)
        }
        if let name, !name.isEmpty {
            insert(ChannelNameNormalizer.keys(name))
        }
    }

    private mutating func insert(_ keys: (strict: String, loose: String)) {
        if !keys.strict.isEmpty {
            names.insert(keys.strict)
        }
        if !keys.loose.isEmpty {
            looseNames.insert(keys.loose)
        }
    }

    /// Whether a `<channel>` of the guide can match one of the wanted playlist channels.
    func contains(channelID: String, names channelNames: [String]) -> Bool {
        if overrideIDs.contains(channelID) {
            return true
        }
        if ChannelNameNormalizer.idKeys(channelID).contains(where: ids.contains) {
            return true
        }
        for name in channelNames + [ChannelNameNormalizer.nameFromID(channelID)] {
            let keys = ChannelNameNormalizer.keys(name)
            if names.contains(keys.strict) || looseNames.contains(keys.loose) {
                return true
            }
        }
        return false
    }

    /// For programmes whose `<channel>` element was never seen (a malformed or reordered file).
    func containsID(_ channelID: String) -> Bool {
        overrideIDs.contains(channelID) || ChannelNameNormalizer.idKeys(channelID).contains(where: ids.contains)
    }
}
