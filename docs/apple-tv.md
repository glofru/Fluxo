# Apple TV

Fluxo runs on Apple TV (tvOS 26 and later) from the same target as the iPhone, iPad and Mac app. The shared code
(the store, playlist import, the remux engine and its loopback server, the player view model, the TV guide,
search, recommendations, recordings, App Intents) is compiled for tvOS as it is; the screens are the TV's own
(`Fluxo/TV`): a 10-foot interface made for the focus engine and the Siri Remote, not the iPad layout on a bigger
screen.

## One multiplatform target

tvOS was added to the existing `Fluxo` target (`SUPPORTED_PLATFORMS`, `TVOS_DEPLOYMENT_TARGET = 26.0`, device
family 3 for the tvOS SDKs) rather than to a target of its own:

- **One app record**: the same bundle identifier (`dev.watermelon.Fluxo`) on every platform is what universal
  purchase needs: one App Store product, bought once for iPhone, iPad, Mac and Apple TV. A second target would have
  to repeat it anyway. The Mac's Release build is team-signed for the Mac App Store (see [Building](building.md)); it has no
  iCloud sync yet.
- **The same pattern as macOS**: the target already builds two platforms, with the differences as SDK-conditional
  settings (`[sdk=macosx*]`); tvOS adds its own: its Info.plist (`Fluxo/Info-tvOS.plist`), app icon (below) and
  device family. Packages filter by platform (Google Cast stays iOS only; FFmpeg is linked on iOS, macOS and tvOS).
  The entitlements file is `Fluxo/Fluxo-tvOS.entitlements`: the iCloud keys of the iOS one plus the Top Shelf App
  Group.
- **No second list of files**: the target uses a file-system synchronized group, so every new file builds for every
  platform, and a change that does not compile on one fails at once instead of drifting in a target nobody builds.
  A second target would need its own membership exceptions for every iOS-only file, kept in step by hand.
- **One scheme**: every platform builds with `-scheme Fluxo` and a destination.

The cost is that code which exists on one platform only says so in the source: files of the TV screens are wrapped in
`#if os(tvOS)` (a platform filter on the `TV` folder is ignored by the synchronized group, checked with Xcode 27.2), and the touch and pointer
screens that Apple TV replaces in `#if !os(tvOS)`: the iPhone / iPad / Mac player (`Features/Watch`), the root of their
windows (`ContentView`, `MacRootView`), the iPad player windows, the menu bar commands, the Cast button and picker.

## What tvOS does not have

What a platform can do is answered in one place, `App/Platform/PlatformFeatures.swift`, and features ask it instead of
testing the operating system; the APIs tvOS lacks are compiled out only in the file that calls them.

| Capability | On Apple TV |
|---|---|
| Offline downloads (`offlineDownloads`) | Off. tvOS keeps only a small amount of an app's data for sure and may delete everything else (caches) when it needs space, so a downloaded movie could be gone when it is watched; `AVAssetDownloadURLSession` and the storage priorities that protect downloads do not exist there. `DownloadCenter` starts empty and `canDownload` is false, so no screen offers Download. |
| Clipboard (`pasteboard`) | None: Copy Link, Share and the Paste button of Add Playlist are not shown. |
| Notifications with text (`textNotifications`) | tvOS notifications only badge the icon. Reminders are delivered by `ReminderDelivery`: system notifications on iPhone, iPad and Mac (`SystemReminderNotifications`), an alert in the app on Apple TV (`InAppReminderAlerts`, one timer for the next reminder, armed again at launch from the stored reminders), with Watch and Not Now, over the player too. Reminders due together show one after the other, worded with the time actually left ("Started at 20:15." once it has started); one whose programme ended while Fluxo was in the background (no timer runs then) is dropped. |
| On-device model (`onDeviceLanguageModel`) | Foundation Models has no language model on tvOS: `FluxoIntelligence` reports the device as not eligible, and recommendations, smart search and summaries use their built-in fallbacks. |
| Spotlight (`spotlightIndexing`) | No app content in tvOS search: channels are not indexed; the Siri phrases with channel names still update. |
| Files and drag and drop (`files`) | No Files app or document picker: Load Subtitle File… and dropped playlists are not offered. |
| Chromecast | `CastController.isSupported` is false (no Google Cast SDK for tvOS, and the Apple TV is the screen). |
| Several windows, foldable layouts, iPad sidebar | One window; the posture of the iPhone Duo and the iPad-only layouts do not apply. |
| Storage for recordings | No Documents folder for apps: recordings go to `Caches/Recordings` (`PlatformStorage.userFilesDirectory`), which tvOS may empty when it runs out of space. |

SwiftUI modifiers that tvOS marks unavailable (swipe actions, row separators, text selection, inspectors, the
inset list styles) go through helpers in `View+Platform.swift` (`rowSwipeActions`, `rowSeparatorHidden`,
`selectableText`, `sideInspector`, `groupedListStyle`) that apply them where they exist; the guide's background
refresh (`BGAppRefreshTask`) runs on tvOS too.

## The TV app (`Fluxo/TV`)

