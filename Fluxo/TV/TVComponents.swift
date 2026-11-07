//
//  TVComponents.swift
//  Fluxo
//
//  Building blocks of the Apple TV screens, sized for a TV seen from across the room: focusable cards (the
//  system's card button style, which lifts, tilts and lights the artwork under focus as the tiles of the TV app
//  do, with the title beneath that moves down to make room), the shelves they sit in (focus sections, so a swipe
//  up or down goes to the shelf above or below wherever the focus is in the row), section titles, the See All
//  card and the empty states.
//
//  Layouts use the 1920 × 1080 point canvas of tvOS. The screens ignore the safe area so that artwork can run to
//  the edges of the picture, and keep text and controls inside `TVLayout.margin`, the overscan-safe inset Apple
//  recommends (80 points on the sides, 60 at the top and bottom).
//

#if os(tvOS)
import SwiftUI

/// Sizes of the 10-foot layout (points of the 1920 × 1080 tvOS canvas).
enum TVLayout {
    /// Leading and trailing inset of text and controls: the overscan-safe area.
    static let margin: CGFloat = 80
    /// Top and bottom inset of text and controls.
    static let verticalMargin: CGFloat = 60
    /// The height of the tab bar above a page's content (tvOS draws it over the page).
    static let tabBarClearance: CGFloat = 150
    /// A landscape card: channels, Continue Watching, On Now, episodes. Four fit across the screen.
    static let landscapeCard = CGSize(width: 400, height: 225)
    /// A poster card: movies and series (2:3). Six fit across the screen.
    static let posterCard = CGSize(width: 248, height: 372)
    /// A channel logo inside a landscape card, inset from its edges.
    static let logoSize = CGSize(width: 260, height: 140)
    /// Between two cards of a shelf.
    static let cardSpacing: CGFloat = 40
    /// Between two shelves.
    static let shelfSpacing: CGFloat = 36
    /// Room above and below the cards of a shelf for the focused one, which grows past its frame.
    static let focusPadding: CGFloat = 30
    static let cardCornerRadius: CGFloat = 16
}

extension Color {
    /// The background tvOS draws behind an app's pages: the hero and the series page fade into it.
    static func tvPageBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(white: 0.055) : Color(white: 0.93)
    }
}

extension View {
    /// A form presented over the app (Add Playlist, Add Guide Source) as a full-screen page: opaque (what is under
    /// it never shows through) and its fields as wide as a whole address, centered.
    func tvFormPage() -> some View {
        modifier(TVFormPage())
    }

    /// The page's own background, edge to edge: the hero and the series page fade into exactly this color.
    func tvPageBackground() -> some View {
        modifier(TVPageBackground())
    }
}

private struct TVFormPage: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 1_240)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Color.tvPageBackground(colorScheme)
                    .ignoresSafeArea()
            }
    }
}

private struct TVPageBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                Color.tvPageBackground(colorScheme)
                    .ignoresSafeArea()
            }
    }
}

enum TVText {
    /// The VoiceOver hint of a card or a row that plays `item`: the hints of the iPhone and iPad rows and cards.
    static func playsHint(for item: ChannelItem) -> LocalizedStringResource {
        switch item.kind {
        case .live:
            "Plays the channel"
        case .series:
            "Plays the episode"
        default:
            "Plays the video"
        }
    }

    /// For VoiceOver: "Channel 12", the number of a channel in its playlist (the guide's and the rows' key).
    static func spokenChannelNumber(_ number: Int) -> String {
        String(localized: "Channel \(EpisodeFormat.number(number))", comment: "VoiceOver: the channel number of the playlist, as in 'Channel 12'.")
    }

    /// For VoiceOver: "BBC One, Channel 12", a channel's name and number (its name alone without a number).
    static func spokenChannel(_ item: ChannelItem) -> String {
        TextParts.spoken([item.displayName, item.number.map(spokenChannelNumber)])
    }

    /// The VoiceOver hint of a recording.
    static let playsRecordingHint = LocalizedStringResource("Plays the recording", comment: "VoiceOver hint of a recording in the list.")
    static let opensSeriesHint = LocalizedStringResource("TV.hint.series", defaultValue: "Shows the seasons and episodes", comment: "VoiceOver hint of a series card on Apple TV: selecting it opens the page of the series.")
    static let opensCategoryHint = LocalizedStringResource("TV.hint.category", defaultValue: "Shows everything in this category", comment: "VoiceOver hint of a category tile or a See All card on Apple TV.")
    static let seeAll = LocalizedStringResource("See All")
}

