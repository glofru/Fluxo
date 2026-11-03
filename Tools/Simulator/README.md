# Simulator test harness

Scripts and Debug-only launch arguments to check the Fluxo UI in iOS simulators quickly, with a seeded
library that never touches a real one. Everything here runs on the Mac; nothing needs the internet.

| Script | What it does |
|---|---|
| `build.sh` | Builds the Debug simulator app once (into `/tmp/fluxo-dd/<worktree folder>-sim`). |
| `run.sh` | Clones a simulator, boots it, installs the app, launches it with the harness, waits until it is ready, screenshots every display, deletes the clone (or keeps it with `--keep`). |
| `shot.sh` | Screenshots every display of a kept clone (`--front` first brings a running Fluxo to the front). |
| `cleanup.sh` | Deletes clones by name prefix (`fluxo-…` only). |
| `test-stream.sh` | Loopback-only test streams for the player: live HLS, live raw MPEG-TS, on-demand MP4 / TS, and an M3U playlist of them. |
| `gesture-tests.sh` | Real touches on a kept clone (`GestureTests/`, an XCUITest bundle that drives the installed app): mini player tap and swipe up, the player's drag down (follows, springs back, closes on a long drag or a flick, ignores horizontal drags), scrubbing that never closes the player, the X that stops playback, and nothing above the tab bar while nothing plays (at launch, back from the background, after stopping with the tab bar minimized, after a relaunch). Needs `test-stream.sh`; quit Fluxo on other booted clones first, since every simulator shares the Mac's loopback interface and so the player's local stream port. |
| `contact_sheet.swift` | Combines screenshots into one labelled grid (`run.sh` does it when a run makes several). |

The app side is in `Fluxo/App/Debug` (`DebugLaunchOptions`, `DebugHarness`, `DebugRoutes`, `DebugSeeder`,
`DebugSeedCatalog`, `DebugArtwork`) and is compiled out of Release builds.

## Quick start

```sh
Tools/Simulator/build.sh                                   # once per code change
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1
open /tmp/fluxo-shots/fluxo-mykey-1/shot.png
```

Use your own key in clone names (`fluxo-<key>-<n>`) when several people or agents run simulators at the
same time; `cleanup.sh fluxo-<key>-` then deletes only your clones. Clones are copies of your own
simulators: `run.sh` never boots, changes or deletes the simulator it clones, and it refuses to clone one
that is booted. Keep at most two clones booted at a time.