- **Root** (`TVContentView`): the tvOS top tab bar, titles only as tvOS shows them: Search (first, as in the TV app),
  Home, Live TV, Movies, Series, Library and Settings. It is driven by `AppNavigation.tab` (Live TV is the `.guide` tab
  of the iPhone; Movies and Series are tvOS-only cases), so App Intents, Show in TV Guide and the debug routes move it.
  It sets up what `ContentView` sets up elsewhere: the playlist and guide sheets, the "Your Playlists from iCloud"
  cover and iCloud sync on activation and suspension (see [iCloud sync](icloud-sync.md)), watch progress, VoiceOver announcements, the
  reminder alert, the play action of every card and the debug harness. The app-wide sheets and alerts (a due reminder,
  the playlist sheets and the Delete Playlist and Playlist Error alerts, the TV guide picker and its errors, the alert
  of a link that could not open) show over the top-most screen: over the player while it is up, and playback goes on
  under them. Presented from the tab bar under the full-screen player, SwiftUI would dismiss the player to show them,
  and closing the player stops playback. So both the tab bar and the player present them (`appModals`), and an
  `AppModalsGate` in the environment opens exactly one: the player's while it is up, the tab bar's once the player's
  cover has finished closing. The gate is a check, not a stored value, because SwiftUI calls the setter of a
  presentation's binding when it is handed over, sometimes a binding made before the hand-over: the setter asks the
  gate again and leaves the request for the other presenter. iPhone, iPad and Mac have one presenter per window and
  an always-open gate. Every page draws its own
  background (`tvPageBackground()`), which the hero and the series page fade into.
