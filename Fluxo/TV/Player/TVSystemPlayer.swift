//
//  TVSystemPlayer.swift
//  Fluxo
//
//  The UIKit side of the Apple TV player: the one `AVPlayerViewController` of the app, on the app's single
//  `AVPlayer`, and its delegate. `TVPlayerView` describes what it shows besides the video (`TVPlayerChrome`: the
//  transport bar's buttons, the info panel's actions and tabs, the contextual actions, the metadata of the item)
//  and this object applies it, rebuilding only what changed.
//
//  - Seeks: the transport bar seeks AVPlayer itself (the clickpad's skips, a scrub committed with a click). Each one
//    is announced to the view model first (`timeToSeekAfterUserNavigatedFrom`), so the remux engine produces the
//    segment there from a key frame and the app's seeker follows and recovers it like one of its own.
//  - Channels: channel up / down (the channel buttons of a TV remote, and the system's channel gestures) goes to the
//    next or previous channel of the category, behind a full-screen card of the channel it goes to
//    (`TVChannelInterstitial`), until that channel plays.
//  - Audio and subtitles: the system's menus list the AVMediaSelection groups of the item, which include the
//    renditions the remux engine writes for raw MPEG-TS, Matroska and the other inputs it converts; a choice there
//    is remembered like one in the app's menu on iPhone (`MediaSelectionController.systemPlayerDidSelect`).
//  - Picture in Picture: the system's. The controller is kept here, outside SwiftUI, so the video goes on in the
//    corner while the player screen is closed and the app is browsed; "Full Screen" opens the screen again.
//  - Now Playing: AVKit publishes it for this controller from the item's `externalMetadata` (the app's own
//    `NowPlayingController` stays out of its way on tvOS).
//  - Menu while recording: Menu would close the player, which stops playback and with it the recording. AVKit asks
//    its delegate first (`playerViewControllerShouldDismiss`, only for the Menu that dismisses, not the one that
//    hides the transport bar or the info panel): while recording it stays, and the player asks
//    (`isConfirmingClose`).
//

#if os(tvOS)
import AVKit
import Observation
import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "TVPlayer")

/// Everything the Apple TV player shows besides the video and the system's own controls. A value: the player applies
/// what changed since the last one.
struct TVPlayerChrome: Equatable {

    /// A tab of the info panel (a swipe down on the clickpad), after the system's Info tab.
    enum Tab: String, Hashable, CaseIterable {
        /// The other channels of the category, with what each shows now: selecting one switches to it.
        case channels
        /// What is on the playing channel now and next, from the TV guide.
        case guide
        /// The other episodes of the series.
        case episodes
    }

    /// The text and artwork of what plays: the system's Info tab, the title over the transport bar, Now Playing.
    ///
    /// AVKit lays them out differently in its two places: the transport bar's title view shows the subtitle as a
    /// small line over the title, while the Info tab shows only one of them as its headline, the subtitle when there
    /// is one, else the title (seen on tvOS 27). So, as in the TV app, the title names the show (a channel, a
    /// series, a movie) and the subtitle what of it plays (the programme on now, the episode); a movie or recording
    /// has no subtitle.
    struct Metadata: Equatable {
        /// The bar's large line; the Info tab's headline when there is no subtitle.
        var title = ""
        /// The bar's small line over the title, and the Info tab's headline: it names what plays.
        var subtitle: String?
        var summary: String?
        var genre: String?
        /// The logo of the channel or the poster of the movie or episode (a playlist's artwork source).
        var artwork: String?
        var artworkIsPoster = false
    }

    /// False while an overlay of the app takes the focus (a failure, the end of a video): the transport bar would
    /// take the clickpad's presses otherwise.
    var showsPlaybackControls = true
    var fillsScreen = false
    var allowsPictureInPicture = true

    /// Transport bar: Record / Stop Recording (live channels through the engine).
    var canRecord = false
    var isRecording = false

