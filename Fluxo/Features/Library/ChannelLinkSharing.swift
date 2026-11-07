//
//  ChannelLinkSharing.swift
//  Fluxo
//
//  Copy Link and Share of a channel, movie or episode: the stream URL of the playlist entry (never the app's own
//  loopback URL), for another player (VLC, Infuse, a TV), a note or another device.
//
//  Every channel menu shows the same two items (`ChannelLinkMenuItems`): the context menus of the cards and rows
//  (through `ChannelContextMenu`), Favorites, the player's side panel and its ••• menu, the Playback menu of the
//  menu bar (macOS, iPad keyboards), and the VoiceOver actions of the cards and rows. The episodes of the series
//  page have them too. Where the menu is not about the stream itself, the items say whose link it is
//  (`StreamLinkMenuItems.Target`): a programme of the TV guide offers the link of its channel ("Copy Channel
//  Link"), the series page's ••• menu the link of the episode its Play button plays ("Copy Link to S1 E4"). A
//  series card or row does not know that episode until it is looked up, so its menu has "Copy Episode Link"
//  (`SeriesLinkCopy`), and the toast then names the episode ("Link to S1 E4 Copied").
//
//  Copying confirms with a short toast at the top of the window, a success haptic (iPhone) and a VoiceOver
//  announcement (`LinkCopyFeedback`, one per window, set up by `linkCopyFeedbackHost()` at its root, above the
//  player).
//
//  Credentials: IPTV providers often put the account's user name and password in every stream URL (Xtream Codes:
//  `/live/<user>/<password>/<id>.ts`, `get.php?username=…&password=…`), or a token. The app never puts these URLs
//  where the system keeps them (window state, notifications, Spotlight, drags to other apps), but here the user
//  asks for the link, and only the full URL plays elsewhere, so it is copied as it is. When it looks like it holds
//  credentials (`StreamLink.containsCredentials`), the toast and the announcement say so ("Includes your account
//  login. Share it with care."), so a link pasted into a chat is a choice, not an accident; plain links get a
//  plain confirmation, so the warning keeps its meaning. Such a link also stays on this device and does not stay
//  for long (`StreamLinkPasteboard`): it is not offered to the user's other devices through Universal Clipboard, and
//  it leaves the clipboard after `StreamLinkPasteboard.credentialsLifetime` (the toast says so), unless something
//  else was copied meanwhile. On macOS it is marked concealed too (`org.nspasteboard.ConcealedType`), so clipboard
//  history managers do not keep the password.
//

import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

// MARK: - Link

/// A stream URL that can be copied or shared: a network URL (not a recording or download on disk, nor an
/// inline `data:` URL).
struct StreamLink: Equatable, Sendable {
    let url: URL
    /// The URL seems to contain the account's credentials or an access token (see `hasCredentials(_:)`).
    let containsCredentials: Bool

    init?(_ url: URL?) {
        guard let url, !url.isFileURL, let scheme = url.scheme?.lowercased(), !Self.localSchemes.contains(scheme), url.host() != nil else {
            return nil
        }
        self.url = url
        containsCredentials = Self.hasCredentials(url)
    }

    private static let localSchemes: Set<String> = ["file", "data", "blob", "about"]

    /// Query parameters that carry a user name, a password, a token or a signature.
    private static let credentialQueryNames: Set<String> = [
        "username", "user", "login", "password", "pass", "passwd", "pwd", "token", "access_token", "auth", "auth_token",
        "authtoken", "apikey", "api_key", "key", "secret", "signature", "sig", "wmsauthsign", "hash", "mac",
    ]

    /// Xtream Codes stream paths: `/<kind>/<user>/<password>/…`.
    private static let xtreamKinds: Set<String> = ["live", "movie", "series", "timeshift"]

    /// Whether `url` looks like it contains credentials: a user name or password in the URL itself
    /// (`http://user:pass@host`), a credential or token query parameter, or an Xtream Codes stream path
    /// (`/live/<user>/<password>/<id>`, `/movie/…`, `/series/…`, `/timeshift/…`, and the short form
    /// `/<user>/<password>/<id>`). A heuristic: it errs on the side of the warning.
    static func hasCredentials(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        if components.user?.isEmpty == false || components.password?.isEmpty == false {
            return true
        }
        if components.queryItems?.contains(where: { item in
            credentialQueryNames.contains(item.name.lowercased()) && item.value?.isEmpty == false
        }) == true {
            return true
        }
        let path = url.pathComponents.filter { $0 != "/" }
        if path.count >= 4, xtreamKinds.contains(path[0].lowercased()) {
            return true
        }
        if path.count == 3, path[2].split(separator: ".").first?.allSatisfy(\.isNumber) == true {
            return true
        }
        return false
    }
}

