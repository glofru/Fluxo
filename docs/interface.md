# Interface and design

## User interface

- **Player screen** (`Features/Watch/WatchChannelView.swift`, with its top bar in `PlayerChrome.swift`, its controls in
  `PlayerBottomBar.swift` and its messages in `PlayerStatusOverlay.swift`): the video fills the screen
  (iOS full-screen cover; on macOS it covers the main window, whose toolbar is hidden
  meanwhile). The top bar shows close, the channel logo and name, the status (connecting,
  buffering, reconnecting, `LIVE`, time-shifted `-m:ss`, paused, ended, error) and the
  recording indicator, plus PiP, AirPlay, full screen (macOS) and a menu (fill / fit,
  recordings, stop). The bottom bar has a scrubber (on-demand position, or the time-shift
  window of a live channel), channel down / up, skip back / forward, play / pause, Record
  and Go Live (see "Liquid Glass" below for how these controls morph). Controls fade out after 4 s of playback without interaction and come back on
  a tap or mouse move; they stay up while paused, buffering, failed, scrubbing or with
  VoiceOver on. Errors and the end of a stream show a card with Try Again / Play Again.
- **Channel guide from the player** (`Features/Watch/PlayerChannelGuide.swift`): on a live channel with a guide,
  what is on now in the top bar (with a chevron) and Channel Guide in the player's menu show the channel's
  schedule without stopping the video: the last programmes of today (dimmed), the one on now (highlighted, with
  its progress and time left) and what follows by day, opened scrolled to now, with a Now button once it is out of
  view; a tap opens a programme (details, Remind Me). Where it shows: the side panel's Guide tab in a wide player
  (iPad in landscape, the Mac), the schedule pane of an open foldable, otherwise a sheet over the video (medium and
  large on iPhone, a form sheet on iPad and the Mac). Full Guide closes the player (playback continues, in Picture
  in Picture when it can) and opens the TV Guide at today and now, scrolled to the channel's row, which is tinted
  (`AppNavigation.showInGuide(_:)`, `guideFocus`; the list layout scrolls to it too). Player windows of their own
  (iPad) have no Full Guide: their guide is in another window.
- **Guide legibility over the video** (`Features/Watch/PlayerLegibility.swift`): the channel name, its status and
  what is on now / next sit on a thin, mostly clear Liquid Glass platter (clear glass with a light dark layer,
  hugging the text) instead of the top scrim alone, which fades out before the last lines and let bright pictures
  wash them out; over a white picture the text keeps about 4.5:1, over a dark one the platter is barely visible.
  The guide sheet over the video gets a dimmed thin-material backdrop instead of the clear sheet glass. Reduce
  Transparency makes both near-opaque; Increase Contrast dims more and edges the platter with a hairline.
- **Channel zapping** (`ChannelZapper`): channel up / down plays the next / previous
  channel of the group of the playing channel, in playlist order, wrapping around. Each
  step is one indexed single-row fetch. It is offered for live channels started from a
  playlist (not recordings) and disabled while recording.
- **Cards**: live channels are 5:3 logo cards, movies and series 2:3 posters. Without
  usable artwork a card shows the channel's initials on a gradient whose color is derived
  from the name. Cards lift on hover and keyboard focus (macOS) and under the iPad pointer,
  and have a combined VoiceOver label (name, kind, playlist, favorite) and a favorite action.
- **Add / edit playlist**: a form with URL validation (http/https and a host), paste from
  the clipboard, a name suggested from the URL, determinate or indeterminate import progress
  with Cancel Import, and an error section with Try Again. Editing can change the URL, which
  re-imports the playlist.
- **Settings** (a tab on iOS, the Settings window ⌘, on macOS): iCloud sync (see [iCloud sync](icloud-sync.md)), time-shift length, skip
  intervals, automatic PiP (iOS), TV guide sources and the reminder time, recordings count and size, delete all
  recordings, temporary stream files, logo cache, watch history, and About: the app and FFmpeg versions,
  Acknowledgements, the privacy policy, the source code and the notice that Fluxo provides no content.
- **Recordings** (in the Library tab on iOS, the sidebar on macOS, and the player's menu): play, delete, delete all.
  Recordings and downloads play only in Fluxo: there is no Share or Show in Finder, and `UIFileSharingEnabled` is
  off, so the Files app and the Finder do not list the app's Documents folder (App Review guideline 5.2.3; see
  [License, privacy and the App Store](license-and-privacy.md)).