    /// Info panel: Add to / Remove from Favorites (nil: not a playlist entry, e.g. a recording).
    var isFavorite: Bool?
    /// Info panel: Start Over (movies, episodes, recordings).
    var offersStartOver = false
    var tabs: [Tab] = []

    /// Contextual actions (the buttons that appear over the video, at the bottom right).
    var offersGoLive = false
    /// "Next Episode" during the end credits.
    var nextEpisode: ChannelItem?
    /// A seek that did not play: Try Again.
    var offersSeekRetry = false

    var metadata = Metadata()
}

/// What the views of the player's tabs and channel cards need from the app (the environment of the TV app).
struct TVPlayerServices {
    let library: ChannelLibrary
    let epg: EPGStore
    let modelContainer: ModelContainer
    let playChannel: PlayChannelAction
}

/// The app's only `AVPlayerViewController` (see the file comment).
@MainActor
@Observable
final class TVSystemPlayer: NSObject {

    static let shared = TVSystemPlayer()

    /// The transport bar is on screen: overlays of the app make room for it.
    private(set) var isTransportBarVisible = false
    /// Menu was pressed to close the player while it records: `TVPlayerView` asks whether to stop the recording.
    var isConfirmingClose = false
    /// The first video frame of the player's item is ready (`AVPlayerViewController.isReadyForDisplay`): until then
    /// the app's preroll covers the black screen.
    private(set) var isReadyForDisplay = false
    /// How many times a first video frame became ready (an item replaced inside the player screen counts again).
    /// AVKit may report "not ready" and "ready" for a new item a few milliseconds apart, faster than SwiftUI updates,
    /// so `isReadyForDisplay` can look unchanged to the view; this count still moves on.
    private(set) var readyForDisplayCount = 0

    @ObservationIgnored let playerViewController: AVPlayerViewController
    /// The controller SwiftUI shows (`TVPlayerView`): the player's parent for good, so it can leave the screen and
    /// come back (Picture in Picture) without being rebuilt.
    @ObservationIgnored let container: TVPlayerContainerController

    @ObservationIgnored private weak var viewModel: AVPlayerViewModel?
    @ObservationIgnored private var services: TVPlayerServices?
    @ObservationIgnored private var chrome: TVPlayerChrome?
    @ObservationIgnored private var tabControllers: [TVPlayerChrome.Tab: UIViewController] = [:]
    /// The item the metadata was written to, and the metadata.
    @ObservationIgnored private weak var describedItem: AVPlayerItem?
    @ObservationIgnored private var describedMetadata: TVPlayerChrome.Metadata?
    @ObservationIgnored private var describedArtwork: Data?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkCache: [String: Data] = [:]
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var readyForDisplayObservation: NSKeyValueObservation?
    /// Picture in Picture asked for the player screen: called once it is on screen.
    @ObservationIgnored private var pendingRestore: ((Bool) -> Void)?
    /// The channel change in progress: its interstice stays up until that channel plays.
    @ObservationIgnored private var zapCompletion: ((Bool) -> Void)?
    @ObservationIgnored private var zapGeneration = 0
    /// The pending `reapplyControls()` (a later return of the controls replaces it).
    @ObservationIgnored private var reapplyGeneration = 0