// MARK: - Pasteboard

enum StreamLinkPasteboard {
    /// How long a link with credentials stays on the clipboard (`LinkCopyFeedback.Confirmation.expiry` says it).
    static let credentialsLifetime: Duration = .seconds(120)

    /// `credentialsLifetime` in whole minutes, rounded up, as the toast says it.
    static var credentialsLifetimeMinutes: Int {
        let seconds = Int(credentialsLifetime.components.seconds)
        return max(1, (seconds + 59) / 60)
    }

    /// Puts `link` on the general pasteboard, as a URL and as plain text (so it pastes into any text field). A link
    /// with credentials stays on this device (no Universal Clipboard) and leaves the pasteboard after
    /// `credentialsLifetime`.
    @MainActor
    static func copy(_ link: StreamLink) {
        let text = link.url.absoluteString
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        if link.containsCredentials {
            // Clears the pasteboard like `clearContents()`, and keeps what follows off the user's other devices.
            pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
            pasteboard.clearContents()
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .URL)
        item.setString(text, forType: .string)
        if link.containsCredentials {
            // The nspasteboard.org convention: clipboard managers do not record concealed items.
            item.setData(Data(), forType: concealedType)
        }
        pasteboard.writeObjects([item])
        if link.containsCredentials {
            clearLater(changeCount: pasteboard.changeCount)
        }
        #elseif os(tvOS)
        // No pasteboard on Apple TV: the menus do not offer Copy Link there (`PlatformFeatures.pasteboard`).
        _ = text
        #else
        let items: [[String: Any]] = [[
            UTType.url.identifier: link.url,
            UTType.utf8PlainText.identifier: text,
        ]]
        if link.containsCredentials {
            UIPasteboard.general.setItems(items, options: [
                .localOnly: true,
                .expirationDate: Date.now.addingTimeInterval(TimeInterval(credentialsLifetime.components.seconds)),
            ])
        } else {
            UIPasteboard.general.setItems(items)
        }
        #endif
    }

    #if os(macOS)
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// The Mac's pasteboard has no expiration date: the link is removed after `credentialsLifetime` if it is still
    /// what the pasteboard holds (nothing was copied since).
    @MainActor
    private static func clearLater(changeCount: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: credentialsLifetime)
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
            }
        }
    }
    #endif
}

// MARK: - Feedback

/// The confirmation of the last copied link in one window: what the toast shows, and the haptic trigger.
@MainActor
@Observable
final class LinkCopyFeedback {

    struct Confirmation: Equatable, Identifiable {
        let id = UUID()
        let containsCredentials: Bool
        /// The episode of a series whose link was copied from a menu that could not name it (a series card): the
        /// toast names it.
        var episode: EpisodeRef?

        var title: String {
            if let episode {
                return String(localized: "LinkCopied.episodeTitle", defaultValue: "Link to \(EpisodeFormat.code(episode)) Copied", comment: "Toast after Copy Episode Link of a series: the stream link of the episode to watch next is on the clipboard. The placeholder is the short episode label, such as S1 E4.")
            }
            return String(localized: "LinkCopied.title", defaultValue: "Link Copied", comment: "Toast after Copy Link: the stream link of a channel, movie or episode is on the clipboard.")
        }

        /// The warning of a link with credentials.
        var detail: String? {
            guard containsCredentials else {
                return nil
            }
            return String(localized: "LinkCopied.credentials", defaultValue: "Includes your account login. Share it with care.", comment: "Second line of the Link Copied toast when the copied stream link contains the user name and password (or access token) of the IPTV account.")
        }

        /// A link with credentials leaves the clipboard after a while (`StreamLinkPasteboard.credentialsLifetime`).
        var expiry: String? {
            guard containsCredentials else {
                return nil
            }
            let minutes = StreamLinkPasteboard.credentialsLifetimeMinutes
            return String(localized: "LinkCopied.expiryMinutes", defaultValue: "Removed from the clipboard in \(minutes) minutes.", comment: "Last line of the Link Copied toast when the copied stream link contains the IPTV account's login: the link is removed from the clipboard (and is not shared with the user's other devices) this many minutes after it was copied. The placeholder is the number of minutes.")
        }

        var spokenText: String {
            let spokenTitle = episode.map {
                String(localized: "LinkCopied.episodeSpoken", defaultValue: "Link to \(EpisodeFormat.spokenCode($0)) copied", comment: "VoiceOver, after Copy Episode Link of a series. The placeholder is the spoken season and episode, such as 'Season 1, episode 4'.")
            }
            return TextParts.sentences([spokenTitle ?? title, detail.map(Self.withoutFinalStop), expiry.map(Self.withoutFinalStop)])
        }