- **Layout** (`TVComponents.swift`): pages ignore the safe area so artwork runs to the edges of the picture, and keep
  text and controls 80 points from the sides (`TVLayout.margin`, the overscan-safe inset; 60 at the top and bottom).
  Cards (`TVCard`) are the system's card button style (lift, tilt and light under focus) on the artwork only, with the
  title beneath it, which moves down while the card is focused, as in the TV app; each card is one VoiceOver element
  with a label and a hint, and has a long-press menu (play, Record on live channels the engine plays, favorite, Show
  in TV Guide, Go to Series, Remove from History). Landscape cards (400 × 225) for channels, Continue Watching, On Now and episodes; posters (248 × 372) for
  movies and series. A channel's logo sits on an opaque tile (nothing under a card or a sheet shows through it):
  graphite, or light for a logo of dark lettering on a transparent background, which would vanish on graphite (the
  Top Shelf's rule, `LogoTone`). Shelves (`TVShelf`) are focus sections that scroll edge to edge; long ones end with a
  See All card (Continue Watching's only when the history has more than it shows, and on the Movies and Series pages
  it opens the history of that kind only). Action buttons are Liquid Glass (`.glassProminent` for the main one); their
  titles are white on the accent and on the glass, and the brand's ink once focused, on the light platter the focus
  turns them into (where the styles' violet title was about 2.6:1, `TVActionLabelStyle`). Every empty page says what to do and has the
  button that does it (Add Playlist, Add Guide Source, Show Channels).
- **Home** (`TVHomeScreen`, `TVHero`): a full-bleed hero of featured movies, series and channels (the picks of the
  iPhone billboard, `FeaturedCarousel.loadPicks`, see "Featured") under the tab bar: blurred backdrop, poster, title,
  Play (Resume S1 E3, Watch Live), Episodes, favorite, and page dots. Its pages sit side by side, so moving the focus
  past the last button pages on; while the focus is elsewhere it moves on by itself every 9 s (not with Reduce
  Motion). Entering the hero, down from any tab or up from the shelves, lands on the Play of the page on screen, also
  while it pages (each page is a focus section as wide as the screen; `HomeHeroFocusTests` checks it with the Siri
  Remote). Then Continue Watching (a series once, with the episode to watch now and Up Next once one is finished),
  Favorites (channels and series), On Now (from the guide, ending with a TV Guide card), and the first live, movie and
  series categories. It follows the playlist selection, which Settings changes.
- **Live TV** (`TVGuideScreen`): Guide or Channels. The guide is a grid of channels × time for the focus engine: a
  two-hour window (starting a quarter of an hour before now) with the channel column and the time ruler fixed and the
  rows scrolling. Each programme is a button as wide as its time in the window, so swiping moves across a channel's
  programmes and up or down to what airs at the same time on the next channel. The narrow cells at the ends of each
  row move the window an hour back or on and focus the programme that came into view (`TVGuideModel`); Earlier, Now,
  Later and the day menu above jump further, and the category menu filters. A line marks now, behind the programmes' opaque tiles, so it shows between
  them and never crosses a title; programmes on air are tinted with their progress, ended ones dimmed. A channel's
  number is on its logo, so its name has two lines in every script; the day and category menus say what they choose
  to VoiceOver ("Day, Today"). Selecting a programme opens it full screen (Watch Now or Watch
  Channel, Record, Remind Me, and what follows on the channel, each with its own reminder; after a programme that
  ended, "Later on" lists what the channel shows from now, the programme on air marked LIVE, and selecting it plays
  the channel); Play/Pause plays the
  channel; selecting a channel's name plays it. Record (a programme on air, on a channel the engine plays: not one
  AVPlayer plays straight from HLS) plays the channel and starts recording as soon as its stream is open
  (`PlayChannelAction.playAndRecord`, as Siri's "Record this"); while the channel records (Picture in Picture), the
  sheet shows REC with the duration and Stop Recording. Watch and Record open the player once the sheet has gone,
  so the focus is back on the programme first and Menu from the player returns to it (the grid gives the focus back
  to the cell that had it last, `TVGuideGrid.lastFocus`). Rows read their programmes as they scroll in, for 30 hours
  around the window, so paging reads nothing new. Without a guide source, Channels shows the live categories with Add a TV Guide.
- **Movies, Series** (`TVKindScreen`, `TVBrowseScreens.swift`): Continue Watching of that kind, a strip of category
  tiles (and the full category browser), then every category as a shelf, a page of categories at a time. A category
  (`TVCategoryScreen`) is a grid with its order (channel number, name, recently added), paged by
  `CategoryChannelsModel`. Favorites and Recently Watched (by day, Clear History) have full pages too.
- **Series** (`TVSeriesScreen`): a backdrop of the poster, the poster, title, counts and what plays next; Resume /
  Play S1 E4 (it has the focus when the page opens), favorite, mark the season as watched; the seasons as a row of
  tabs drawn like the tab bar (the focused one shows its episodes, as in the TV app; a long row scrolls, and opens at
  the season of the episode to watch) and the episodes as a shelf (number, title, watched, progress, Up Next; the
  long-press menu marks one as watched). The focus moves between the rows predictably: down from the actions and up
  from the episodes land on the selected season, and down from a tab (or Select on it) enters the season at its Up
  Next episode, or its first. `Tools/Simulator/remote-tests.sh` checks it with Siri Remote presses.
- **Library** (`TVLibraryScreen`): Continue Watching, Favorites, Favorite Series, Recently Watched and the recordings
  (the channel's logo, kept with the recording since this version, else its initials; when it was made and how long
  it is, "45 sec" under a minute; Recording or Saving… over the artwork until it can play; long press deletes one),
  on `AppNavigation.libraryPath`. Empty, it offers Find Something to Watch (Home), or Add Playlist without playlists.
- **Search** (`TVSearchScreen`): the system search field and keyboard (dictation with the Siri Remote's microphone,
  the Continuity Keyboard of an iPhone), results as shelves: live channels, programmes of the guide, movies and series
  (a series named exactly as typed first). Before typing: what was watched last and the favorites. A sentence (what
  people say to the remote: "football tonight", "italian news channels", "films tomorrow") also gets Smart Results
  first; see [Siri, voice search and links](#siri-voice-search-and-links).
- **Settings** (`TVSettingsScreen`): laid out like the system's Settings, the app's mark and the library at a glance on
  one side and a list on the other: playlists (each with refresh, edit and delete; Add Playlist; which playlists the
  pages show), TV guide sources (on or off, refresh, delete; add; refresh all; reminder lead time), the time-shift
  buffer, audio and subtitle languages (the shared `TrackSettingsSection`), Clear Watch History, the recordings, Siri and
  Voice Search (`TVSiriScreen`, below) and the version; every choice opens its own list. iCloud (the shared `CloudSyncSettingsSection`, after the playlists, with
  the same plain row symbols): the switch, the status, Playlists in iCloud, Sync Now, and What's Synced and Privacy
  (a page of focusable lines the remote scrolls through, and Delete iCloud Data). Addresses are typed in the shared Add Playlist and Add Guide Source forms,
  whose text fields bring up the tvOS keyboard, dictation and the Continuity Keyboard on a nearby iPhone or iPad. On
  Apple TV they are full-screen pages (`tvFormPage()`: opaque, the fields 1,240 points wide, so a whole address shows;
  a sheet there is a narrow translucent card), their Add button is a row of the form and Menu cancels. The rows'
  icons are a column of their own, clear of their titles (`TVSettingsLabelStyle`), and the header shows the app's
  icon (`TVAppMark`).
- **Focus**: each page has a sensible first focus (the hero's Play, the series' Continue, the programme on air on the
  first channel, the Add Playlist of an empty page, or Add Playlists from iCloud next to it on the welcome screen when
  iCloud has playlists of the user's other devices); the system brings the focus back to the card or programme that
  opened a player, a sheet or a pushed page.
- **Player** (`TVPlayerView`, `TV/Player`): the system's `AVPlayerViewController`, see [The TV player](#the-tv-player).
- **Icon**: Icon Composer has no tvOS rendition (checked with Xcode 27.2: `AppIcon.icon` gives the iPhone, iPad and
  Mac icons only), so `Design/Icon/render_tvos_assets.swift` draws the layers of `AppIcon.icon` (the brand gradient,
  the three stream bands, the play glyph) into the layered "App Icon & Top Shelf Image" brand assets: Back, Middle
  and Front layers for the parallax at 400 × 240 (1x, 2x) and 1280 × 768 (App Store), and the static Top Shelf
  images (1920 × 720 and 2320 × 720, 1x and 2x): `xcrun swift Design/Icon/render_tvos_assets.swift`.
- **Launch screen** (`FluxoTV/LaunchScreen.storyboard`, tvOS only): the mark of the icon (the stream bands fading in
  from nothing, into the play glyph) centered on the page background of the TV app, in the system appearance (the
  `TVLaunchBackground` color, 0.055 white dark and 0.93 light as `Color.tvPageBackground`, and the `TVLaunchMark`
  image, a white glyph dark and an ink one light), so the launch dissolves into Home in both. Both assets have the tv
  idiom only, so the iPhone, iPad and Mac catalogs do not carry them; the mark is drawn by
  `Design/Icon/render_tvos_launch.swift`. (On tvOS 27.2 a `UILaunchScreen` dictionary is drawn plain black.) iPhone
  and iPad keep their generated launch screen. The welcome screen and Settings show the icon itself, flat
  (`TVAppMark`, tv idiom only, drawn from `Design/Icon/Fluxo-flat.svg` by `xcrun swift Design/Icon/render_tvos_mark.swift`).

## Top Shelf

With Fluxo in the top row of the Home Screen, its Top Shelf shows what Home starts with, for the playlists Home shows:
**Continue Watching** (a series once, with the episode to watch now, and how far it was watched), **Favorites**
(channels, movies, episodes and series in the user's order) and **On Now** (what the user's channels show, with the
programme's progress), as rows of 16:9 images. Selecting an item plays it (a favorite series opens its page);
Play/Pause plays it (a series where the viewer left off). Without a playlist tvOS shows the static Top Shelf image.
The Top Shelf is in front of everyone in the room: while "Hide adult content from recommendations" is on, none of its
rows shows adult content, the user's own included (see "Adult content").

- **The extension** (`FluxoTopShelf`, a `TVTopShelfContentProvider`, embedded in the tvOS app only: the target
  dependency and the Embed Foundation Extensions phase are filtered to tvOS, so the iPhone, iPad and Mac builds never
  build it) reads one small JSON file and points at finished images. It never opens the SwiftData store (a second
  process on the SQLite file, possibly in the middle of a migration or an import) and never goes on the network.
  Its only strings are the three row titles (`FluxoTopShelf/Localizable.xcstrings`, the translations of the app's
  catalog): they follow the language of the Apple TV, also when the app has not run since it was changed.
- **The snapshot** (`TopShelfSnapshot`, compiled into both targets) is written by the app (`TopShelfPublisher`) to
  `Library/Caches/TopShelf` of the App Group `group.dev.watermelon.Fluxo` (`Fluxo-tvOS.entitlements`,
  `FluxoTopShelf.entitlements`; `Fluxo-tvOS.entitlements` also keeps the iCloud keys of `Fluxo.entitlements`, and the
  iOS entitlements are unchanged). A hidden view at the root of the TV app runs
  Home's queries and publishes again, debounced, when the history, the favorites, the watch progress, the guide or
  the playlists change, and not while the player is open (the position is saved every 10 s there): once it closes,
  or at once when the app goes to the background, also with the player open (Home or the TV button leave it up),
  in background time (`beginBackgroundTask`), so what was just watched leads Continue Watching. Each On Now channel carries its next 12 hours of programmes, so the extension still
  shows what is on air, titled with it, after the app was closed; then it tells tvOS to reload
  (`topShelfContentDidChange`).
- **Images** are drawn by the app (`TopShelfArtwork`) with the look of its cards: a channel's logo on a graphite tile
  (on a light tile when the logo is dark lettering on a transparent background, which would vanish on graphite), a
  poster in front of a blurred copy of itself and clear of the progress bar tvOS draws, the initials of the name on
  its color without artwork, and the LIVE badge in On Now. They are drawn in the direction of the app's language
  (`ImageRenderer` lays out left to right unless told: in Arabic the badge is in the top right corner, as on the
  On Now cards, and its letters are not spaced apart). They are cached by a digest of what they show and the
  language (a logo that changes makes a new file) and the ones the snapshot no longer uses are deleted. Only drawn
  artwork is cached under its digest: while a logo or poster cannot be loaded (its host is down, or the publish was
  cancelled) the initials tile is written under the digest of the art without artwork, and the next publish tries
  the artwork again.
- **Links**: `fluxo://play?channel=<id>`, `fluxo://play?playlist=<UUID>&series=<key>` and
  `fluxo://open?playlist=<UUID>&series=<key>` (`TopShelfLink`; the scheme is registered in `Info-tvOS.plist` only).
  Channels are named by their App Intents identifier (`ChannelEntityID`: the playlist and a keyed digest of the stream
  URL), never by the URL, which often carries the account's user name and password; the snapshot holds no URL either.
  A link to something no longer in the playlists says so ("Not Available"), in the one alert of every link
  (`AppNavigation.linkFailure`, shown by `TVLinkHandler`): Siri or the next link take it down and keep the tab they
  open. A Top Shelf link is a request like Siri's: it takes down an earlier link's alert, and a series page opened
  over the player keeps Home against the focus the player gives back (`AppNavigation.keepTab(for:)`).
- **Target**: a plain app extension (`com.apple.product-type.app-extension`, as Xcode 27.2's TV Top Shelf Extension
  template makes it), which links with `_NSExtensionMain`; the legacy TV App Extension type sets `_TVExtensionMain`,
  with which the extension exits before the provider is created in the tvOS 27.2 Simulator. Its version and build
  (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) are the project's, shared with the app, as the App Store requires.
- **Accessibility**: tvOS reads each item's title, so the titles say what the image shows ("Orbit · S1 E2", "Quiz
  Night · Rai 1 HD"); they keep the direction isolates of the app's lines only when a right-to-left script needs them. On Now items have no expiration date: tvOS would show the time left in place of the title.

## Siri, voice search and links

What the tvOS 27.2 SDK offers third-party apps, checked in its headers and `.swiftinterface` files, in the tvOS 27.2
Simulator runtime and in the built app's `Metadata.appintents`, and what Fluxo does with it:

| Capability | On Apple TV |
|---|---|
| App Intents, `AppDependencyManager`, entities and queries (tvOS 16) | The same intents as on iPhone, in the app's process: Play Channel, Play by Name, Continue Watching, Pause / Resume / Stop, Recording, the favorites, Search in Fluxo, Find Channels, Suggestions, What's On, Search TV Guide, Show Channel Schedule, Set Reminder, Open Screen. 19 intents, 2 entities and the 10 App Shortcuts are in the tvOS build's `Metadata.appintents` (Visual Intelligence is not in the tvOS SDK). Differences: Show Channel Schedule opens the Live TV guide at the channel's row (the TV has no schedule sheet); Open Screen also opens Movies, Series and Settings ("Live TV" is a name of the guide) and does not offer Downloads (Apple TV keeps none, so the choice is not in its list); Set Reminder no longer asks for notification permission (the TV's reminders are the app's own alerts) and says they show while Fluxo is open; opening a screen stops what plays, as Menu does (there is no mini player). When the player (or a link's alert) goes away, tvOS gives the focus back to what had it before, and a tab-bar item that takes the focus selects its tab: the tab that Siri or a link opened behind it is kept for 2 seconds after the cover is gone (`AppNavigation.keepTab(for:)`, undone once at most; never after Menu or OK, where the viewer is the one moving) |
| App Shortcuts (`AppShortcutsProvider`, tvOS 16), `updateAppShortcutParameters()` | Registered with their phrases in 16 languages; the channel names are refreshed as on iPhone. Xcode 27.2 runs the `AppIntentsSSUTraining` step (the `root.ssu.yaml` Siri uses to match phrases that are said a little differently) for iOS and not for tvOS, so on Apple TV say the phrases as written. The tvOS 27.2 runtime has the Siri plug-in that runs App Shortcuts (`SiriLinkFlowPlugin`) and `linkd`; the Simulator has no Siri, so the phrases must be tried on a device |
| Assistant schemas (`AppSchema`, `@AppIntent(schema:)`) | **Unavailable on tvOS** (`@available(tvOS, unavailable)`): no free-form requests through Apple Intelligence; `AppSchemaAdoption.swift` stays iOS / macOS / visionOS |
| `OpenIntent`, `PlayVideoIntent` and `ShowInAppSearchResultsIntent` (tvOS 17.2) | Play Channel, Play by Name ("Play … in Fluxo" with any words), Search in Fluxo (types the words into the Search tab) |
| Predictions (`PredictableIntent`, `AppIntent.donate()`) | Play Channel is donated whenever a channel starts, as on iPhone. `NSUserActivity.isEligibleForPrediction` and `persistentIdentifier` are unavailable on tvOS (not used) |
| On-screen awareness: `View.appEntityIdentifier(_:)` (tvOS 18.4), `MPNowPlayingInfoPropertyAppEntityIdentifiers` (tvOS 27) | The TV player names the channel on screen. Its Now Playing entry is AVKit's own on Apple TV (see [The TV player](#the-tv-player)), which carries no app entity, so `MPNowPlayingInfoPropertyAppEntityIdentifiers` is not set there. Harmless and ready for later: on-screen awareness is an Apple Intelligence feature, which Apple TV does not have, so today nothing reads them. "Add this channel to my Fluxo favorites" and "Record this in Fluxo" act on the channel that plays (else the one watched last) by themselves |
| `SiriTipView` (tvOS 16), `ShortcutsLink` | `SiriTipView` is in the SDK but drew nothing in the tvOS 27.2 Simulator; `ShortcutsLink` is not in the tvOS SDK (no Shortcuts app). Settings › Siri and Voice Search lists what to say instead |
| Spotlight: `CSSearchableIndex`, `IndexedEntity` | **Unavailable on tvOS** (`API_UNAVAILABLE(tvos)`; the CoreSpotlight cross-import of App Intents is not in the tvOS SDK): the system search of Apple TV never lists app content. `PlatformFeatures.spotlightIndexing` is off |
| Foundation Models | No on-device model on tvOS: Smart Results use the rules of `SmartSearch` |
| Handoff (`NSUserActivity.isEligibleForHandoff`, tvOS 10 in the SDK) | **Not a Handoff device**: Apple TV neither advertises nor receives Handoff (Continuity's Handoff is iPhone, iPad, Mac, Apple Watch and Vision Pro), so "Continue on Apple TV" from an iPhone cannot be a Handoff. What does it: iCloud sync carries the resume position (published within seconds of a pause or stop on the iPhone, see [iCloud sync](icloud-sync.md)), then "Continue watching in Fluxo", the Continue Watching shelf or the Top Shelf resume it on the TV; AirPlay from the iPhone's player puts the iPhone's playback itself on the TV |
| The TV app (Up Next, "Watch Now", universal search, "Play … " and "What should I watch?" without the app name, single sign-on) | **Needs Apple's video partner programme**: Apple ingests a catalogue and availability feed from the provider and grants the entitlement; it is not open to an app that plays the user's own playlists. `VideoSubscriberAccount` is in the SDK for TV-provider sign-in only. A request without "Fluxo" goes to the TV app or Music |
| SiriKit media intents (`INPlayMediaIntent`, `INSearchForMediaIntent`, tvOS 14) | Not used: they need an Intents extension and Siri treats them as audio requests |
| URL schemes | `fluxo://` is registered in `Info-tvOS.plist` only; `FluxoLink`, its handler and their debug routes are compiled for tvOS only (iPhone, iPad and Mac do not handle these links) |

**Voice search** (`TVSearchScreen`). In Search, holding the microphone button of the Siri Remote dictates into the
system search field (as does the Continuity Keyboard of an iPhone). What is said is often a sentence rather than a
name, so a search of two or more words with a time, a kind, a country or "like …", or one the name search finds nothing
for, also gets **Smart Results** first: the words as understood in the shelf's title, as said ("Football · Tonight",
"News · Italy · Live TV", "Movies · Tomorrow"; not the synonyms and translations searched with them), then the
programmes of the guide and the channels, movies and series they match (a series opens its page, as on iPhone, rather
than playing the episode that happened to match), then the matching categories as tiles. The regular results show at
once and Smart Results join them above when their plan has run (a search the name search finds nothing for waits for
them instead, with "Searching for …" in place of the previous words' shelves, rather than saying "No Results" first). What Smart Results show is left out of the regular shelves below them, so
nothing is listed twice. "Search Fluxo" (Siri) and `fluxo://search?q=…` type their words into the same field.

**Siri and Voice Search** (`TVSiriScreen`, Settings): the phrases (Play, Continue Watching, What's On, Search, Open the TV
Guide, Record this, Add to Favorites, Set a Reminder) with what each does, and how to search by voice; every line is
focusable (on a white platter with dark text when focused, as the system's Settings rows, kept clear of the screen's overscan-safe edge), so the remote walks through
the page and VoiceOver reads each line.

**Links** (`App/Links/FluxoLink.swift`, opened by `TVLinkHandler` through the same `AppServices` calls as the intents
of the same name, so a link and Siri leave the app in the same state):

| Link | Opens |
|---|---|
| `fluxo://open?screen=<home\|guide\|search\|movies\|series\|library\|favorites\|history\|recordings\|settings>` | A screen, from its root (as Open Screen: Live TV, Movies, Series and Settings pop their own stacks through `AppNavigation.rootRequest`) |
| `fluxo://search?q=<words>` | Search with the words typed in (as Search in Fluxo; at most 200 characters) |
| `fluxo://guide[?channel=<ChannelEntity id>]` | The TV guide, at a live channel's row (as Show Channel Schedule); a channel that is gone shows "Channel Not Available" over the guide at now (over Live TV's channels without a guide). Whatever opens a screen next (Siri, another link, even to the same tab) takes the alert down first, and an alert still to come for an earlier link is dropped |
| `fluxo://continue` | Continue Watching (as the intent): the movie or episode with a saved position watched last, else the channel watched last; "Nothing to Continue" when nothing was watched |
| `fluxo://play?channel=…`, `fluxo://play?playlist=…&series=…`, `fluxo://open?playlist=…&series=…` | The Top Shelf's links (`TopShelfLink`, its own handler): never parsed as `FluxoLink`s, so every URL is opened once. Their "Not Available" is the same alert as the links above, and they count as requests the same way |

Channels are named by their `ChannelEntity` identifier, never by their stream URL (which can carry the account's user
name and password). The identifier is keyed with a secret of the installation, so a link made on another device does not
resolve on this one: links are for the Top Shelf and the system of this Apple TV. A link opened from outside the system
(`xcrun simctl openurl`) first shows the system's "Open in “Fluxo”?".

## The TV player

`AVPlayerViewController` on the app's single `AVPlayer`, for every route: HLS that AVPlayer plays directly, the remux
engine's on-demand and live HLS on 127.0.0.1 (raw MPEG-TS, Matroska and the other formats), the time-shift window of
live channels, recordings. The transport bar, the clickpad and the Siri Remote work as in the TV app; the shared
`AVPlayerViewModel` does the rest (routing, reconnection, time shift, recording, watch progress and resume).
`TVSystemPlayer` owns the controller and is its delegate; `TVPlayerView` describes what it shows besides the video
(`TVPlayerChrome`, applied when it changes):

- **Seeking**: the transport bar seeks AVPlayer itself (a click on the left or right of the clickpad skips 10 s, a
  scrub is committed with a click). Its delegate hears of every seek first
  (`playerViewController(_:timeToSeekAfterUserNavigatedFrom:to:)`): the engine is told where playback goes before
  AVPlayer asks for the segment there (`fluxo_remux_note_seek`, as for the app's own seeks), and `PlayerSeeker` follows
  the seek (`followSystemSeek(to:)`) with the recovery of a seek that does not play (again from the key frame before
  the target, then a new item or the engine) and its latency log.
- **Info panel** (a swipe down): the system's Info tab, from the item's `externalMetadata`. AVKit shows the
  subtitle as its headline (the title only when there is no subtitle), and over the transport bar the subtitle as a
  small line above a large title. So the title names the show and the subtitle what of it plays, as in the TV app:
  a live channel is "2 · Channel" over the programme on now ("Quiz Night · 8:00–9:00 PM · S4 E9", the headline of
  the Info tab, with its description, what is next and its genre; written again when the programme on air changes;
  the channel alone without a guide), an episode "Orbit" over "S1 E2 · Encore" (the series also in the Info tab's
  line of details, as its genre, since the tab does not show the title), a movie its name, a recording its
  name with when it was recorded as its description; the logo or poster is the artwork.
  Its actions are Start Over (movies, episodes, recordings) and Add to / Remove from Favorites. Tabs
  (`TVPlayerPanels.swift`): **Guide** (live channels with a TV guide: now, with its progress and the time left (behind the live edge, the picture's
  position brighter over the broadcast's), and
  what follows; selecting a programme still to come sets or removes its reminder, selecting the one on now goes back
  live when playback is behind the broadcast, or plays it from its start when the time-shift window reaches back
  that far; with neither, selecting it does nothing, but it still takes the focus, so the focus stays on it after
  Go Live), **Channels** (the channels of the
  category, with what each shows now and the one playing marked; selecting one switches to it, not while recording)
  and **Episodes** (the series' episodes).
- **Channel up / down**: the delegate's channel skipping (the channel buttons of TV remotes): AVKit shows
  `TVChannelInterstitial` (the channel's logo, number and name, what is on) until the next or previous channel of the
  category plays (8 s at most). A channel switched to inside the player shows its banner (logo, number, name, now
  with its progress and time left, next) at the top left for 5 s while the transport bar is hidden.
- **Contextual actions** (over the video, bottom right; they take the focus, so Select presses them and the info
  panel does not open while one shows): Go Live more than 10 s behind the live edge of a time-shifted channel, for
  8 s once it plays behind with the transport bar hidden (once until the bar shows again or playback catches up, so
  the stalls of a flaky stream do not bring it back; not while paused, and the Guide tab's programme on now goes
  live at any time); Next Episode during the end credits of an episode (the last
  3 %, at most a minute, of one longer than 5 minutes); Try Again after a seek that could not play.
- **Transport bar**: Record / Stop Recording (live channels through the engine; a REC capsule with the duration shows
  at the top right while the bar is hidden; Menu while recording asks first, Stop Recording or Keep Recording, since
  closing the player stops the recording: `playerViewControllerShouldDismiss` keeps the player for that Menu, not
  for the one that hides the bar or the info panel) and Picture (Fit to Screen / Fill Screen), next to the system's Audio
  and Subtitles menus. Those list the item's AVMediaSelection groups, which include the renditions the engine writes
  (extra audio tracks, text subtitles, CEA-608 captions, see "Audio tracks and subtitles"); a choice there is
  remembered like one in the iPhone menu (`MediaSelectionController.systemPlayerDidSelect`).
- **Before the first picture** (until a first frame of the channel's item is ready, `AVPlayerViewController.isReadyForDisplay`
  counted per transition by `TVSystemPlayer.readyForDisplayCount`, since AVKit reports "not ready" and "ready" for an
  item replaced in the player a few milliseconds apart; and in any case once it has played 3 s: audio only)
  the channel (logo, number and name, the programme on now; an episode as its series and
  code with its title, a recording with when it was recorded) and the player's state show around the only spinner
  on screen (`TVPlayerPreroll` covers the system player, whose own indicator stays hidden under it). **Failures** say
  what went wrong ("Can't Play “…”", the reason in plain words for the usual server failures (refused, timed out,
  unknown host, 401/403, 404, 5xx: `TVPlayerFailureText`) over the technical one in small type, a warning sign or,
  offline, a Wi-Fi sign) with Try Again and Close (Liquid Glass buttons, readable unfocused);
  on a live channel also Next Channel, and up and down change the channel there as on the video.
  A server that refuses the connection fails in about 4 s, not 20: on Apple TV the engine opens the input with one
  connection per attempt (`StreamRemuxer.Configuration.quickOpen`, `FluxoRemuxConfig.quick_open`; its own retries
  for a busy server, 0.5, 1 and 2 s apart, stay, and FFmpeg's reconnection on network errors is turned on once the
  input is open), where FFmpeg's HTTP layer would retry each attempt for 4 s by itself. iPhone, iPad and Mac keep
  the retries; **the end of a movie or recording** shows Play Again and
  Close; **the end of an episode** with a next one shows it (poster, series, code and title) with a 10 s countdown
  ring, Play Now and Cancel (nothing starts by itself with VoiceOver or Switch Control on); a live broadcast that
  stopped is a failure with Try Again. These take the focus: the transport bar is off while they show, so the
  clickpad drives their buttons. Reconnecting… shows at the top right while the bar is hidden.
- **Picture in Picture**: the system's (the transport bar's button). The controller is kept outside SwiftUI, so the
  player screen closes and the video plays on in the corner while the app is browsed; a channel picked meanwhile
  plays there; Full Screen opens the player again, closing the PiP window stops playback. Not verified yet: the
  tvOS Simulator has no Picture in Picture (`isPictureInPictureSupported()` is false there, so the button does not
  show), so these paths need a check on an Apple TV. Menu closes the player and stops playback otherwise, as in the
  TV app.
- **Now Playing**: AVKit publishes it for the controller (from `externalMetadata`, with the elapsed time, duration
  and live state) and answers the remote commands; `NowPlayingController` does nothing on tvOS
  (`updatesNowPlayingInfoCenter` does not exist there, and two writers fight). The Siri app entity of the channel is
  not attached to Now Playing on Apple TV for that reason.
- **Screensaver**: the display stays awake while the video plays on screen (`playerViewDidAppear()` on the player's
  container, `PlaybackEnergyProfile`), and the screensaver may start while it is paused, as in the TV app. The app's
  own `PlayerSurface` layer keeps no hold on the player on tvOS (one video output).
- **Accessibility**: the system's controls are VoiceOver's own; the cards of the tabs are one element each (channel
  and programme, Now Playing / Reminder set as values); failures, the end of a video, seeks that could not play and
  recordings are announced by `PlayerAnnouncements` as on iPhone, favorites changes and the next episode by the TV
  player.

Seek latency in the tvOS Simulator (Apple TV 4K, the transport bar's seek replayed by the harness: `tv-seek:` asks the
delegate and seeks AVPlayer exactly, as AVKit does; `tv-skip:` is the clickpad's skip; timed from the seek until it
plays at the target with frames that keep up with the clock, loopback test server; on a heavily loaded Mac, so upper
bounds):

| Route | Scrub (`tv-seek:`) | Skip ±10 s (`tv-skip:`) |
|---|---|---|
| AVPlayer, MP4 on demand | 0.10–0.16 s | 0.10–0.11 s |
| Engine, MPEG-TS on demand | 0.11–0.17 s | 0.16–0.17 s |
| Engine, Matroska on demand (two audio tracks, subtitles) | 0.11–0.15 s | 0.12–0.16 s |
| AVPlayer, live HLS | | 0.06–0.12 s |
| Engine, live MPEG-TS, time-shift window | 0.11–0.12 s | 0.07–0.12 s |
| Recording (local MP4) | 0.16 s | 0.10 s (−5 s) |

Every seek played at its target (the seeker logs "Seek to … playing at … after …" for each, within 0.2 s) with the
picture keeping up with the clock (video lag 0.03–0.04 s, no frozen frames) and no stall. One run made while the Mac
was far overloaded (load average above 100, screenshots after every step) left direct MP4 seeks buffering without
frames; the same seeks run again were all as above.

## Trying it

```sh
Tools/Simulator/build.sh --platform tvos
Tools/Simulator/test-stream.sh start
Tools/Simulator/run.sh --device "Apple TV 4K (4th generation)" --clone fluxo-mykey-tv-1 --step-shots \
    --route "home;focus:Sky Sport F1;player:Test Pattern (MPEG-TS);wait:8;probe-playback"
# The TV player: the guide and channel tabs, recording, transport-bar seeks, channel up and its interstice.
Tools/Simulator/run.sh --device "Apple TV 4K (4th generation)" --clone fluxo-mykey-tv-1 --step-shots \
    --route "seed-guide;player:Test Pattern (MPEG-TS);wait:5;tv-panel:guide;tv-panel-close;tv-panel:channels;tv-panel-close;record:start;wait:4;record:stop;tv-skip:-10;pause;resume;tv-zap:next,hold;tv-zap-close;tv-zap:previous"
```

See "Apple TV" in `Tools/Simulator/README.md` for the harness on tvOS, and `topshelf-tests.sh` there for the Top
Shelf on the Home Screen of the Simulator.