    private override init() {
        let controller = AVPlayerViewController()
        playerViewController = controller
        container = TVPlayerContainerController(playerViewController: controller)
        super.init()
        controller.delegate = self
        // The title (and subtitle) of what plays over the transport bar, as in the TV app.
        controller.transportBarIncludesTitleView = true
        readyForDisplayObservation = controller.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
            // The value of this change, not one read later: each transition counts, in order (the main queue keeps it).
            let newValue = change.newValue
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.readyForDisplayChanged(newValue ?? self.playerViewController.isReadyForDisplay)
                }
            }
        }
        container.onAppear = { [weak self] in
            self?.viewModel?.playerViewDidAppear()
            self?.completeRestore(true)
        }
        container.onDisappear = { [weak self] in
            self?.viewModel?.playerViewDidDisappear()
            self?.isConfirmingClose = false
        }
    }

    private func readyForDisplayChanged(_ isReady: Bool) {
        guard isReadyForDisplay != isReady else {
            return
        }
        if isReady {
            readyForDisplayCount &+= 1
        }
        logger.info("Ready for display: \(isReady, privacy: .public)")
        isReadyForDisplay = isReady
    }

    // MARK: - Configuration

    /// Connects the controller to the app's player (once per presentation; the player and services do not change).
    func attach(_ viewModel: AVPlayerViewModel, services: TVPlayerServices) {
        self.viewModel = viewModel
        self.services = services
        if playerViewController.player !== viewModel.player {
            playerViewController.player = viewModel.player
        }
        if itemObservation == nil {
            itemObservation = viewModel.player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.currentItemChanged()
                    }
                }
            }
        }
    }

    private func currentItemChanged() {
        if viewModel?.currentChannel == nil, viewModel?.isPictureInPictureActive == true {
            // Playback stopped while in Picture in Picture (Siri, a reminder's channel elsewhere): it closes.
            playerViewController.player = nil
            return
        }
        describeCurrentItem()
    }

    /// The player screen left SwiftUI. The controller keeps the player while Picture in Picture shows it.
    func screenWasDismantled() {
        guard viewModel?.isPictureInPictureActive != true else {
            return
        }
        playerViewController.player = nil
        chrome = nil
        describedItem = nil
        describedMetadata = nil
        finishZap(success: true)
    }

    /// Applies what the player shows besides the video, rebuilding only what changed.
    func apply(_ new: TVPlayerChrome) {
        let old = chrome
        chrome = new
        let controller = playerViewController
        // Turning the controls back on may drop what was set while they were off: everything is set again then, on
        // the next turn of the run loop (`reapplyControls`), once AVKit has brought its controls back. Written in the
        // same transaction, AVKit could lay its title view out a second time at the corner of the screen for a frame.
        let controlsReturned = old?.showsPlaybackControls == false && new.showsPlaybackControls
        if controller.showsPlaybackControls != new.showsPlaybackControls {
            controller.showsPlaybackControls = new.showsPlaybackControls
            // Without its controls the player takes no focus (nor the clickpad's presses): the app's buttons over it do.
            controller.view.isUserInteractionEnabled = new.showsPlaybackControls
            container.setNeedsFocusUpdate()
        }
        let gravity: AVLayerVideoGravity = new.fillsScreen ? .resizeAspectFill : .resizeAspect
        if controller.videoGravity != gravity {
            controller.videoGravity = gravity
        }
        if controller.allowsPictureInPicturePlayback != new.allowsPictureInPicture {
            controller.allowsPictureInPicturePlayback = new.allowsPictureInPicture
        }
        if controlsReturned {
            reapplyGeneration &+= 1
            let generation = reapplyGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reapplyGeneration == generation else {
                    return
                }
                self.reapplyControls()
            }
        } else {
            if old?.canRecord != new.canRecord || old?.isRecording != new.isRecording || old?.fillsScreen != new.fillsScreen {
                controller.transportBarCustomMenuItems = transportBarItems(new)
            }
            if old?.isFavorite != new.isFavorite || old?.offersStartOver != new.offersStartOver {
                controller.infoViewActions = infoViewActions(new)
            }
            if old?.tabs != new.tabs {
                controller.customInfoViewControllers = new.tabs.compactMap(tabController)
            }
            if old?.offersGoLive != new.offersGoLive || old?.nextEpisode != new.nextEpisode || old?.offersSeekRetry != new.offersSeekRetry {
                controller.contextualActions = contextualActions(new)
            }
        }
        if old?.metadata != new.metadata {
            describeCurrentItem()
        }
    }

    /// Sets the transport bar's buttons, the info panel's actions and tabs and the contextual actions again, from the
    /// chrome applied last (after the controls came back).
    private func reapplyControls() {
        guard let chrome, chrome.showsPlaybackControls else {
            return
        }
        let controller = playerViewController
        controller.transportBarCustomMenuItems = transportBarItems(chrome)
        controller.infoViewActions = infoViewActions(chrome)
        controller.customInfoViewControllers = chrome.tabs.compactMap(tabController)
        controller.contextualActions = contextualActions(chrome)
    }

    // MARK: - Transport bar, info panel, contextual actions

    private func transportBarItems(_ chrome: TVPlayerChrome) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if chrome.canRecord || chrome.isRecording {
            let title = chrome.isRecording
                ? String(localized: "Stop Recording", comment: "Apple TV player, transport bar button: stops recording the live channel.")
                : String(localized: "Record", comment: "Apple TV player, transport bar button: starts recording the live channel.")
            items.append(UIAction(
                title: title,
                image: UIImage(systemName: chrome.isRecording ? "stop.circle.fill" : "record.circle"),
                identifier: UIAction.Identifier("fluxo.player.record"),
                attributes: chrome.isRecording ? .destructive : []
            ) { [weak self] _ in
                self?.toggleRecording()
            })
        }
        let fit = UIAction(
            title: String(localized: "Fit to Screen", comment: "Apple TV player, Picture menu: shows the whole picture, with black bars when its shape differs from the TV's."),
            image: UIImage(systemName: "rectangle.arrowtriangle.2.inward"),
            state: chrome.fillsScreen ? .off : .on
        ) { [weak self] _ in
            self?.setFillsScreen(false)
        }
        let fill = UIAction(
            title: String(localized: "Fill Screen", comment: "Apple TV player, Picture menu: zooms the picture to fill the TV, cutting its edges."),
            image: UIImage(systemName: "rectangle.arrowtriangle.2.outward"),
            state: chrome.fillsScreen ? .on : .off
        ) { [weak self] _ in
            self?.setFillsScreen(true)
        }
        items.append(UIMenu(
            title: String(localized: "Picture", comment: "Apple TV player, transport bar menu: how the picture fits the screen."),
            image: UIImage(systemName: "aspectratio"),
            identifier: UIMenu.Identifier("fluxo.player.picture"),
            options: [.singleSelection],
            children: [fit, fill]
        ))
        return items
    }

    private func infoViewActions(_ chrome: TVPlayerChrome) -> [UIAction] {
        var actions: [UIAction] = []
        if chrome.offersStartOver {
            actions.append(UIAction(
                title: String(localized: "Start Over", comment: "Apple TV player, info panel button: plays the movie or episode from the beginning."),
                image: UIImage(systemName: "backward.end.fill")
            ) { [weak self] _ in
                self?.viewModel?.seek(toSeconds: 0)
                self?.viewModel?.play()
            })
        }
        if let isFavorite = chrome.isFavorite {
            actions.append(UIAction(
                title: isFavorite
                    ? String(localized: "Remove from Favorites", comment: "Apple TV player, info panel button.")
                    : String(localized: "Add to Favorites", comment: "Apple TV player, info panel button."),
                image: UIImage(systemName: isFavorite ? "star.slash" : "star")
            ) { [weak self] _ in
                self?.toggleFavorite()
            })
        }
        // The info view shows two actions at most.
        return Array(actions.prefix(2))
    }

    private func contextualActions(_ chrome: TVPlayerChrome) -> [UIAction] {
        var actions: [UIAction] = []
        if chrome.offersSeekRetry {
            actions.append(UIAction(
                title: String(localized: "Try Again", comment: "Apple TV player, button over the video after a seek that could not play: seeks there again."),
                image: UIImage(systemName: "arrow.clockwise")
            ) { [weak self] _ in
                self?.viewModel?.retrySeek()
            })
        }
        if chrome.offersGoLive {
            actions.append(UIAction(
                title: String(localized: "Go Live", comment: "Apple TV player, button over the video of a time-shifted live channel: jumps to the live broadcast."),
                image: UIImage(systemName: "forward.end.alt.fill")
            ) { [weak self] _ in
                self?.viewModel?.goLive()
            })
        }
        if let next = chrome.nextEpisode {
            actions.append(UIAction(
                title: String(localized: "Next Episode", comment: "Apple TV player, button over the video during the end credits of an episode: plays the next one."),
                image: UIImage(systemName: "forward.end.fill")
            ) { [weak self] _ in
                self?.playNextEpisode(next)
            })
        }
        return actions
    }

    private func tabController(_ tab: TVPlayerChrome.Tab) -> UIViewController? {
        if let controller = tabControllers[tab] {
            return controller
        }
        guard let viewModel, let services else {
            return nil
        }
        let controller = UIHostingController(rootView: AnyView(
            TVPlayerTabContent(tab: tab, viewModel: viewModel)
                .tvPlayerServices(services)
        ))
        controller.title = tab.title
        controller.preferredContentSize = CGSize(width: 1_920, height: TVPlayerTabContent.height(of: tab))
        controller.view.backgroundColor = .clear
        tabControllers[tab] = controller
        return controller
    }

    private func toggleRecording() {
        guard let viewModel else {
            return
        }
        // `PlayerAnnouncements` tells VoiceOver when the recording starts or stops.
        viewModel.toggleRecording()
    }

    private func toggleFavorite() {
        guard let item = viewModel?.currentItem, let library = services?.library else {
            return
        }
        let wasFavorite = library.isFavorite(item)
        library.toggleFavorite(item)
        AccessibilityAnnouncer.announce(wasFavorite
            ? String(localized: "Removed from Favorites", comment: "VoiceOver, Apple TV player: the channel or video was removed from the favorites.")
            : String(localized: "Added to Favorites", comment: "VoiceOver, Apple TV player: the channel or video was added to the favorites."))
    }

    private func setFillsScreen(_ fills: Bool) {
        guard let viewModel, viewModel.fillsScreen != fills else {
            return
        }
        viewModel.toggleFillsScreen()
    }

    private func playNextEpisode(_ next: ChannelItem) {
        if let ref = next.series {
            AccessibilityAnnouncer.announce(String(localized: "Playing \(EpisodeFormat.spokenCode(ref))", comment: "VoiceOver: the next episode starts; the placeholder is its season and episode, as in 'Season 1, episode 4'."))
        }
        services?.playChannel(next)
    }

    // MARK: - Metadata

    /// Writes the metadata to the item that plays (the system's Info tab, the title view, Now Playing). A new item
    /// gets it as soon as it is the player's.
    private func describeCurrentItem() {
        guard let item = viewModel?.player.currentItem, let metadata = chrome?.metadata else {
            return
        }
        if item === describedItem, metadata == describedMetadata {
            return
        }
        let artworkChanged = metadata.artwork != describedMetadata?.artwork || item !== describedItem
        describedItem = item
        describedMetadata = metadata
        if artworkChanged {
            describedArtwork = metadata.artwork.flatMap { artworkCache[$0] }
            loadArtwork(metadata)
        }
        item.externalMetadata = Self.metadataItems(metadata, artwork: describedArtwork)
    }

    private func loadArtwork(_ metadata: TVPlayerChrome.Metadata) {
        artworkTask?.cancel()
        guard let source = metadata.artwork, artworkCache[source] == nil else {
            return
        }
        // The size of the artwork of the info panel (a poster is 2:3, a logo sits on a 16:9 tile).
        let size = metadata.artworkIsPoster ? CGSize(width: 400, height: 600) : CGSize(width: 640, height: 360)
        guard let request = LogoRequest(source: source, pointSize: size, scale: 1, contentMode: metadata.artworkIsPoster ? .fill : .fit) else {
            return
        }
        artworkTask = Task { [weak self] in
            guard let image = await LogoImageLoader.shared.image(for: request), !Task.isCancelled,
                  let data = UIImage(cgImage: image).pngData() else {
                return
            }
            guard let self, self.describedMetadata?.artwork == source, let item = self.describedItem, let described = self.describedMetadata else {
                return
            }
            self.artworkCache[source] = data
            self.describedArtwork = data
            item.externalMetadata = Self.metadataItems(described, artwork: data)
        }
    }

    private static func metadataItems(_ metadata: TVPlayerChrome.Metadata, artwork: Data?) -> [AVMetadataItem] {
        var items = [textItem(.commonIdentifierTitle, metadata.title)]
        if let subtitle = metadata.subtitle, !subtitle.isEmpty {
            items.append(textItem(.iTunesMetadataTrackSubTitle, subtitle))
        }
        if let summary = metadata.summary, !summary.isEmpty {
            items.append(textItem(.commonIdentifierDescription, summary))
        }
        if let genre = metadata.genre, !genre.isEmpty {
            items.append(textItem(.quickTimeMetadataGenre, genre))
        }
        if let artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.value = artwork as NSData
            item.dataType = kCMMetadataBaseDataType_PNG as String
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        return items
    }

    private static func textItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    // MARK: - Channel changes

    /// The channel `offset` places away in the category (nil when there is none, or zapping is not possible now).
    private func neighbor(offset: Int) -> ChannelItem? {
        guard let viewModel, viewModel.canZap, let item = viewModel.currentItem else {
            return nil
        }
        return viewModel.zapper?.neighbor(of: item, offset: offset)
    }

    private func interstitial(offset: Int) -> UIViewController {
        let target = neighbor(offset: offset)
        let view = TVChannelInterstitial(item: target, isRecording: viewModel?.isRecording == true)
        let controller = UIHostingController(rootView: AnyView(services.map { view.tvPlayerServices($0) } ?? AnyView(view)))
        controller.view.backgroundColor = .black
        return controller
    }

    /// Plays the channel `offset` places away; the interstice stays up until it plays (or fails), at most 8 s.
    private func zap(by offset: Int, completion: @escaping (Bool) -> Void) {
        guard let viewModel, let target = neighbor(offset: offset) else {
            completion(false)
            return
        }
        // A newer change replaces the one in progress (each request moves one more channel).
        finishZap(success: true)
        zapCompletion = completion
        zapGeneration &+= 1
        let generation = zapGeneration
        logger.info("Channel \(offset > 0 ? "up" : "down", privacy: .public) to \(target.displayName, privacy: .private)")
        viewModel.zap(by: offset)
        Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.zapGeneration == generation else {
                    return
                }
                switch self.viewModel?.playbackState {
                case .playing, .paused, .failed, .ended, .idle, .none:
                    self.finishZap(success: true)
                    return
                default:
                    continue
                }
            }
            self?.finishZap(success: true)
        }
    }

    private func finishZap(success: Bool) {
        let completion = zapCompletion
        zapCompletion = nil
        completion?(success)
    }

    // MARK: - Picture in Picture

    private func completeRestore(_ restored: Bool) {
        let completion = pendingRestore
        pendingRestore = nil
        completion?(restored)
    }

    #if DEBUG
    /// Debug harness (`tv-seek:`): a seek of the transport bar to `seconds`, the way AVKit makes it (it asks the
    /// delegate where to go, then seeks AVPlayer itself, exactly).
    func debugNavigate(to seconds: TimeInterval) {
        guard let player = viewModel?.player else {
            return
        }
        let from = player.currentTime()
        let to = CMTime(seconds: seconds, preferredTimescale: 600)
        let time = playerViewController(playerViewController, timeToSeekAfterUserNavigatedFrom: from, to: to)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
    }

    /// Debug harness (`pause`): what the system player shows besides the video, for the log.
    var debugSummary: String {
        let controller = playerViewController
        func titles(_ elements: [UIMenuElement]) -> String {
            elements.map { ($0 as? UIMenu).map { "\($0.title) [\(titles($0.children))]" } ?? $0.title }.joined(separator: ", ")
        }
        return "transport bar [\(titles(controller.transportBarCustomMenuItems))] info actions [\(titles(controller.infoViewActions))]"
            + " contextual [\(titles(controller.contextualActions))] tabs [\(controller.customInfoViewControllers.compactMap(\.title).joined(separator: ", "))]"
            + " controls \(controller.showsPlaybackControls) PiP allowed \(controller.allowsPictureInPicturePlayback) supported \(AVPictureInPictureController.isPictureInPictureSupported())"
            + " behind live \(viewModel.map { String(format: "%.1f", $0.timeBehindLiveEdge) } ?? "-") s (time shift \(viewModel?.isTimeShiftAvailable == true), at edge \(viewModel?.timeline.isAtLiveEdge == true))"
    }

    /// Debug harness (`tv-panel:`): a tab of the info panel as AVKit lays it out (its content under the tab bar, on
    /// the panel's material), for screenshots: the Siri Remote's swipe that opens the panel cannot be scripted.
    func debugPanel(_ tab: TVPlayerChrome.Tab) -> UIViewController? {
        guard let viewModel, let services else {
            return nil
        }
        let tabs = chrome?.tabs ?? [tab]
        let controller = UIHostingController(rootView: AnyView(
            TVDebugInfoPanel(tabs: tabs, selected: tab, height: TVPlayerTabContent.height(of: tab)) {
                TVPlayerTabContent(tab: tab, viewModel: viewModel)
            }
            .tvPlayerServices(services)
        ))
        controller.view.backgroundColor = .clear
        controller.modalPresentationStyle = .overFullScreen
        return controller
    }

    /// Debug harness (`tv-zap:`): the interstice of the next (`offset` 1) or previous channel, and the change.
    /// - Parameter completion: called when AVKit would take the interstice away (the channel plays, or 8 s passed).
    func debugZap(by offset: Int, completion: @escaping (Bool) -> Void) -> UIViewController? {
        guard neighbor(offset: offset) != nil else {
            return nil
        }
        let interstitial = interstitial(offset: offset)
        zap(by: offset, completion: completion)
        return interstitial
    }
    #endif
}