        /// `sentences(_:)` adds the full stops between sentences itself.
        private static func withoutFinalStop(_ sentence: String) -> String {
            var sentence = sentence
            while let last = sentence.last, ".。।".contains(last) {
                sentence.removeLast()
            }
            return sentence
        }

        /// Long enough to read the warning and the expiry.
        var duration: Duration {
            containsCredentials ? .seconds(5) : .seconds(2)
        }
    }

    private(set) var confirmation: Confirmation?
    /// Increments on every copy (the haptic's trigger: copying the same link twice still confirms).
    private(set) var copyCount = 0
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// Copies `link` and confirms it; `episode` names the episode in the confirmation. `duration` overrides how
    /// long the toast shows (the debug harness holds it for its screenshots).
    func copy(_ link: StreamLink, episode: EpisodeRef? = nil, duration: Duration? = nil) {
        StreamLinkPasteboard.copy(link)
        let confirmation = Confirmation(containsCredentials: link.containsCredentials, episode: episode)
        self.confirmation = confirmation
        copyCount += 1
        AccessibilityAnnouncer.announce(confirmation.spokenText)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration ?? confirmation.duration)
            guard !Task.isCancelled, self?.confirmation?.id == confirmation.id else {
                return
            }
            self?.confirmation = nil
        }
    }

    /// Copies `link` with the confirmation of `feedback` (the window's), or with only the announcement when the
    /// view is outside a window root that hosts one (previews).
    static func copy(_ link: StreamLink, feedback: LinkCopyFeedback?, episode: EpisodeRef? = nil) {
        if let feedback {
            feedback.copy(link, episode: episode)
        } else {
            StreamLinkPasteboard.copy(link)
            AccessibilityAnnouncer.announce(Confirmation(containsCredentials: link.containsCredentials, episode: episode).spokenText)
        }
    }
}

extension EnvironmentValues {
    /// The copy confirmation of this window (see `linkCopyFeedbackHost()`).
    @Entry var linkCopyFeedback: LinkCopyFeedback?
}

extension FocusedValues {
    /// The copy confirmation of the focused window, for the menu bar's Copy Link.
    @Entry var linkCopyFeedback: LinkCopyFeedback?
}

extension View {
    /// Shows the confirmation of Copy Link over this view (the root of a window, above the player) and provides it to
    /// the channel menus inside. `colorScheme` is the scheme of what the toast covers when it differs from the
    /// window's: dark while the player is on screen.
    func linkCopyFeedbackHost(colorScheme: ColorScheme? = nil) -> some View {
        modifier(LinkCopyFeedbackHost(colorScheme: colorScheme))
    }
}

private struct LinkCopyFeedbackHost: ViewModifier {
    let colorScheme: ColorScheme?

    @State private var feedback = LinkCopyFeedback()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var windowColorScheme

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let confirmation = feedback.confirmation {
                    LinkCopiedToast(confirmation: confirmation)
                        .environment(\.colorScheme, colorScheme ?? windowColorScheme)
                        .id(confirmation.id)
                        .padding(.top, 8)
                        .padding(.horizontal, 16)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.2), value: feedback.confirmation)
            .sensoryFeedback(.success, trigger: feedback.copyCount)
            .environment(\.linkCopyFeedback, feedback)
            .focusedSceneValue(\.linkCopyFeedback, feedback)
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugCopyLink)) { notification in
                // Debug harness (`copy-link:`): Copy Link of a channel, as its menu does; the toast stays for the
                // screenshots.
                if let link = StreamLink((notification.object as? ChannelItem)?.url) {
                    feedback.copy(link, duration: .seconds(20))
                }
            }
            #endif
    }
}