- **Menu bar** (macOS, and the iPad menu bar): File > New Window (⌥⌘N, iPad), Add Playlist… (⌘N), Refresh All
  Playlists (⌘R), Refresh TV Guide (⌥⌘R); Go > Home (⌘1), TV Guide (⌘2), Favorites (⌘3), Recently Watched (⌘4),
  Recordings (⌘5; on iPad these three open the Library tab), Settings (⌘6, iPad), Search (⌘F); Playback > Play/Pause (Space), Skip Back / Forward (⌘← / ⌘→),
  Go Live (⌘L), Channel Up / Down (⌘↑ / ⌘↓), Record (⇧⌘R), Picture in Picture (⌥⌘P), Fill Video, Show
  Player (⇧⌘P), Stop Playback (⌘.). Commands act on the focused window. Shortcuts that would clash with text
  editing (Space, the arrows) are only enabled while the player is on screen. Escape closes the player; in a wide
  player ⇧⌘L shows or hides the channel list.
- **Haptics** (iOS): channel changes, recording start / stop, favorites, and the result of a
  playlist import.

## iPad

- **Sidebar** (`App/AppTabView.swift`): a `.sidebarAdaptable` tab view. The sidebar lists Home, Guide, Library,
  Settings, Search (the tabs of the iPhone and of the floating tab bar, so both always show the same selection)
  and a Playlists section (the Home of each playlist, with its
  refresh / edit / delete menu, and Add Playlist). It shows by default when the window is wide (landscape, at least
  1,100 points, so the iPad mini too), decided in the first layout of the window (a `GeometryReader`: the tab view
  reads its default placement only once); narrower windows start with the floating tab bar and its sidebar
  button. Edit in the sidebar pins entries to the tab bar (tab customization, kept in `UserDefaults.fluxo`).
  Narrow windows (Slide Over, a third of Split View) are compact and look like the iPhone. The iPad-only tabs are
  not declared on iPhone, whose tab bar is unchanged.
- **Inspectors**: in a regular width window, programme details open in an inspector next to the Guide grid. In a
  wide window (the sidebar rule above) a channel's schedule (its Guide swipe or menu action) opens in an inspector
  next to Home, the Library (and Favorites and Recently Watched in it), Search and the playlists, which stay usable: another channel replaces
  it. In portrait and narrower windows, where an inspector would cover the content, it is a centered form sheet;
  in compact widths a sheet, as on iPhone.
- **Player side panel** (`Features/Watch/PlayerSidePanel.swift`): in a wide player (iPad in landscape, at least
  900 points), the top bar has a button for a glass panel next to the video: the channels of the playing channel's
  category with what each shows now (tap to switch, the playing one highlighted and scrolled to), or the playing
  channel's guide by day with reminders, at now (see "Channel guide from the player"). The video shrinks to make room. The panel and its tab are remembered;
  ⇧⌘L toggles it, also while the controls are hidden. A row's context menu (Play, Open in New Window, Favorites,
  Today's Schedule) only has actions that work over the player: the schedule opens in the panel's Guide tab, with
  Watch and back buttons; guide matching is left out (its picker would open under the player).
- **Windows** (`App/Windows`): the app supports several windows (`UIApplicationSupportsMultipleScenes`): File ›
  New Window, the Dock, Split View and Stage Manager, all resizable. "Open in New Window" in the context menu of a
  channel opens it in a window of its own (`WindowGroup(for: PlayerWindowValue.self)`; the value holds the channel's
  identifiers and name, never its stream URL). There is still one player: `WindowCoordinator` presents it in the
  window it was started from (a card, the mini player or Show Player moves it to the window used), and the other
  windows show the mini player. App-wide sheets and alerts (Add / Edit Playlist, delete, import and guide errors,
  the guide channel picker) are claimed by the window the user touched or focused last and stay there. Closing a
  player window, or its player, brings the main window back; a player window restored at launch waits for Play
  Here.
- **Drag and drop** (iPad and macOS; on iPhone a long press stays the context menu): channel cards and rows can
  be dragged (`ChannelTransfer`, a custom type visible to the app only; other apps get the channel name as text)
  onto Library in the sidebar or the tab bar (spring-loaded), the Favorites row of Home or of the Library, or the
  Favorites screen, which adds them to the favorites; the Mac sidebar's Favorites accepts them too. A web link dropped on a window opens Add Playlist with it; an M3U / M3U8 file dropped on a
  window (or opened in Fluxo from Files, `CFBundleDocumentTypes`) is copied to `Application Support/Playlists` and
  imported from that copy (`LocalPlaylistFiles`, which resolves the copy in the current container on every
  refresh and deletes it with the playlist). The Edit Playlist form accepts that file address only for the
  playlist that owns it; typed addresses must be http or https.
