//
//  FluxoLink.swift
//  Fluxo
//
//  The fluxo:// links that open a place of the app: a screen, Search with words typed in, the TV guide at a channel,
//  or what Continue Watching resumes. They are the way into the app from outside its process on Apple TV (where
//  the scheme is registered, `Info-tvOS.plist`): the Top Shelf of the Home Screen, `xcrun simctl openurl`, and
//  anything else that opens a URL. App Intents (Siri) run in the app's process and drive the same `AppServices`
//  calls directly; a link does exactly what the intent of the same name does.
//
//      fluxo://open?screen=<home|guide|search|movies|series|library|favorites|history|recordings|settings>
//      fluxo://search?q=<words>                         Search, with the words typed in (as "Search in Fluxo")
//      fluxo://guide[?channel=<ChannelEntity id>]       the TV guide, at a live channel's row when one is given
//      fluxo://continue                                 Continue Watching (as "Continue watching in Fluxo")
//
//  The Top Shelf's own links (`fluxo://play?channel=…`, `fluxo://play?playlist=…&series=…`,
//  `fluxo://open?playlist=…&series=…`) are `TopShelfLink`'s, opened by its own handler: this type never parses them
//  (`open` without `screen` is not a `FluxoLink`), so a URL is opened once, by one of the two.
//
//  A channel is named by its `ChannelEntity` identifier (the playlist UUID and a keyed digest of the stream URL), never
//  by its stream URL, which can carry the account's user name and password. The identifier is made with a secret of
//  this installation, so a link made on another device does not resolve here (see "Apple TV › Siri" in the README).
//  Plain values (Foundation only). Apple TV only: iPhone, iPad and the Mac register no URL scheme (their way in from
//  outside is Siri, Shortcuts, Spotlight and Handoff), so they do not carry the code.
//

#if os(tvOS)
import Foundation

enum FluxoLink: Hashable, Sendable {

    /// A screen of the app, from its root.
    case screen(Screen)
    /// Search, with `term` typed in.
    case search(String)
    /// The TV guide, at the row of the live channel with this `ChannelEntity` identifier (else at now).
    case guide(channelID: String?)
    /// What Continue Watching resumes: the movie or episode watched last that was not finished, else the channel
    /// watched last.
    case continueWatching

    /// The screens a link can open. The raw values are the link's `screen` parameter.
    enum Screen: String, CaseIterable, Sendable {
        case home
        case guide
        case search
        /// The Movies tab.
        case movies
        /// The Series tab.
        case series
        case library
        case favorites
        case history
        case recordings
        case settings
    }

    static let scheme = "fluxo"

    /// The longest search a link can type in: a link is not a way to paste a document into the search field.
    static let maximumSearchLength = 200

    // MARK: - Parsing

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else {
            return nil
        }
        // The first value of each parameter; empty values count as missing.
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if query[item.name.lowercased()] == nil, let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                query[item.name.lowercased()] = value
            }
        }
        switch host {
        case "open":
            // `open?playlist=…&series=…` is the Top Shelf's link to a series page (`TopShelfLink`).
            guard let name = query["screen"], let screen = Screen(rawValue: name.lowercased()) else {
                return nil
            }
            self = .screen(screen)
        case "search":
            let term = String((query["q"] ?? query["query"] ?? "").prefix(Self.maximumSearchLength))
            self = term.isEmpty ? .screen(.search) : .search(term)
        case "guide":
            self = .guide(channelID: query["channel"])
        case "continue":
            self = .continueWatching
        default:
            return nil
        }
    }

    // MARK: - Building

    /// The link (nil only if `URLComponents` refused its parts, which are all valid).
    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .screen(let screen):
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "screen", value: screen.rawValue)]
        case .search(let term):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: String(term.prefix(Self.maximumSearchLength)))]
        case .guide(let channelID):
            components.host = "guide"
            components.queryItems = channelID.map { [URLQueryItem(name: "channel", value: $0)] }
        case .continueWatching:
            components.host = "continue"
        }
        return components.url
    }
}
#endif