// MARK: - AVPlayerViewControllerDelegate

// AVKit calls its delegate on the main thread.
extension TVSystemPlayer: @MainActor AVPlayerViewControllerDelegate {

    func playerViewController(_ playerViewController: AVPlayerViewController, timeToSeekAfterUserNavigatedFrom oldTime: CMTime, to targetTime: CMTime) -> CMTime {
        guard let viewModel, targetTime.isNumeric else {
            return targetTime
        }
        let seconds = viewModel.systemPlayerWillSeek(from: oldTime.isNumeric ? oldTime.seconds : 0, to: targetTime.seconds)
        return seconds == targetTime.seconds ? targetTime : CMTime(seconds: seconds, preferredTimescale: 600)
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, didSelect mediaSelectionOption: AVMediaSelectionOption?, in mediaSelectionGroup: AVMediaSelectionGroup) {
        viewModel?.mediaSelection.systemPlayerDidSelect(mediaSelectionOption, in: mediaSelectionGroup)
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, willTransitionToVisibilityOfTransportBar visible: Bool, with coordinator: any AVPlayerViewControllerAnimationCoordinator) {
        coordinator.addCoordinatedAnimations({ [weak self] in
            self?.isTransportBarVisible = visible
        }, completion: nil)
    }

    // Channel up / down.

