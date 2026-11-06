//
//  ChannelAccessibility.swift
//  Fluxo
//
//  What VoiceOver, Voice Control and Switch Control get for a channel card or row, the same everywhere:
//
//  - the label: number, name, kind (Live TV, Movie, Series), for an episode its series, season, number and title,
//    favorite state, the programme on air from the TV guide (or how far a movie was watched) and the card's own
//    second line;
//  - activation plays the channel (the card's button);
//  - custom actions (the VoiceOver Actions rotor, Switch Control's menu, Voice Control "Show actions"):
//    add to or remove from the favorites, the channel's schedule, play and record (live channels the remux
//    engine records), play from the beginning (started movies and episodes), copy the stream link;
//  - Voice Control names: the full name and the name without its provider prefix and quality tags, so
//    "Tap Sky Sport F1" finds "IT | Sky Sport F1 FHD".
//

import SwiftUI

extension View {
    /// The custom actions and Voice Control names of a channel card or row (see the file comment). The label
    /// stays the element's own.
    func channelAccessibilityActions(_ item: ChannelItem, isFavorite: Bool) -> some View {
        modifier(ChannelAccessibilityActions(item: item, isFavorite: isFavorite))
    }

    /// The VoiceOver rotor of a long list or grid of channels: Favorites jumps between the favorites among `items`
    /// (the loaded part of the list). The views of the items must be identified by the item `id` (a `ForEach`
    /// over the items does it).
    func channelListRotors(_ items: [ChannelItem], library: ChannelLibrary) -> some View {
        accessibilityRotor("Favorites", entries: items.filter(library.isFavorite), entryID: \.id, entryLabel: \.displayName)
    }

    /// Publishes what a live channel shows now, as spoken text, to the card that contains this view (see
    /// `ChannelProgrammeSummaryKey`).
    func channelProgrammeSummary(_ summary: String?) -> some View {
        preference(key: ChannelProgrammeSummaryKey.self, value: summary)
    }
}

/// The programme on air of a card's channel, spoken ("On now: Evening News, 40 min left"). The guide overlay of
/// a card loads it; the card reads it into its VoiceOver label, so the label never needs a load of its own.
struct ChannelProgrammeSummaryKey: PreferenceKey {
    static let defaultValue: String? = nil

    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = value ?? nextValue()
    }
}

enum ChannelAccessibility {

    /// The spoken state of a channel that is a favorite (the star badge, a card's value). Its own key: in
    /// several languages the button that adds a favorite ("Favorite") is a verb, which would read as an action.
    static var favoriteState: String {
        String(localized: "ChannelAccessibility.favoriteState", defaultValue: "Favorite", comment: "VoiceOver: the state of a channel that is in the favorites, read after its name (not the button that adds it). A noun or an adjective, such as 'Favorite' or 'In Favorites'.")
    }

    /// "Channel 12, Sky Sport F1, Live TV, Favorite, On now: …". Parts that are nil or empty are left out.
    static func label(for item: ChannelItem, isFavorite: Bool, includesNumber: Bool = false, includesKind: Bool = true, extra: [String?] = []) -> String {
        var parts: [String] = []
        if includesNumber, let number = item.number {
            parts.append(String(localized: "Channel \(number.formatted(.number.grouping(.never)))", comment: "VoiceOver: the channel number of the playlist, as in 'Channel 12'."))
        }
        if let episode = item.series {
            // "Breaking Bad, Series, Season 1, episode 3, Pilot" rather than the raw "Breaking Bad S01E03 Pilot".
            parts.append(episode.seriesTitle)
            if includesKind {
                parts.append(item.kind.title)
            }
            parts.append(EpisodeFormat.spokenCode(episode))
            if let title = episode.episodeTitle {
                parts.append(title)
            }
        } else {
            parts.append(item.displayName)
            if includesKind {
                parts.append(item.kind.title)
            }
        }
        if isFavorite {
            parts.append(favoriteState)
        }
        parts.append(contentsOf: extra.compactMap { $0 }.filter { !$0.isEmpty })
        return TextParts.spoken(parts)
    }

    /// The spoken programme on air: "On now: Evening News, 40 min left".
    static func onNow(_ programme: GuideProgramme, at date: Date = .now) -> String {
        String(localized: "On now: \(programme.title), \(GuideFormat.remaining(programme, at: date))")
    }

    /// The names Voice Control accepts for a channel: its full name, then the name people say, without the
    /// provider prefix ("IT |", "UK:", "[DE]") and quality tags ("FHD", "4K", "HEVC").
    static func inputLabels(for item: ChannelItem) -> [String] {
        let name = item.displayName
        let spoken = spokenName(name)
        return spoken.isEmpty || spoken == name ? [name] : [name, spoken]
    }

    private static let qualityTags: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "8k", "hevc", "h264", "h265", "1080p", "720p", "2160p", "50fps", "60fps", "hdr", "raw", "backup"]

    static func spokenName(_ name: String) -> String {
        var text = Substring(name).trimmingCharacters(in: .whitespaces)
        // "IT | Sky Sport", "UK: BBC One", "[DE] ZDF", "|IT| Rai 1": a short code before a separator.
        let separators: [Character] = ["|", ":", "]", ")"]
        if let index = text.firstIndex(where: { separators.contains($0) }) {
            let prefix = text[..<index].trimmingCharacters(in: CharacterSet(charactersIn: " |[("))
            let rest = text[text.index(after: index)...].trimmingCharacters(in: CharacterSet(charactersIn: " |-"))
            if !rest.isEmpty, (1...4).contains(prefix.count), prefix.allSatisfy(\.isLetter) {
                text = rest
            }
        }
        var words = text.split(separator: " ")
        while let last = words.last, words.count > 1, qualityTags.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }
}

private struct ChannelAccessibilityActions: ViewModifier {
    let item: ChannelItem
    let isFavorite: Bool

    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @Environment(EPGStore.self) private var epg: EPGStore?
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @Environment(\.linkCopyFeedback) private var linkCopyFeedback

    func body(content: Content) -> some View {
        content
            .accessibilityInputLabels(ChannelAccessibility.inputLabels(for: item).map { Text($0) })
            .accessibilityActions {
                if item.url != nil {
                    Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                        library.toggleFavorite(item)
                        AccessibilityAnnouncer.announce(
                            isFavorite
                                ? String(localized: "Removed \(item.displayName) from Favorites")
                                : String(localized: "Added \(item.displayName) to Favorites")
                        )
                    }
                }
                if item.kind == .live, epg?.hasGuide == true, let navigation {
                    Button("Show Schedule") {
                        navigation.scheduleChannel = item
                    }
                }
                if item.isRecordable {
                    Button("Play and Record") {
                        playChannel.playAndRecord(item)
                    }
                }
                if library.watchProgress(for: item) != nil {
                    Button("Play from Beginning") {
                        library.saveWatchProgress(for: item, position: 0, duration: library.watchProgress(for: item)?.duration ?? 1)
                        playChannel(item)
                    }
                }
                // Download, Pause, Resume, Delete Download of movies and episodes.
                DownloadMenuItems(item: item)
                // Announces "Link copied" (and the credentials warning) itself.
                if let link = StreamLink(item.url) {
                    Button("Copy Link") {
                        LinkCopyFeedback.copy(link, feedback: linkCopyFeedback)
                    }
                }
            }
    }
}
