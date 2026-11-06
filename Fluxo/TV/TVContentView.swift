//
//  TVContentView.swift
//  Fluxo
//
//  The root of the Apple TV app: the top tab bar (Search, Home, Live TV, Movies, Series, Library and Settings) over
//  full-screen pages, and the system player on top of them. Live TV is the TV guide grid (the iPhone's Guide tab,
//  `AppNavigation.Tab.guide`, so App Intents and Full Guide reach it); Movies and Series have tabs of their own on
//  the TV, where the iPhone switches between them on Home. Search comes first, as in the TV app.
//
//  It sets up what `ContentView` sets up on iPhone, iPad and Mac, minus what the TV has no use for (the mini player,
//  drag and drop, Copy Link, offline downloads, several windows, the foldable posture): the playlist and guide
//  sheets, watch progress, VoiceOver announcements, reminders, the play action every card uses, App Intents
//  navigation, the Top Shelf of the Home Screen (`TopShelfPublisher`, `TopShelfLinks`) and the debug harness. The
//  pages are in `Fluxo/TV` (`TVHomeScreen`, `TVGuideScreen`, `TVKindScreen`,
//  `TVLibraryScreen`, `TVSearchScreen`, `TVSettingsScreen`); the player is `TVPlayerView`.
//
//  Everything in Fluxo/TV is compiled for tvOS only (each file is wrapped in `#if os(tvOS)`): the iPhone, iPad and
//  Mac screens are touch and pointer layouts (swipe actions, drags, hover, context menus) that the TV replaces with
//  focus-driven ones.
//

#if os(tvOS)
import SwiftData
import SwiftUI

struct TVContentView: View {

    let viewModel: AVPlayerViewModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(ChannelLibrary.self) private var library
    @Environment(EPGStore.self) private var epg
    @Environment(WindowCoordinator.self) private var coordinator
    @Environment(CloudSync.self) private var cloudSync
    /// The selected tab and the search text, shared with App Intents and the debug routes.
    @State private var navigation: AppNavigation
    /// Identifies the window to the `WindowCoordinator` (Apple TV has one).
    @State private var windowID = UUID()

    init(viewModel: AVPlayerViewModel, navigation: AppNavigation) {
        self.viewModel = viewModel
        _navigation = State(initialValue: navigation)
    }

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab("Search", systemImage: "magnifyingglass", value: AppNavigation.Tab.search, role: .search) {
                TVSearchScreen()
                    .tvPageBackground()
            }

            // Titles without symbols, as tvOS tab bars show them: seven tabs fit across the screen that way.
            Tab(value: AppNavigation.Tab.home) {
                TVHomeScreen()
                    .tvPageBackground()
            } label: {
                Text("Home")
            }

            Tab(value: AppNavigation.Tab.guide) {
                TVGuideScreen()
                    .tvPageBackground()
            } label: {
                Text(String(localized: "Live TV"))
            }

            Tab(value: AppNavigation.Tab.movies) {
                TVKindScreen(kind: .movie)
                    .tvPageBackground()
            } label: {
                Text(ChannelContentKind.movie.title)
            }

            Tab(value: AppNavigation.Tab.series) {
                TVKindScreen(kind: .series)
                    .tvPageBackground()
            } label: {
                Text(ChannelContentKind.series.title)
            }

            Tab(value: AppNavigation.Tab.library) {
                TVLibraryScreen(player: viewModel)
                    .tvPageBackground()
            } label: {
                Text(LibraryText.title)
            }