    func playerViewController(_ playerViewController: AVPlayerViewController, skipToNextChannel completion: @escaping (Bool) -> Void) {
        zap(by: 1, completion: completion)
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, skipToPreviousChannel completion: @escaping (Bool) -> Void) {
        zap(by: -1, completion: completion)
    }

    func nextChannelInterstitialViewController(for playerViewController: AVPlayerViewController) -> UIViewController {
        interstitial(offset: 1)
    }

    func previousChannelInterstitialViewController(for playerViewController: AVPlayerViewController) -> UIViewController {
        interstitial(offset: -1)
    }

    // Picture in Picture.

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        // The controller is embedded in SwiftUI's full-screen cover: the view model closes the screen itself.
        false
    }

    func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        guard viewModel?.isRecording == true else {
            return true
        }
        // Closing the player would stop the recording: `TVPlayerView` asks first (Stop Recording or Keep Recording).
        logger.info("Menu while recording: asking before closing the player")
        isConfirmingClose = true
        return false
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        viewModel?.systemPictureInPictureDidChange(true)
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        viewModel?.systemPictureInPictureDidChange(false)
        if viewModel?.isPresented != true {
            // Closed from its menu: nothing shows the video any more, playback stops.
            screenWasDismantled()
            viewModel?.playerScreenDidClose()
        }
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: any Error) {
        logger.error("Picture in Picture did not start: \(error.localizedDescription, privacy: .public)")
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard viewModel?.restoreFromSystemPictureInPicture() == true else {
            completionHandler(false)
            return
        }
        completeRestore(false)
        pendingRestore = completionHandler
        if container.viewIfLoaded?.window != nil {
            completeRestore(true)
        }
        // Never leave Picture in Picture waiting when the screen cannot appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.completeRestore(true)
        }
    }
}