- **Pointer and keyboard**: cards lift and list rows highlight under the pointer; the menu bar commands above have
  keyboard shortcuts and show in the shortcut overlay (hold ⌘).

## iPhone with a hinge (iPhone Duo)

The iPhone Duo (`iPhone19,4`) is a book-style foldable: a cover display (466 x 678 pt) used folded, and an inner
display (951 x 669 pt in landscape) that folds across its middle. The iOS 27.1 SDK describes it to apps with
`onHingeChange` / `UIHingeInteraction` (the hinge status, closed / partially open / fully open, and its angle),
`GeometryProxy.reservedRegions(kind:)` (`.division`: where content should divide in two, the fold; `.occlusion`),
and, on the cover display, the vertical bar (`UITraitCollection.verticalBarEdge`; SwiftUI `toolbarVerticalBehavior`,
`axisBehavior`, `toolbarVerticalCompressionBehavior`), which puts the status bar, the toolbar items and the tab bar
in one column on the trailing edge. `ArrangementView` (`.split` / `.overlay`) arranges two views side by side or
overlaid.

- **Posture** (`App/Foldable/DisplayPosture.swift`): the root of the window reads the hinge, the active division and
  occlusion regions and the vertical bar edge once, and shares them as `\.displayPosture`. `split()` is where the
  window divides: the system's division region, or, on a device with a hinge showing the app on its inner display
  without one, the middle of the long side. On every other device it is nil and nothing changes.
- **Player** (`PlayerPaneLayout`, `PlayerCompanionPanel`): open like a book, the video takes one half and the other
  half shows the companion panel: what plays (channel, category, programme on air and next), the other channels
  of its category with what they show (a tap switches channel in place; not while recording) and the channel's
  schedule (a tap opens a programme, with its reminder). Nothing is drawn on the fold, the top bar uses its phone
  layout in its half, and a button swaps the sides. Fully open (flat), the video gets the whole display; the top
  bar's split button shows the panel. Standing like a laptop (the fold from side to side), the video goes to the
  upper half with its top bar, the timeline and the transport stay on the lower half (always visible), above the
  channel list. The choices (panel when partly open / flat, video side) are remembered. The video view keeps its
  identity in every layout, so folding, unfolding or toggling the panel never interrupts playback.
- **Cover display**: the system's vertical bar is part of the safe area, which every screen respects. The Home
  billboard pages are as wide as the screen and run under the bar (and the side safe areas of a phone in
  landscape) with their text clear of it, so the next page never shows under the bar; the billboard's fade covers
  the extended artwork too. The player covers the bar, as on other iPhones.
- **Testing**: the simulator cannot open the hinge, see "iPhone Duo" in `Tools/Simulator/README.md` for the
  simulated postures (`-FluxoDebugPosture`, the `posture:` route) and the gesture test.

## Liquid Glass (iOS 26)

Glass is used for the navigation and control layer only (tab bar, toolbars, the mini player,
the playlist chips, the player controls, sheets). Cards, rows and banners are content and use
plain surfaces or small materials.

- **Tab bar**: a native `TabView` with Home, Guide, Library, Settings and a `.search` role tab. It
  minimizes while scrolling down (`tabBarMinimizeBehavior(.onScrollDown)`).
- **Mini player** (`PlayerBottomAccessory` in `App/ContentView.swift`): the
  `tabViewBottomAccessory`, shown only while something plays (through `isEnabled:`). It reads
  `tabViewBottomAccessoryPlacement`: expanded, it shows the artwork, the title, a status line
  (LIVE and group, recording with a pulsing symbol, PiP, buffering), play / pause and close;
  inline (next to the minimized tab bar), only the artwork, the title and play / pause.
- **Zoom transitions** (`App/Design/ZoomTransitions.swift`): the full-screen player zooms out of
  the card, billboard artwork, search result or mini player that opened it
  (`matchedTransitionSource` + `navigationTransition(.zoom)`); `PlayChannelAction` passes the
  source to `AVPlayerViewModel.presentationSourceID`, and paths without a card (PiP restore,
  recordings, Show Player) zoom from the mini player. A category zooms out of its
  Home row or its category card (Home, search, the category browser).