// MARK: - Cards

/// What a card does when it is selected.
enum TVCardAction {
    /// Plays, or anything else done in place.
    case perform(() -> Void)
    /// Pushes a screen on the enclosing navigation stack.
    case open(ChannelRoute)
}

/// A focusable piece of artwork with its caption beneath, like the tiles of the TV app: the artwork is the button
/// (card style: it lifts and tilts under focus), the caption stays under it and moves down while it is focused so
/// that the lifted artwork never covers it. One VoiceOver element, named by `accessibilityLabel`.
struct TVCard<Artwork: View, Caption: View, Menu: View>: View {
    let size: CGSize
    let action: TVCardAction
    /// The name the harness's `focus:<name>` route matches (Debug builds).
    var focusName: String?
    let accessibilityLabel: Text
    var accessibilityHint: Text?
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var caption: (_ isFocused: Bool) -> Caption
    @ViewBuilder var menu: () -> Menu

    @FocusState private var isFocused: Bool
    #if DEBUG
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            button
                .contextMenu {
                    menu()
                }
                .focused($isFocused)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint ?? Text(verbatim: ""))
            caption(isFocused)
                .frame(width: size.width, alignment: .leading)
                // The focused card grows by about a tenth: its caption follows it down.
                .offset(y: isFocused ? 18 : 0)
                .padding(.top, 14)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .accessibilityHidden(true)
        }
        #if DEBUG
        .onChange(of: navigation?.debugFocusName, initial: true) { _, name in
            if let name, let focusName, focusName.caseInsensitiveCompare(name) == .orderedSame {
                isFocused = true
            }
        }
        #endif
    }

    @ViewBuilder
    private var button: some View {
        switch action {
        case .perform(let perform):
            Button(action: perform) {
                artworkFrame
            }
            .buttonStyle(.card)
        case .open(let route):
            NavigationLink(value: route) {
                artworkFrame
            }
            .buttonStyle(.card)
        }
    }

    private var artworkFrame: some View {
        artwork()
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: TVLayout.cardCornerRadius, style: .continuous))
    }
}

extension TVCard where Menu == EmptyView {
    init(
        size: CGSize,
        action: TVCardAction,
        focusName: String? = nil,
        accessibilityLabel: Text,
        accessibilityHint: Text? = nil,
        @ViewBuilder artwork: @escaping () -> Artwork,
        @ViewBuilder caption: @escaping (_ isFocused: Bool) -> Caption
    ) {
        self.init(size: size, action: action, focusName: focusName, accessibilityLabel: accessibilityLabel, accessibilityHint: accessibilityHint, artwork: artwork, caption: caption) {
            EmptyView()
        }
    }
}