/// The player's parent, which SwiftUI shows full screen: it hands the focus to the player and tells the view model
/// when the video is on screen (the display then stays awake while it plays, see `PlaybackEnergyProfile`).
final class TVPlayerContainerController: UIViewController {

    let playerViewController: AVPlayerViewController
    var onAppear: (() -> Void)?
    var onDisappear: (() -> Void)?

    init(playerViewController: AVPlayerViewController) {
        self.playerViewController = playerViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(playerViewController)
        playerViewController.view.frame = view.bounds
        playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerViewController.view)
        playerViewController.didMove(toParent: self)
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        [playerViewController]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

#if DEBUG
/// The look of the system's info panel around a tab's content (`debugPanel(_:)`).
private struct TVDebugInfoPanel<Content: View>: View {
    let tabs: [TVPlayerChrome.Tab]
    let selected: TVPlayerChrome.Tab
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 28) {
                // The system's tab (a debug-only mock-up of it: not localized).
                Text(verbatim: "Info")
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
                ForEach(tabs, id: \.self) { tab in
                    Text(tab.title)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                        .background(tab == selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.clear), in: .capsule)
                        .foregroundStyle(tab == selected ? .black : .white)
                }
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 80)
            .padding(.top, 50)
            content()
                .frame(height: height)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}
#endif

extension TVPlayerChrome.Tab {
    /// The tab's title in the info panel.
    var title: String {
        switch self {
        case .channels:
            String(localized: "Channels", comment: "Apple TV player, info panel tab: the other channels of the category.")
        case .guide:
            String(localized: "Guide", comment: "Apple TV player, info panel tab: what is on the channel now and next.")
        case .episodes:
            String(localized: "Episodes", comment: "Apple TV player, info panel tab: the episodes of the series.")
        }
    }
}

extension View {
    /// The environment of the TV app, for views AVKit hosts (the info panel's tabs, the channel interstice).
    func tvPlayerServices(_ services: TVPlayerServices) -> AnyView {
        AnyView(self
            .environment(services.library)
            .environment(services.epg)
            .environment(\.playChannel, services.playChannel)
            .modelContainer(services.modelContainer)
            .defaultAppStorage(.fluxo)
            .tint(Theme.accent))
    }
}
#endif