            Tab(value: AppNavigation.Tab.settings) {
                TVSettingsScreen(player: viewModel)
                    .tvPageBackground()
            } label: {
                Text("Settings")
            }
        }
        // The system player, full screen. Menu on the Siri Remote (or the TV remote's Back) closes it: playback
        // stops, as in the TV app (there is no mini player on Apple TV).
        .fullScreenCover(isPresented: isPlayerPresented, onDismiss: playerDidDismiss) {
            TVPlayerView(viewModel: viewModel)
                // On-screen awareness: Siri knows the channel on screen ("Add this to my favorites in Fluxo").
                .appEntityIdentifier(viewModel.currentItem.flatMap(ChannelEntity.entityIdentifier(for:)))
        }
        // Siri or a link opened a tab while the player (or a link's alert) covered the tab bar: the focus given back
        // as it goes away must not select the tab it had before (`AppNavigation.keepTab(for:)`).
        .onChange(of: navigation.tab) {
            navigation.tabDidChange()
        }
        .reminderAlert(epg.reminders)
        .playlistManagement()
        // "Your Playlists from iCloud": the playlists of the user's other devices, without typing an address.
        .cloudPlaylistImport()
        .guideManagement(epg)
        .watchProgressRecording(player: viewModel)
        .playerAnnouncements(viewModel)
        // The Top Shelf of the Home Screen: what it shows (written for the FluxoTopShelf extension), and its links.
        .topShelfPublishing(player: viewModel)
        .topShelfLinks(player: viewModel)
        .environment(\.playChannel, PlayChannelAction(library: library, player: viewModel, coordinator: coordinator, windowID: windowID))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.sceneDidBecomeActive()
                cloudSync.sceneDidBecomeActive()
            } else if phase == .background {
                EPGBackgroundRefresh.schedule()
                cloudSync.sceneDidEnterBackground()
            }
        }
        .task(id: epg.reminders.channelToOpen) {
            // A reminder was opened (Watch in its alert): play its channel.
            guard let channel = epg.reminders.channelToOpen else {
                return
            }
            epg.reminders.channelToOpen = nil
            PlayChannelAction(library: library, player: viewModel, coordinator: coordinator, windowID: windowID)(channel)
        }
        #if DEBUG
        .debugAutoplay(viewModel)
        .debugSnapshots()
        .debugHarness(player: viewModel, navigation: navigation)
        #endif
        .environment(navigation)
        .windowPresentation(.player, isActive: viewModel.isPresented)
        .windowScene(windowID, kind: .main, coordinator: coordinator, navigation: navigation)
        .defaultAppStorage(.fluxo)
        .tint(Theme.accent)
    }

    private var isPlayerPresented: Binding<Bool> {
        Binding {
            viewModel.isPresented
        } set: { isPresented in
            // The cover also sets this when the model closed it (Siri, a link): only Menu finds it still presented.
            if !isPresented, viewModel.isPresented {
                // Menu: the viewer is the one moving now, nothing is kept for them.
                navigation.releaseKeptTab()
                viewModel.closePlayer()
            }
        }
    }

    /// The player's cover is gone: playback stops (Apple TV has no mini player), and the tab Siri or a link opened
    /// behind it is kept while tvOS gives the focus back.
    private func playerDidDismiss() {
        viewModel.stop()
        navigation.coverDidDismiss(keepingFor: AppServices.keptTabDuration)
    }
}

private extension View {
    /// The alert of a reminder that is due (Apple TV shows reminders itself, see `InAppReminderAlerts`).
    func reminderAlert(_ reminders: ReminderCenter) -> some View {
        modifier(ReminderAlertModifier(reminders: reminders))
    }
}

private struct ReminderAlertModifier: ViewModifier {
    let reminders: ReminderCenter

    func body(content: Content) -> some View {
        let reminder = reminders.dueReminder
        content
            .alert(
                reminder?.title ?? "",
                isPresented: Binding {
                    reminders.dueReminder != nil
                } set: { isPresented in
                    if !isPresented {
                        reminders.dismissDueReminder()
                    }
                },
                presenting: reminder
            ) { _ in
                Button(String(localized: "Watch", comment: "Button (verb): play the channel. Also the button of a programme reminder (a notification, or the alert on Apple TV): plays the channel of the programme that is about to start.")) {
                    reminders.openDueReminder()
                }
                Button(String(localized: "Not Now", comment: "Button of a programme reminder on Apple TV: closes the reminder without playing the channel."), role: .cancel) {
                    reminders.dismissDueReminder()
                }
            } message: { reminder in
                // Worded when it shows: the time left then, not the lead time it was set with.
                Text(TextParts.sentences([reminder.channelName, reminder.body(at: .now)]))
            }
    }
}
#endif