/// The title and second line under a card.
struct TVCardCaption: View {
    let title: String
    var subtitle: String?
    /// A progress bar under the text (a programme on air, a movie watched part-way).
    var progress: Double?
    var isFocused = false
    var showsLiveBadge = false
    /// Under a poster: a smaller title on up to two lines (posters are narrow).
    var isCompact = false
    var progressTint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(isCompact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                .foregroundStyle(isFocused ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(isCompact ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
            if subtitle != nil || showsLiveBadge {
                HStack(spacing: 8) {
                    if showsLiveBadge {
                        LiveBadge()
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            if let progress {
                ProgrammeProgressBar(progress: progress, tint: progressTint, height: 6)
                    .padding(.top, 2)
            }
        }
    }
}

/// A channel, movie or episode in a landscape card. Selecting it plays it; a series' episode can open its series
/// instead (`opensSeries`). Live channels show what is on now and its progress, from the TV guide.
struct TVChannelCard: View {
    let item: ChannelItem
    /// The second line, when it is not what is on now (a live channel) or the category.
    var subtitle: String?
    /// An episode opens the page of its series rather than playing. The card is then the series': its title, "Series"
    /// under it (not the episode that happened to be found) and no episode progress.
    var opensSeries = false

    @Environment(\.playChannel) private var playChannel
    @Environment(ChannelLibrary.self) private var library

    private var showsSeries: Bool {
        opensSeries && item.series != nil
    }

    var body: some View {
        let progress = showsSeries ? nil : library.watchProgress(for: item)
        NowNextReader(item: item) { nowNext in
            TimelineView(.everyMinute) { context in
                let current = nowNext?.current.flatMap { $0.isOnAir(at: context.date) ? $0 : nil }
                let title = item.series?.seriesTitle ?? item.displayName
                TVCard(
                    size: TVLayout.landscapeCard,
                    action: action,
                    focusName: showsSeries ? title : item.displayName,
                    accessibilityLabel: Text(showsSeries
                        ? TextParts.spoken([title, ChannelContentKind.series.title, subtitle])
                        : TextParts.spoken([item.displayName, current?.title, subtitle ?? item.groupName])),
                    accessibilityHint: Text(showsSeries ? TVText.opensSeriesHint : TVText.playsHint(for: item))
                ) {
                    TVLandscapeArtwork(item: item)
                } caption: { isFocused in
                    TVCardCaption(
                        title: title,
                        subtitle: current?.title ?? subtitle ?? (showsSeries ? ChannelContentKind.series.title : item.episodeLine) ?? ChannelCandidate.displayGroup(item.groupName),
                        progress: current.map { $0.progress(at: context.date) } ?? progress?.fraction,
                        isFocused: isFocused,
                        showsLiveBadge: current != nil,
                        progressTint: current != nil ? Theme.live : Theme.accent
                    )
                } menu: {
                    TVChannelMenu(item: item)
                }
            }
        }
    }

    private var action: TVCardAction {
        if opensSeries, let series = item.seriesItem {
            return .open(series.route)
        }
        return .perform {
            playChannel(item)
        }
    }
}

/// A movie, or a series (from one of its episodes), in a poster card. A movie plays; a series opens its page.
struct TVPosterCard: View {
    let item: ChannelItem

    @Environment(\.playChannel) private var playChannel
    @Environment(ChannelLibrary.self) private var library

    var body: some View {
        if let series = item.seriesItem {
            TVSeriesCard(series: series)
        } else {
            let progress = library.watchProgress(for: item)
            TVCard(
                size: TVLayout.posterCard,
                action: .perform { playChannel(item) },
                focusName: item.displayName,
                accessibilityLabel: Text(TextParts.spoken([item.displayName, progress.map(WatchProgressFormat.remaining)])),
                accessibilityHint: Text(TVText.playsHint(for: item))
            ) {
                TVPosterArtwork(logo: item.logo, name: item.displayName, kind: item.kind)
                    .overlay(alignment: .bottom) {
                        if let progress {
                            ProgrammeProgressBar(progress: progress.fraction, tint: Theme.accent, height: 6)
                                .padding(14)
                        }
                    }
            } caption: { isFocused in
                TVCardCaption(title: item.displayName, subtitle: progress.map(WatchProgressFormat.remaining), isFocused: isFocused, isCompact: true)
            } menu: {
                TVChannelMenu(item: item)
            }
        }
    }
}

/// A series in a poster card: its title, and the counts (or the episode to watch next). Opens the series page.
struct TVSeriesCard: View {
    let series: SeriesItem

    @Environment(ChannelLibrary.self) private var library

    var body: some View {
        let known = library.series.summary(of: series)
        let isFavorite = library.series.isFavorite(series)
        TVCard(
            size: TVLayout.posterCard,
            action: .open(series.route),
            focusName: series.title,
            accessibilityLabel: Text(TextParts.spoken([series.title, ChannelContentKind.series.title] + known.countParts + [isFavorite ? ChannelAccessibility.favoriteState : nil])),
            accessibilityHint: Text(TVText.opensSeriesHint)
        ) {
            TVPosterArtwork(logo: known.artwork ?? series.artwork, name: series.title, kind: .series)
        } caption: { isFocused in
            TVCardCaption(title: series.title, subtitle: known.countsLine, isFocused: isFocused, isCompact: true)
        } menu: {
            Button {
                library.series.toggleFavorite(series)
            } label: {
                Label(isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"), systemImage: isFavorite ? "star.slash" : "star")
            }
        }
        .task(id: TaskKey(key: series.bookmarkKey, revision: library.series.summaryRevision)) {
            library.series.loadSummary(of: series)
        }
    }

    private struct TaskKey: Hashable {
        let key: String
        let revision: Int
    }
}

/// The long-press menu of a channel, movie or episode card: play, record (live channels the engine plays), favorite,
/// the TV guide, the series.
struct TVChannelMenu: View {
    let item: ChannelItem

    @Environment(ChannelLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.playChannel) private var playChannel

    var body: some View {
        let isFavorite = library.isFavorite(item)
        Button {
            playChannel(item)
        } label: {
            Label(item.kind == .live ? String(localized: "Watch Live", comment: "Button of a featured live channel on the Home page.") : String(localized: "Play", comment: "Button of a featured movie on the Home page."), systemImage: "play.fill")
        }
        if item.isRecordable {
            // Plays the channel and records it once its stream is open (the player then shows REC).
            Button {
                playChannel.playAndRecord(item)
            } label: {
                Label(String(localized: "Record"), systemImage: "record.circle")
            }
        }
        if item.bookmarkKey != nil {
            Button {
                library.toggleFavorite(item)
            } label: {
                Label(isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"), systemImage: isFavorite ? "star.slash" : "star")
            }
        }
        if item.kind == .live {
            Button {
                navigation.showInGuide(item)
            } label: {
                Label(String(localized: "TV.menu.showInGuide", defaultValue: "Show in TV Guide", comment: "Apple TV, long-press menu of a live channel: opens the TV guide at the channel."), systemImage: "calendar.day.timeline.left")
            }
        }
        if let series = item.seriesItem {
            NavigationLink(value: series.route) {
                Label(String(localized: "TV.menu.goToSeries", defaultValue: "Go to Series", comment: "Apple TV, long-press menu of an episode: opens the page of its series."), systemImage: "square.stack")
            }
        }
    }
}

extension ChannelItem {
    /// "S1 E3 · Title" of an episode; nil for anything else.
    var episodeLine: String? {
        series.map { TextParts.line([EpisodeFormat.code($0), $0.episodeTitle]) }
    }
}

// MARK: - Artwork

/// The artwork of an entry in a landscape card: a channel's logo on the tile background, or a poster in front of
/// its own blurred, enlarged copy (posters are portrait; the card is 16:9).
struct TVLandscapeArtwork: View {
    let item: ChannelItem
    var size: CGSize = TVLayout.landscapeCard

    var body: some View {
        TVLandscapeArtworkView(logo: item.logo, name: item.displayName, kind: item.kind, size: size)
    }
}

struct TVLandscapeArtworkView: View {
    let logo: String?
    let name: String
    let kind: ChannelContentKind
    var size: CGSize = TVLayout.landscapeCard

    var body: some View {
        ZStack {
            if logo == nil {
                ArtworkPlaceholder(name: name, kind: kind)
            } else if kind.usesPosterArtwork {
                let posterSize = CGSize(width: size.height * 2 / 3, height: size.height)
                ZStack {
                    LogoImage(source: logo, size: CGSize(width: 32, height: 48), contentMode: .fill) { _ in
                        ArtworkPlaceholder(name: name, kind: kind)
                    }
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(CGSize(width: size.width / 32, height: size.width / 32))
                    .blur(radius: 24)
                    .overlay(.black.opacity(0.25))
                    LogoImage(source: logo, size: posterSize, contentMode: .fill) { phase in
                        if phase == .unavailable {
                            ArtworkPlaceholder(name: name, kind: kind)
                        } else {
                            Color.clear
                        }
                    }
                    .shadow(color: .black.opacity(0.45), radius: 12)
                }
            } else {
                TVLogoTile(logo: logo, name: name, kind: kind, logoSize: CGSize(width: size.width * 0.65, height: size.height * 0.62))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A channel's logo on its tile. The tile is opaque (the page, a sheet's blurred content or the backdrop never show
/// through it) and graphite, or light for a logo of dark lettering on a transparent background, which would vanish
/// on graphite: the rule of the Top Shelf's images (`LogoTone`).
private struct TVLogoTile: View {
    let logo: String?
    let name: String
    let kind: ChannelContentKind
    let logoSize: CGSize

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var tone: LogoTone.Result?

    var body: some View {
        let request = LogoRequest(source: logo, pointSize: logoSize, scale: displayScale, contentMode: .fit)
        let isDark = (tone?.key == request?.key ? tone?.isDarkOnTransparent : request.flatMap(LogoTone.cached)) ?? false
        ZStack {
            if isDark {
                LinearGradient(colors: [Color(white: 0.95), Color(white: 0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Color.tvPageBackground(colorScheme)
                Theme.tileBackground
            }
            LogoImage(source: logo, size: logoSize, contentMode: .fit) { phase in
                if phase == .unavailable {
                    ArtworkPlaceholder(name: name, kind: kind)
                } else {
                    Color.clear
                }
            }
        }
        .task(id: request?.key) {
            guard let request, LogoTone.cached(request) == nil else {
                return
            }
            // The image LogoImage shows, from the same cache: measured once per logo and size.
            guard let image = await LogoImageLoader.shared.image(for: request), !Task.isCancelled else {
                return
            }
            tone = LogoTone.Result(key: request.key, isDarkOnTransparent: LogoTone.measure(image, for: request))
        }
    }
}

/// The app's icon, flat (`TVAppMark`, drawn from the icon's artwork by `Design/Icon/render_tvos_mark.swift`), with the
/// corners of an app icon: Settings' header and the welcome screen.
struct TVAppMark: View {
    let size: CGFloat

    var body: some View {
        Image("TVAppMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.22, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: size * 0.1, y: size * 0.055)
            .accessibilityHidden(true)
    }
}

/// A poster (2:3) of a movie or series, or its placeholder.
struct TVPosterArtwork: View {
    let logo: String?
    let name: String
    let kind: ChannelContentKind
    var size: CGSize = TVLayout.posterCard

    var body: some View {
        ZStack {
            if logo == nil {
                ArtworkPlaceholder(name: name, kind: kind)
            } else {
                Theme.tileBackground
                LogoImage(source: logo, size: size, contentMode: .fill) { phase in
                    if phase == .unavailable {
                        ArtworkPlaceholder(name: name, kind: kind)
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A large blurred copy of a piece of artwork that fills its frame: the backdrop of the hero and the series page.
/// The image is decoded tiny (a few points: the blur hides everything finer) and scaled up.
struct TVBackdrop: View {
    let logo: String?
    let name: String
    let kind: ChannelContentKind

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ArtworkPlaceholder(name: name, kind: kind)
                    .opacity(logo == nil ? 1 : 0)
                if logo != nil {
                    let decode = kind.usesPosterArtwork ? CGSize(width: 16, height: 24) : CGSize(width: 24, height: 14)
                    LogoImage(source: logo, size: decode, contentMode: .fill) { _ in
                        ArtworkPlaceholder(name: name, kind: kind)
                    }
                    .scaleEffect(max(proxy.size.width / decode.width, proxy.size.height / decode.height))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .blur(radius: 40, opaque: true)
            .saturation(1.3)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Shelves

/// A titled row of cards that scrolls sideways, edge to edge, its first card at the safe margin. A focus section.
struct TVShelf<Content: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVSectionTitle(title: title, subtitle: subtitle, systemImage: systemImage)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TVLayout.cardSpacing) {
                    content()
                }
                .padding(.vertical, TVLayout.focusPadding)
            }
            .contentMargins(.horizontal, TVLayout.margin, for: .scrollContent)
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
        .focusSection()
    }
}

/// The title of a shelf or section: the headline, an optional symbol and a quieter second line.
struct TVSectionTitle: View {
    let title: String
    var subtitle: String?
    var systemImage: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, TVLayout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The card at the end of a shelf that opens all of it (a category's grid, the history).
struct TVSeeAllCard: View {
    let route: ChannelRoute
    /// The category the shelf shows, for its count ("See All, 42 movies"); nil when the count is not shown.
    var group: GroupItem?
    var size: CGSize = TVLayout.landscapeCard
    var focusName: String?

    /// How many there are in all; nil when unknown.
    private var count: Int? {
        group?.itemCount
    }

    var body: some View {
        TVCard(
            size: size,
            action: .open(route),
            focusName: focusName,
            // The noun of the category's kind (channels, movies, series and episodes), as the category cards say it.
            accessibilityLabel: Text(TextParts.spoken([String(localized: TVText.seeAll), group.map(CategoryCard.countText)])),
            accessibilityHint: Text(TVText.opensCategoryHint)
        ) {
            ZStack {
                Rectangle()
                    .fill(.primary.opacity(0.12))
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text(TVText.seeAll)
                        .font(.headline)
                    if let count {
                        Text(count.formatted())
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .monospacedDigit()
                    }
                }
            }
        } caption: { _ in
            EmptyView()
        }
    }
}

// MARK: - Buttons and states

/// The look of the action buttons of the hero and the series page: Liquid Glass capsules, the main one tinted
/// with the accent (the system lifts and lights whichever has the focus).
///
/// `isProminent` picks one of two button styles, so changing it replaces the button: a focused button whose
/// prominence follows the focus or a selection loses the focus. Keep it fixed while the button can have the focus
/// (the season tabs of the series page have their own single style for that reason).
///
/// Their labels are white on the accent (the main one) or the primary color on the glass, and the brand's ink once
/// focused: the focused button turns into a light platter, where the tint the styles give the label would be violet
/// on lilac, about 2.6:1 (`TVActionLabelStyle`).
struct TVActionButtonStyle: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if isProminent {
            content
                .buttonStyle(.glassProminent)
                .tint(Theme.accentFill)
                .foregroundStyle(TVActionLabelStyle(isProminent: true))
        } else {
            content
                .buttonStyle(.glass)
                .foregroundStyle(TVActionLabelStyle(isProminent: false))
        }
    }
}

/// The color of an action button's label, by focus (`EnvironmentValues.isFocused` is the button's inside its
/// label): the ink of the brand on the focused platter, else white on the accent or the primary color on glass.
struct TVActionLabelStyle: ShapeStyle {
    let isProminent: Bool
    /// A destructive action on glass: red until focused (apply it to the label, inside the button).
    var isDestructive = false

    func resolve(in environment: EnvironmentValues) -> Color {
        if environment.isFocused {
            return Color(.sRGB, red: 0.078, green: 0.059, blue: 0.235)
        }
        if isDestructive {
            return Theme.error
        }
        if isProminent || environment.colorScheme == .dark {
            return .white
        }
        return .black
    }
}

extension View {
    /// Liquid Glass action buttons (`TVActionButtonStyle`).
    func tvActionButton(prominent: Bool = false) -> some View {
        modifier(TVActionButtonStyle(isProminent: prominent))
    }

    /// Debug harness (`focus:<name>`): takes the focus when the route names this view. Nothing in Release builds.
    func tvDebugFocus(_ name: String, focus: FocusState<Bool>.Binding) -> some View {
        modifier(TVDebugFocusModifier(name: name, focus: focus))
    }
}

private struct TVDebugFocusModifier: ViewModifier {
    let name: String
    let focus: FocusState<Bool>.Binding

    #if DEBUG
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .onChange(of: navigation?.debugFocusName, initial: true) { _, requested in
                if let requested, requested.caseInsensitiveCompare(name) == .orderedSame {
                    focus.wrappedValue = true
                }
            }
        #else
        content
        #endif
    }
}

/// A page with nothing to show yet: a symbol, a title, what to do, and optionally the button that does it (it
/// takes the focus, so the page is never a dead end).
struct TVEmptyState<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: systemImage)
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1_000)
            HStack(spacing: 30) {
                actions()
            }
            .padding(.top, 12)
        }
        .padding(TVLayout.margin)
        .frame(maxWidth: .infinity, minHeight: 640)
        .focusSection()
    }
}

/// No playlist yet, on a page other than Home: what the page will show, and Add Playlist (focused).
struct TVNoPlaylistsState: View {
    let message: String
    let systemImage: String

    @Environment(PlaylistActions.self) private var actions

    var body: some View {
        TVEmptyState(title: String(localized: "No Playlists"), message: message, systemImage: systemImage) {
            Button {
                actions.add()
            } label: {
                Label("Add Playlist", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 12)
            }
            .tvActionButton(prominent: true)
        }
    }
}

extension TVEmptyState where Actions == EmptyView {
    init(title: String, message: String, systemImage: String) {
        self.init(title: title, message: message, systemImage: systemImage) {
            EmptyView()
        }
    }
}
#endif