Each run writes to `--out` (default `/tmp/fluxo-shots/<clone>`): the screenshots, `app.log` (the
app's log of this launch, with the harness messages), `app-stdout.log` and `app-stderr.log`.

## Examples

```sh
# iPhone 17e (small screen): Home with the sample library, then a group, search and the player,
# one screenshot after each step plus a contact sheet (shot-contact.png).
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --step-shots \
    --route "home;group:Sport;search:Sky F1;player:Sky Sport F1;close-player"

# iPad Pro 13-inch, dark mode, kept booted for more screenshots.
Tools/Simulator/run.sh --device "iPad Pro 13-inch (M5)" --clone fluxo-mykey-2 --appearance dark --keep
Tools/Simulator/shot.sh fluxo-mykey-2
Tools/Simulator/run.sh --clone fluxo-mykey-2 --keep --no-install --route "settings"   # relaunch, same clone
Tools/Simulator/cleanup.sh fluxo-mykey-2

# iPhone Duo: one screenshot per display (shot-LCD.png, shot-LCD-1.png).
Tools/Simulator/run.sh --device "iPhone Duo" --clone fluxo-mykey-3 --route "player:Test Pattern (HLS)"

# Large Dynamic Type (simctl ui content_size; the in-app alternative is -FluxoDebugDynamicType accessibility3).
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --content-size accessibility-extra-large

# Another language: -AppleLanguages / -AppleLocale for the app only.
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --language it --name it
# Right-to-left layout (Arabic and Hebrew switch to it once the app has those localizations).
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --name rtl -- -NSForceRightToLeftWritingDirection YES

# The large library (about 46,000 entries) on an on-disk store, its artwork from the test-stream server.
Tools/Simulator/test-stream.sh start
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --seed large --store temp \
    --route "playlist:Mega IPTV;search:Sport 5"

# The real import pipeline with a playlist served on the loopback interface, no seed, forced dark mode.
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --seed none --route "group:Test Streams" \
    -- -FluxoDebugImportPlaylist http://127.0.0.1:18080/playlist.m3u -FluxoDebugAppearance dark

# Playback: the live raw MPEG-TS channel (remux engine), then the mini player.
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --step-shots \
    --route "player:Test Pattern (MPEG-TS);wait:8;close-player"

Tools/Simulator/test-stream.sh stop
Tools/Simulator/cleanup.sh fluxo-mykey-
```

A clone that `run.sh` boots gets 5 s to settle before the app is installed (`FLUXO_SIM_BOOT_SETTLE=<s>`
changes it), and the running app is brought to the front once before the first screenshot (same process,
same state): on a busy Mac, SpringBoard sometimes finishes its first-boot work after the launch and the
screenshots then show the Home Screen while the app runs behind it.

Everything after `--` is passed to the app, so any launch argument below (and the older
`-FluxoDebugAutoplayURL`, `-FluxoDebugRecordSeconds`, `-FluxoDebugPictureInPicture` of
`DebugAutoplay.swift`) can be combined with the script options. `run.sh --help` lists the options.

## Launch arguments (Debug builds)

The harness only reads launch arguments (the argument domain), never persisted defaults, and does
nothing when none of these is passed.

| Argument | Effect |
|---|---|
| `-FluxoDebugStore memory\|temp\|scratch` | Isolated library: in memory; a fresh SQLite store in `tmp/FluxoDebug` (deleted at the next launch); or a separate store in `Application Support/FluxoDebug/Scratch`, kept between launches (seeded only while it is empty). Settings (`UserDefaults.fluxo`, a separate suite, cleared for `memory` / `temp`) and recordings are isolated too. An unknown value falls back to `memory`, never to the real library. |
| `-FluxoDebugSeed sample\|large` | Seeds the library (implies `-FluxoDebugStore memory`). See "Seeded content". |
| `-FluxoDebugImportPlaylist <url>` | Imports a playlist through the real pipeline at launch (implies `-FluxoDebugStore memory`). |
| `-FluxoDebugRoute "<route>[;<route>…]"` | Opens screens once the library is ready, see "Routes" (implies `-FluxoDebugStore memory`: some routes write watch history and settings). |
| `-FluxoDebugPauseAfterEachRoute YES` | After each route, waits (up to 60 s) until the script has taken its screenshots (`run.sh --step-shots`). |
| `-FluxoDebugAppearance light\|dark` | Forces the color scheme of the window (`simctl ui appearance` changes the whole simulator instead). Alone, it keeps the real library (it writes nothing). |
| `-FluxoDebugDynamicType <size>` | Forces a Dynamic Type size: `xSmall` … `xxxLarge`, `accessibility1` … `accessibility5`, or the `simctl` names. Alone, it keeps the real library (it writes nothing). |
| `-FluxoDebugTestStreamURL <url>` | Base URL of the test-stream server used by the seeded "Loopback Test" playlist and the large seed's artwork (default `http://127.0.0.1:18080`). |

Other useful system arguments: `-AppleLanguages "(de)" -AppleLocale de_DE`,
`-NSForceRightToLeftWritingDirection YES` (right-to-left layout in any language),
`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL`.

While seeding, a small "hammer" capsule shows the progress at the top of the window. The harness writes
`tmp/FluxoDebug/Status/step-<n>` after each route (also after an unknown or failed one, with the problem
in the file) and `ready` at the end (in the app's data container); `run.sh` waits for these files instead
of sleeping.

### Routes

`name` or `name:argument`, several separated by `;`, run in order with a 1.2 s pause after each.
Names are matched case-insensitively; playlists, groups and channels by exact name first, then by the
first that contains the text.

| Route | Opens |
|---|---|
| `home` | Home, from its root. |
| `tab:<home\|guide\|favorites\|settings\|search>` | A tab (iOS). |
| `guide` | The TV Guide (the Guide tab on iOS, the sidebar item on macOS). |
| `search[:<query>]` | Search, with the query typed in. |
| `settings` | The Settings tab (iOS) or window (macOS). |
| `favorites`, `history` | Favorites; Recently Watched. |
| `recordings` | The Recordings sheet (iOS) or sidebar item (macOS). |
| `playlist:<name\|all>` | Selects a playlist (or All Playlists) on Home. |
| `kind:<live\|movies\|series>` | The Live TV / Movies / Series section of Home. |
| `group:<name>` | Pushes a category (group) on Home. |
| `categories:<live\|movies\|series>` | Pushes the category browser of a kind on Home. |
| `browse:<order>[,<layout>]` | Order (`playlist`, `name`, `recentlyAdded`, `mostWatched`) and layout (`list`, `grid`) of every category. |
| `home-section:<onNow\|browse>` | Scrolls Home to a section. |
| `seed-guide` | Adds a sample TV guide for the live channels of every playlist (for On Now, now / next in rows, schedules). |
| `progress:<channel>` | Marks a movie or episode as watched up to 40 % (Continue Watching, progress bars). |
| `schedule:<channel>` | The schedule sheet of a live channel (needs a guide, e.g. `seed-guide`). |
| `player:<channel>` | Plays a channel full screen. |
| `mini-player:<channel>` | Plays a channel with the player closed, so the mini player shows. |
| `play-url:<url>` | Plays any URL full screen. |
| `close-player`, `stop` | Closes the player screen (playback continues); stops playback. |
| `dismiss-player` | Closes the player like its chevron or a swipe down (into Picture in Picture when the device supports it; the Simulator does not, so the mini player shows). |
| `open-player` | Opens the player for what plays, like a tap on the mini player. |
| `player-drag:<points>` | Holds the player screen dragged down by that many points, as a finger would (`player-drag:0` releases it). |
| `overscroll:<points>` | Shows Home as if pulled down by that many points (the billboard stretches over the gap); `overscroll:0` resets it. |
| `pip` | Starts Picture in Picture once the item allows it. |
| `add-playlist`, `edit-playlist:<name>`, `delete-playlist:<name>` | The Add / Edit Playlist sheet; the delete confirmation (nothing is deleted). |
| `wait:<seconds>` | Waits before the next route. |
| `help` | Logs the list of routes (in `app.log`). |

Routes drive the app through `AppNavigation` (`Fluxo/App/AppNavigation.swift`: the selected tab or
sidebar item, the Home / Favorites / Search navigation paths, the search text and the Recordings sheet)
and the app's own objects (player, library, import center, playlist actions). A new screen gets a route
with one line in `DebugRoutes.all`:

```swift
DebugRoute("guide", "The TV Guide.") { context, _ in context.navigation.show(.guide) },
```

The seeded libraries have no TV guide; the `seed-guide` route adds a sample one to them. The guide demo of
`DebugGuideDemo.swift` is another way (an in-memory store with sample playlists and two days of sample
programmes; it replaces the seeded library, so pass `--seed none`):

```sh
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --seed none --route guide -- -FluxoDebugGuideDemo YES
```

Unknown routes and failures (e.g. no channel with that name) are logged and skipped, and the next steps
still run. With `--step-shots` the step is still screenshotted and `run.sh` shows the problem
(`Step 3: bogus (unknown route)`); unknown route names are logged at launch, before seeding, and
`run.sh` prints every problem at the end.

### Seeded content

`sample` (about 380 entries in 33 groups, ready in about 2 s) is imported through the real pipeline from
generated M3U files, then gets favorites, a watch history and three recordings:

- **Sky Italia**: Italian live TV in 8 groups (Sport, Intrattenimento, Cinema, News, Rai, Mediaset, Kids,
  Musica), with "Sky Sport F1", "IT | Sky Sport F1 FHD", quality tags and a very long channel name.
- **World TV**: 11 country groups ("UK | Sport", France, Deutschland, España…), including Japanese,
  Arabic and Greek names.
- **Cinema Club**: 96 movies in 8 groups and 4 series groups (episodes `Show S01E01`), with Xtream-style
  `/movie/` and `/series/` URLs.
- **Loopback Test**: "Test Pattern (HLS)", "Test Pattern (MPEG-TS)", "Test Clip (MP4)", "Test Clip
  (MPEG-TS)" (the streams of `test-stream.sh`) and "Unreachable Channel" (fails at once).

Live channels have iptv-org style `tvg-id`s (`SkySportF1.it`, `BBCOneHD.uk`). Logos and posters are
drawn locally and stored as `data:image` URIs, in the styles real playlists use: filled, transparent,
dark-on-transparent (hard to read in dark mode), wide and square; every ninth channel has none, and two
have logos that cannot load. Other seeded streams use the host `seed.fluxo.invalid`, which never
resolves: playing one shows the player's error state.

`large` adds "Mega IPTV" (30,000 live channels in 300 groups) and "Mega VOD" (12,000 movies and 4,200
episodes in 30 groups), about 6 s. Their logos are http URLs of the test-stream server; without it they
show placeholders.

## Test streams

```sh
Tools/Simulator/test-stream.sh start     # background; or no argument for the foreground
Tools/Simulator/test-stream.sh status
Tools/Simulator/test-stream.sh stop
```

It serves on `127.0.0.1:18080` only (`PORT=` changes the port; the address cannot be changed, and the iOS
Simulator shares the Mac's loopback interface): `/playlist.m3u`, `/hls/live.m3u8` (live HLS with a 2
minute window, played directly by AVPlayer), `/live/test-pattern` and `/live.ts` (live raw MPEG-TS
through the remux engine, one real-time encoder per client, at most 4 at once, more get 503),
`/movie/clip.mp4` and `/movie/clip.ts` (60 s on demand, with byte ranges), and `/logo/<n>.png`,
`/poster/<n>.png`. It needs `ffmpeg` (`/opt/homebrew/bin/ffmpeg`, or `FFMPEG=`), and `/usr/bin/python3`.
The content is synthetic test patterns, so the loopback bind is its only protection; do not change it.

## iPhone Duo

The iPhone Duo simulator has two integrated displays, `LCD` and `LCD-1`; `run.sh` and `shot.sh`
screenshot both (`--display=` of `simctl io`). The screens are listed by `xcrun simctl io <udid>
enumerate`, and `xcrun simctl io <udid> screenConfig --display=LCD power off|on` switches one off.

What the screenshots showed with the current app (iOS 27.2 runtime): on `LCD` (1398 x 2034 px) the app
runs with the status bar and the tab bar along the right edge and its content clipped on that side;
`LCD-1` (2007 x 2853 px) stays black, both on the Home Screen and with Fluxo running, and switching `LCD`
off does not light it up. `simctl` has no fold or posture control, so whatever makes the second display
show content has to come from the app (e.g. a scene for that display) or from Simulator.app.

## Driving the simulator (taps and swipes)

`gesture-tests.sh` drives a kept clone with real touches through XCUITest (no approval needed): add a test to
`GestureTests/GestureTests.swift` for any gesture to check; it launches Fluxo with the harness arguments and
writes screenshots. Otherwise `simctl` cannot tap or swipe. The Xcode MCP `DeviceInteraction*` tools (`DeviceInteractionStartSession`,
then `DeviceInteractionSynthesize` with commands such as `t 100 200`, which also returns a screenshot and the
UI hierarchy) can, but only after this agent has been approved in Xcode: the first call answers "This
agent isn't approved to use Xcode's tools yet. Call XcodeOpenWorkspace or XcodeNewProject first", and
opening a workspace asks the user for approval. They are not usable unattended; use routes (add one for
any screen you need) and `--step-shots` instead.

## Safety

- Seeding, importing and routes always use an isolated store (`-FluxoDebugStore memory` when none is
  passed), and `run.sh` always passes one: the real library, settings and recordings are never opened.
  Only `-FluxoDebugAppearance` and `-FluxoDebugDynamicType` on their own run on the real library, and they
  write nothing.
- `cleanup.sh` only deletes simulators whose names start with `fluxo-`, and `run.sh` only creates
  such clones.
- Logos with http URLs (only the large seed has them) go through the app's on-disk logo cache, which is
  not isolated; on a simulator clone that is the clone's own cache.
- The macOS app can use the same launch arguments (`open -n Fluxo.app --args -FluxoDebugStore memory
  -FluxoDebugSeed sample`), but it shares the sandbox container, the loopback port and the instance lock
  with a Fluxo you may be running: prefer the simulator.