- **Home**: the featured billboard runs under the status bar and the floating toolbar, its
  blurred artwork uses `backgroundExtensionEffect()` (it also extends under the iPad sidebar and
  the landscape safe areas), stretches on overscroll and fades into the background so both light
  and dark mode stay legible. The inline title fades in once the billboard has scrolled away;
  the scroll edge effect is `.soft`. The playlist chips share a `GlassEffectContainer` and the
  tinted selection glass keeps its `glassEffectID`, so it morphs from chip to chip.
- **Player controls**: floating glass clusters in one `GlassEffectContainer`. Channel and skip
  buttons merge into a capsule on each side (`glassEffectUnion`), play / pause is a larger
  circle tinted with the accent color while paused, Record stretches into a red-tinted
  `REC m:ss` timer with a pulsing dot, and a red LIVE indicator morphs into `-m:ss Go Live`
  when the stream is time-shifted (`glassEffectID`). PiP, AirPlay and the menu share one capsule.
- **Sheets**: Add / Edit Playlist and Recordings (the player's) use `.medium` / `.large` detents; their forms
  hide the grouped background so the sheet's glass shows at partial height, and they use the
  `.cancel` / `.close` / `.confirm` button roles.
- **Motion and accessibility**: symbol transitions (`contentTransition(.symbolEffect(.replace))`)
  for play / pause, PiP and favorites, `.pulse` for recording and `.variableColor` for LIVE,
  haptics for play / pause, Go Live, chip selection and favorites. With Reduce Motion the glass
  morphs, symbol loops and the welcome animation are turned off; with Reduce Transparency the
  player scrims and the billboard fades get stronger (the system glass adapts on its own).
- **Tint**: the `AccentColor` asset is a violet with a lighter dark-mode variant; live and
  recording states stay red.

## Brand and app icon

The icon shows three streams of colour that flow in from the left and gather into a play
glyph: live channels flowing into one player.

### Palette

| Name | Hex | Use |
|---|---|---|
| Fluxo Violet | `#6A4CFF` | Primary brand colour; the top of the icon background. The `AccentColor` asset is `#6A4CFF` (dark `#8F7BFF`), see Accessibility for the contrast variants. |
| Fluxo Ink | `#140F3C` | Deepest background; the bottom of the icon background. |
| Night | `#281D69` → `#0A0720` | The dark-appearance icon background. |
| Signal Cyan | `#3CD6FF` | Leading stream band; highlights and "live / connected" accents. |
| Lilac | `#A08CFF` | Middle stream band; secondary tints, selection on dark surfaces. |
| Flux Pink | `#FF5C9E` | Trailing stream band; a warm accent that can replace a plain red where the meaning is not an error. |
| Glyph White | `#FFFFFF` (dark: `#F0EDFF`) | The play glyph. |

The background is a linear gradient from the top left (Violet) to the bottom right (Ink).

### Files

- `Fluxo/AppIcon.icon`: the Icon Composer document used as the app icon on iOS and macOS
  (`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`; there is no `AppIcon.appiconset`). It has two
  Liquid Glass groups: **Play** (the glyph, 20 % translucency, neutral shadow) in front of
  **Stream** (the three bands, layer-colour shadow), both with specular highlights. The dark
  appearance has the Night background and a lavender glyph; the tinted and clear appearances are
  derived by the system from the layers. Open it in Icon Composer
  (`Xcode.app/Contents/Applications/Icon Composer.app`) to adjust the glass settings. Xcode
  compiles it into `Assets.car` (and `AppIcon.icns` / `AppIcon60x60@2x.png` fallbacks).
- `Design/Icon/Fluxo.vectorcraft`: the editable master in [VectorCraft](https://github.com/storytold/vectorcraft),
  one layer per icon layer plus a reference background. `Design/Icon/Layers/*.svg` are the layer
  exports (1024 × 1024), and `Fluxo-flat.svg` all layers together.
- `Design/Icon/generate_layers.py`: draws the master with the headless VectorCraft CLI (the
  geometry is computed in the script: the band centre lines, their stroke width, outline and
  fade-in, and the live corners of the glyph), exports the layer SVGs and copies them into
  `Fluxo/AppIcon.icon/Assets`. `vectorcraft-cli` is in the
  `vectorcraft-cli-<version>-macos-universal.zip` release asset (the app bundle does not include it):

  ```sh
  VECTORCRAFT_CLI=/path/to/vectorcraft-cli Design/Icon/generate_layers.py
  ```
- `Design/Icon/render_previews.sh [dir]`: renders the icon with Icon Composer's `ictool` in the
  Default, Dark, Clear (light / dark) and Tinted (light / dark) appearances for iOS and macOS.