/// "Link Copied", with the credentials warning under it when the link has them, at the top of the window, as wide
/// as its text. A thick material rather than glass: it lies over the navigation bar or the player's controls, which
/// clear glass lets show through the text. It does not take touches (it never covers a control for long) and
/// VoiceOver hears the announcement instead.
private struct LinkCopiedToast: View {
    let confirmation: LinkCopyFeedback.Confirmation

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: confirmation.containsCredentials ? "key.fill" : "link")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(confirmation.containsCredentials ? Theme.warning : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(confirmation.title)
                    .font(.subheadline.weight(.semibold))
                if let detail = confirmation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let expiry = confirmation.expiry {
                    Text(expiry)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thickMaterial, in: shape)
        .overlay {
            shape.strokeBorder(Theme.surfaceStroke)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
extension Notification.Name {
    /// Debug harness: Copy Link of a channel in every window (the object is a `ChannelItem`).
    static let fluxoDebugCopyLink = Notification.Name("FluxoDebugCopyLink")
}
#endif

// MARK: - Menu items

/// Copy Link and Share of a channel, movie or episode, in every channel menu. Nothing when it has no network
/// URL.
struct ChannelLinkMenuItems: View {
    let item: ChannelItem

    var body: some View {
        StreamLinkMenuItems(url: item.url, name: item.displayName)
    }
}

/// Copy Link and Share of a stream URL; `name` titles the share sheet's preview and an e-mail's subject.
struct StreamLinkMenuItems: View {

    /// Whose link the items copy and share, when the menu is about something else.
    enum Target: Equatable {
        /// The stream the menu is about: "Copy Link", "Share".
        case stream
        /// The channel of a programme (TV guide): "Copy Channel Link", "Share Channel".
        case channel
        /// The episode a series plays next (the series page): "Copy Link to S1 E4", "Share S1 E4".
        case episode(EpisodeRef)
    }

    let url: URL?
    let name: String
    var target: Target = .stream

    @Environment(\.linkCopyFeedback) private var feedback

    var body: some View {
        // Apple TV has neither a clipboard nor a share sheet (`PlatformFeatures.pasteboard`).
        #if !os(tvOS)
        if let link = StreamLink(url) {
            Button(copyTitle, systemImage: "link") {
                LinkCopyFeedback.copy(link, feedback: feedback, episode: episode)
            }
            // The preview gives the share sheet a title, so it does not load the stream to make one. (No icon: an
            // SF Symbol exports as a blank image there, and the system's link placeholder reads better.)
            if let shareTitle {
                ShareLink(Text(shareTitle), item: link.url, subject: Text(verbatim: name), preview: SharePreview(name))
            } else {
                // The system's own "Share" label (localized by the system).
                ShareLink(item: link.url, subject: Text(verbatim: name), preview: SharePreview(name))
            }
        }
        #endif
    }

    private var copyTitle: String {
        switch target {
        case .stream:
            String(localized: "Copy Link", comment: "Menu item and VoiceOver action (verb): copies the stream link (URL) of a channel, movie or episode to the clipboard, to play it in another app or on another device.")
        case .channel:
            String(localized: "Copy Channel Link", comment: "Menu item of a programme of the TV guide: copies the stream link of its channel to the clipboard.")
        case .episode(let episode):
            String(localized: "Copy Link to \(EpisodeFormat.code(episode))", comment: "Menu item of a series page: copies the stream link of the episode its Play button plays. The placeholder is the short episode label, such as S1 E4.")
        }
    }

    /// The episode the confirmation names ("Link to S1 E4 Copied").
    private var episode: EpisodeRef? {
        if case .episode(let episode) = target {
            return episode
        }
        return nil
    }

    /// nil for the system's "Share".
    private var shareTitle: String? {
        switch target {
        case .stream:
            nil
        case .channel:
            String(localized: "Share Channel", comment: "Menu item of a programme of the TV guide: shares the stream link of its channel.")
        case .episode(let episode):
            String(localized: "Share \(EpisodeFormat.code(episode))", comment: "Menu item of a series page: shares the stream link of the episode its Play button plays. The placeholder is the short episode label, such as S1 E4.")
        }
    }
}

/// Copy Episode Link of a series card or row: looks up the episode its Continue or Play would play, then copies
/// that episode's link with a confirmation that names it ("Link to S1 E4 Copied"). Says so when the series has
/// no episode with a network link.
@MainActor
enum SeriesLinkCopy {
    static func copy(_ series: SeriesItem, library: ChannelLibrary, container: ModelContainer, feedback: LinkCopyFeedback?) async {
        guard let nextUp = await SeriesPlayback.nextUp(for: series, library: library, container: container),
              let link = StreamLink(nextUp.episode.url)
        else {
            AccessibilityAnnouncer.announce(String(localized: "\(series.title) has no episode link to copy", comment: "VoiceOver, after Copy Episode Link of a series whose playlist no longer lists an episode with a stream link."), priority: .high)
            return
        }
        LinkCopyFeedback.copy(link, feedback: feedback, episode: nextUp.episode.series)
    }

    /// The menu item's title.
    static var title: String {
        String(localized: "Copy Episode Link", comment: "Menu item of a series card or row: copies the stream link of the episode Continue (or Play) would play, the one the viewer is up to.")
    }
}
