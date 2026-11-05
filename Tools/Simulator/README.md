# Simulator test harness

Scripts and Debug-only launch arguments to check the Fluxo UI in iOS and tvOS simulators quickly, with a seeded
library that never touches a real one. Everything here runs on the Mac; nothing needs the internet.

| Script | What it does |
|---|---|
| `build.sh` | Builds the Debug simulator app once (into `/tmp/fluxo-dd/<worktree folder>-sim`); `--platform tvos` builds the Apple TV one. |
| `run.sh` | Clones a simulator, boots it, installs the app, launches it with the harness, waits until it is ready, screenshots every display, deletes the clone (or keeps it with `--keep`). |
| `shot.sh` | Screenshots every display of a kept clone (`--front` first brings a running Fluxo to the front). |
| `cleanup.sh` | Deletes clones by name prefix (`fluxo-…` only). |
| `test-stream.sh` | Loopback-only test streams for the player: live HLS, live raw MPEG-TS, on-demand MP4 / TS, and an M3U playlist of them. |
| `gesture-tests.sh` | Real touches on a kept clone (`GestureTests/`, an XCUITest bundle that drives the installed app): deleting a TV guide source by swipe and by context menu in Settings and in the Guide Sources sheet over the Guide (`testDeleteGuideSource…`; the swipe used to crash), mini player tap and swipe up, the player's drag down (follows, springs back, closes on a long drag or a flick, ignores horizontal drags), scrubbing that never closes the player, scrubbing a movie with a real finger (`testScrubbingMovieFollowsTheFingerAndSeeks`: the time follows the finger, the bar stays at the target after the release, the seek plays; `TEST_RUNNER_FLUXO_TEST_STREAM_URL` may point at a throttled `vod_server.py`), the X that stops playback, and nothing above the tab bar while nothing plays (at launch, back from the background, after stopping with the tab bar minimized, after a relaunch), the Audio and Subtitles menu (`testTracks…`: a Matroska file's tracks through the engine, a loaded subtitle file with its timing controls and the document picker, a live channel with two audio tracks, the receiver's tracks while casting; `TEST_RUNNER_FLUXO_TEST_STREAM_URL` for a test-stream server on another port), and Copy Link / Share in the menus of a channel row, a Home card, the player, its side panel (iPad), a series card ("Copy Episode Link"), a series page and a TV guide programme (`testCopyLink…`; `TEST_RUNNER_FLUXO_APPEARANCE=dark` for dark mode). Needs `test-stream.sh`; quit Fluxo on other booted clones first, since every simulator shares the Mac's loopback interface and so the player's local stream port. |
| `accessibility-audit.sh` | The Xcode accessibility audit (`AccessibilityAudit/`, an XCUITest bundle) of 15 screens of the installed app on a kept clone, in the variants `default`, `ax5` (the largest text size; also audits Dynamic Type and clipped text) and `contrast` (dark mode, Increase Contrast). One `report.txt` per variant with every issue, accepted ones marked with the reason (`knownIssues`), and a screenshot per screen, in `/tmp/fluxo-shots/<clone>/accessibility-audit/<variant>/`. With `FLUXO_TEST_STREAM_URL` (test-stream.sh running) it also checks the player's Audio and Subtitles menu. |
| `siri-tests.sh` | The system side of the App Intents on a kept clone (`SiriTests/`, an XCUITest bundle): the Shortcuts app lists Fluxo's ten App Shortcuts and runs What's On in the running app, the action search is screenshotted, Spotlight finds a seeded favorite and opening it plays it in Fluxo, and Siri is asked two phrases. Screenshots and hierarchy dumps (Spotlight's results are in its own process, `com.apple.Spotlight`) in `/tmp/fluxo-shots/<clone>/siri-tests/`. On iOS 27.2 the Simulator has no Siri ("not enabled on this device"): try phrases on a device. |
| `format-matrix.sh` | The format matrix in the app (`--device`, `--clone`, optional case words): plays a file of each common container / video / audio codec combination (the media of `Tools/EngineSmokeTest/run_formats.sh`, served on 127.0.0.1) with `play-movie:`, then `probe-tracks`, `probe-playback`, a skip, a scrub and a skip back; one clone boot for every case. Summary in `/tmp/fluxo-shots/<clone>/formats/summary.txt`. |
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
| `-FluxoDebugCast simulated` | Uses the simulated Chromecast receiver from launch instead of the Google Cast SDK (the `cast:` route switches to it too). Nothing goes on the network. |
| `-FluxoDebugIntelligence available\|off\|unavailable\|notReady\|unsupported` | Forces the Apple Intelligence status (`FluxoIntelligence`), e.g. `unavailable` to see the built-in suggestions and search on a simulator that has the model. Alone, it keeps the real library. |
| `-FluxoDebugTestStreamURL <url>` | Base URL of the test-stream server used by the seeded "Loopback Test" playlist and the large seed's artwork (default `http://127.0.0.1:18080`). |
| `-FluxoDebugPower low-power\|normal\|fair\|serious\|critical` | Pretends Low Power Mode or a thermal state from launch (see the `power:` route). Alone, it keeps the real library (it writes nothing). |
| `-FluxoDebugLoopbackPort <port>` | Port of the player's loopback HLS server (default 19123, always on 127.0.0.1). Every simulator shares the Mac's loopback interface: give clones that play at the same time different ports. |

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
| `tab:<home\|guide\|library\|settings\|search\|playlist name>` | A tab (iOS, tvOS; playlists are iPad sidebar entries). |
| `focus:<channel>` | Apple TV: moves the focus to the card of that channel (its exact name) on the page shown, for screenshots of the focused state. |
| `guide` | The TV Guide (the Guide tab on iOS, the sidebar item on macOS). |
| `search[:<query>]` | Search, with the query typed in. |
| `settings` | The Settings tab (iOS) or window (macOS). |
| `library` | The Library tab (iOS) or the Recordings sidebar item (macOS). |
| `favorites`, `history` | Favorites; Recently Watched (pushed on the Library tab on iOS). |
| `recordings` | The Library tab, which lists the recordings (iOS), or the Recordings sidebar item (macOS). |
| `playlist:<name\|all>` | Selects a playlist (or All Playlists) on Home. |
| `kind:<live\|movies\|series>` | The Live TV / Movies / Series section of Home. |
| `group:<name>` | Pushes a category (group) on Home. |
| `categories:<live\|movies\|series>` | Pushes the category browser of a kind on Home. |
| `browse:<order>[,<layout>]` | Order (`playlist`, `name`, `recentlyAdded`, `mostWatched`) and layout (`list`, `grid`) of every category. |
| `home-section:<forYou\|onNow\|browse>` | Scrolls Home to a section. |
| `seed-guide` | Adds a sample TV guide for the live channels of every playlist (for On Now, now / next in rows, schedules). |
| `add-guide-source[:<days>]` | Adds a guide "added by you", "Debug Guide" (the kind Settings can delete), with half-hour programmes for every live channel over 7 days (1 to 14), written in the background like an import (about 56,000 programmes for the sample library, 112,000 over 14 days). |
| `delete-guide-source[:<name>]` | Deletes a guide source (the Debug Guide by default) as its Delete button does and checks that its row leaves at once, that no source, programme, channel or manual match of it is left and that the guide no longer uses it; the step fails otherwise. Logs the time and the longest main-actor stall. |
| `progress:<channel>` | Marks a movie or episode as watched up to 40 % (Continue Watching, progress bars). |
| `series:<title>` | Pushes the page of a series on Home. |
| `watched:<episode>` | Records an episode as played to the end (it counts as watched; Continue moves on). |
| `remove-from-history:<channel>` | Removes a Continue Watching card like its context menu does (for an episode, its whole series). |
| `favorite-series:<title>` | Adds a series to the favorites. |
| `featured-series:<playlist>` | Selects a playlist on Home whose billboard then starts at its first series. |
| `audio-track:<name\|number>` | Chooses an audio track of what plays (by name, e.g. `Italian`, or 1-based number), as the Audio and Subtitles menu does (and so remembers its language). |
| `subtitles:<automatic\|off\|file\|name\|number>` | Chooses the subtitles of what plays (`file`: the loaded subtitle file). |
| `subtitle-file:<url>` | Loads a SubRip / WebVTT file (a file URL, or http such as the test server's `/subtitles/clip.srt`) for the movie or episode that plays, as Load Subtitle File… does. |
| `subtitle-offset:<seconds>` | Shifts the loaded subtitle file (positive: later), as Subtitle Timing does. |
| `tracks-log` | Logs the audio tracks, subtitles and choices of what plays (`Tracks: …` in `app.log`). |
| `seek-end:<seconds>` | Seeks the playing on-demand item to that many seconds before its end. |
| `schedule:<channel>` | The schedule sheet of a live channel (needs a guide, e.g. `seed-guide`). |
| `programme:<channel>[,<artwork>][,long]` | The TV Guide with the programme on now on a channel open (a sheet; the inspector on iPad; needs a guide, e.g. `seed-guide`). `<artwork>` replaces its image with a sample of a size and shape guides carry: `tiny` (32 x 32), `still` (1280 x 720), `huge` (6000 x 3375), `classic` (4:3), `wide` (10:1), `tall` (1:8), `poster` (2:3), `square`, or `none`; `long` gives it a long title, description and category list. |
| `player:<channel>` | Plays a channel full screen. |
| `mini-player:<channel>` | Plays a channel with the player closed, so the mini player shows. |
| `copy-link:<channel>` | Copy Link of a channel, as its menus do: the stream link on the pasteboard and the confirmation toast (held for 20 seconds, for screenshots; with the account-login warning when the link carries credentials). |
| `play-url:<url>` | Plays any URL full screen. |
| `play-movie:<url>` | Plays a URL full screen as a playlist's movie entry would (on demand, also for `.ts` and extensionless links). |
| `probe-tracks[:<a\|v\|av>]` | Checks that what plays has enabled audio and / or video tracks (default both) and logs their formats (`Playback tracks after probe-tracks: video=[avc1] audio=[aac] …` in `app.log`; streams the engine converted show as `avc1` / `aac`). |
| `close-player`, `stop` | Closes the player screen (playback continues); stops playback. |
| `skip:<seconds>`, `seek:<seconds\|percent%>` | Skips (negative: back) like the skip buttons; seeks like the scrubber. Then checks that playback continues there with video frames that are not black and keep up with the clock (`video-lag`: a picture frozen over running audio fails), and logs how long the seek took to play (`latency`): a failure is reported as the step's problem. |
| `probe-playback[:<seconds>]` | The same check without moving (near `<seconds>` when given), e.g. after a relaunch that resumes. |
| `drag:<from>-<to>` | Drags the scrubber from one point to another (seconds or percentages, `drag:10%-40%`) in 20 moves over 0.8 s and releases it, then the same check. |
| `scrub-hold:<seconds\|percent%>`, `scrub-release` | Holds the scrubber at a point as a finger would (the time and, for movies AVPlayer plays itself, the frame preview over the knob; screenshots); releases it there (it seeks; add `probe-playback`). |
| `skip-burst:<seconds>x<count>` | Taps a skip button `<count>` times 150 ms apart (`skip-burst:30x4`): the taps add up into one seek. Then the same check. |
| `seek-pause:<seconds\|percent%>` | Seeks, pauses at once, plays 2 s later, then the same check. |
| `seek-loading:<seconds\|percent%>` | Seeks and returns at once, while the seek loads (screenshots of the loading state). |
| `seek-fail:<seconds\|percent%>` | Pauses and shows a seek there that could not play, as after every recovery step (Try Again over the timeline, `player.seekRetry`; the VoiceOver announcement). |
| `seek-drop:<count\|all>x<seconds\|percent%>` | Seeks there while AVPlayer drops that many seeks in a row (completes them as not finished, as it does while it starts an item; `PlayerSeeker.seekInterceptor`), or every seek. A count must play at the target (the probe), `all` must end with Try Again; neither may stay loading (it used to after a fourth drop). |
| `seek-past-buffer[:direct]` | `direct` seeks AVPlayer itself, as Picture in Picture's skip buttons do. Seeks to 1 s past what the player buffered: through the engine, the segment there was usually written ahead from inside a GOP, and the player asks for it as the next one. Then the same check, with playback within 3 s of the target (it used to start at the next key frame, seconds late, with the bar stuck at the target). |
| `dismiss-player` | Closes the player like its chevron or a swipe down (into Picture in Picture when the device supports it; the Simulator does not, so the mini player shows). |
| `player-guide[:full]` | The player's guide control, like a tap on what is on now in its top bar: the playing channel's schedule, at now, in the side panel (wide players), the other pane (open foldable) or a sheet over the video; `player-guide:full` then chooses Full Guide (the player closes and the TV Guide shows the channel, scrolled to its row, highlighted). Needs a guide, e.g. `seed-guide`. |
| `open-player` | Opens the player for what plays, like a tap on the mini player. |
| `player-drag:<points>` | Holds the player screen dragged down by that many points, as a finger would (`player-drag:0` releases it). |
| `player-controls:<show\|hide>` | Shows the player's controls and keeps them on screen until `player-controls:hide` (screenshots of the controls, the status bar); `hide` hides them like a tap on the video. |
| `overscroll:<points>` | Shows Home as if pulled down by that many points (the billboard stretches over the gap); `overscroll:0` resets it. |
| `pip` | Starts Picture in Picture once the item allows it. |
| `cast:<device>` | Switches to the simulated Chromecast receiver (`Living Room TV`, `Bedroom`, `Kitchen Speaker`) and connects to it; what plays is cast. |
| `cast-picker`, `stop-casting` | The Cast device picker; ends the Cast session (the channel plays on the device again). |
| `add-playlist`, `edit-playlist:<name>`, `delete-playlist:<name>` | The Add / Edit Playlist sheet; the delete confirmation (nothing is deleted). |
| `orientation:<portrait\|landscape>` | Asks the scene to rotate (iPhone; iPadOS refuses it in windowed modes, use `testLayoutScreenshots` below). |
| `side-panel:<channels\|guide\|off>` | Shows the player's side panel (wide players) on a tab, or hides it. |
| `new-window:<channel>` | Opens a channel in a player window of its own (iPad); logs the number of connected scenes. |
| `download:<channel>`, `download-season:<series>[,<season>]` | Downloads a movie or episode, or the episodes of a season, like their Download actions. |
| `download-wait[:<seconds>]`, `download-progress:<fraction>` | Waits until no download is queued, downloading or converting (90 s at most); until every running download reached a fraction of its size (60 s at most). |
| `pause-download:<channel>`, `resume-download:<channel>`, `delete-download:<channel>`, `delete-downloads` | Pauses, resumes (or retries), deletes a download; deletes every download. |
| `downloads`, `downloads-all`, `downloaded-series:<title>` | The downloads in the Library tab (the Downloads item on macOS); every download on its own screen; the downloaded episodes of a series. |
| `play-download:<channel>` | Plays a completed download full screen and appends where it plays from to `Status/downloads.log`. |
| `downloads-log` | Appends every download (state, method, sizes, quality, languages, file, failure) to `Status/downloads.log`. |
| `offline:<on\|off\|system>` | Pretends the device is offline (Home's offline section, the player's offline error), online, or follows the system; `-FluxoDebugOffline YES` does it from launch. Loopback URLs still play offline. |
| `settings-section:downloads` | Settings, scrolled to its Downloads section (iOS). |
| `power:<low-power\|normal\|fair\|serious\|critical\|system>` | Pretends Low Power Mode is on, or a thermal state (`normal`: neither), or follows the system (`-FluxoDebugPower <value>` does it from launch): the player's quality limits (`PlaybackEnergyProfile`), the symbol animations and the guide refresh follow it. |
| `energy-check` | Checks the rules of `PlaybackEnergyProfile` (position sampling, quality limits, display sleep, video decoding for the player screen, the mini player, the background, Picture in Picture, Low Power Mode and the thermal states) and writes `energy-check: ok` or the failures to `Status/power.log`. |
| `power-log` | Appends the energy state to `Status/power.log`: Low Power Mode, the thermal state, background, whether something plays and the guide refresh waits, whether the player layer decodes video, whether the display may sleep, the quality limit of the current item and the player's energy profile. |
| `wait:<seconds>` | Waits before the next route. |
| `intent:<action>[:<words>]` | Runs an App Intent in the app as Siri and Shortcuts do, its channel or programme parameter resolved from the words through the entity query (`ChannelEntityQuery.entities(matching:)`). Actions: `play`, `play-name`, `continue`, `pause`, `resume`, `stop`, `whats-on`, `search-guide`, `find`, `search`, `suggestions`, `favorites`, `favorite-add`, `favorite-remove`, `schedule`, `open` (`home`, `guide`, `search`, `favorites`, `history`, `recordings`, `library`), `record-start`, `record-stop`, `reminder`. Each run appends the dialog, the returned value and the player state to `Status/intents.log`. |
| `siri-resolve:<words>` | Resolves spoken words to a channel like "Play … in Fluxo" (`AppServices.resolveChannel`), with the reason (name, programme, number, closest). |
| `siri-resolve-check` | Checks the channel-number rules (a bare number or one next to "channel"/"number" in any app language is a playlist position; "BBC 9" or "Eurosport 7" is not) and, on the sample library, that names it lacks ("BBC 9", "Eurosport 7", "BBC Four") resolve to nothing instead of another channel. Writes `siri-resolve-check: ok` or the failures. |
| `siri-names` | Lists the channels Siri knows by name for the phrases (the App Shortcut parameters) with their spoken-name synonyms. |
| `visual-search:<line>[\|<line>…][#<label>,…]` | Visual Intelligence's matching: the channels for lines of text read in an image and the system's labels. |
| `visual-ocr:<text>[\|<text>…]` | Draws the texts in an image (the first one large), reads it with the same text recognition as Visual Intelligence images, and matches. |
| `spotlight-reindex`, `spotlight-search:<words>` | Indexes the channels in Spotlight now, timing the call; queries the app's Spotlight items (in the Simulator the query may not complete: it gives up after 10 s). |
| `help` | Logs the list of routes (in `app.log`). |

### Apple TV

The same scripts drive Apple TV simulators: build the tvOS app with `build.sh --platform tvos` and clone an Apple TV
(`run.sh` installs the app of the clone's platform, from its runtime). The library, the launch arguments and the
routes are the same; routes of screens tvOS does not have (the touch player's `player-drag`, `player-controls`,
`player-guide`, `side-panel`; Spotlight, Cast, downloads, foldable postures) fail with "not available on this
platform" or change nothing. The Siri Remote cannot be scripted, so `focus:<channel>` moves the focus for screenshots.
There is no status bar to override. `gesture-tests.sh`, `accessibility-audit.sh`, `siri-tests.sh` and
`format-matrix.sh` are iOS only for now.

```sh
Tools/Simulator/build.sh --platform tvos
Tools/Simulator/test-stream.sh start
# Home with a focused card, then the live HLS and the raw MPEG-TS (remux engine) test streams in the system player.
Tools/Simulator/run.sh --device "Apple TV 4K (4th generation)" --clone fluxo-mykey-tv-1 --step-shots \
    --route "home;focus:Sky Sport F1;player:Test Pattern (HLS);wait:6;probe-playback;stop;player:Test Pattern (MPEG-TS);wait:8;probe-tracks;probe-playback"
Tools/Simulator/run.sh --device "Apple TV 4K (4th generation) (at 1080p)" --clone fluxo-mykey-tv-2 --route "tab:guide"
```

### On-demand seeking

Movies and episodes through the engine (see "On demand through the engine" in the main README), with the
media of `Tools/EngineSmokeTest/run_vod.sh` (start it once to generate them, or serve any folder of movies
with `python3 -I Tools/EngineSmokeTest/vod_server.py --root <folder>`, loopback only):

```sh
python3 -I Tools/EngineSmokeTest/vod_server.py --root /tmp/fluxo-vod-media --port 18930 &
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --step-shots \
    --route "play-url:http://127.0.0.1:18930/series/user/pass/2001.mkv;wait:3;skip:30;seek:50%;seek:90%;skip:-10"
```

The seeded "Test Clip (MPEG-TS)" and "Test Clip (MP4)" are movies (`/movie/` URLs) of the test-stream server:
pointing `-FluxoDebugTestStreamURL` at a folder with `movie/clip.ts` and `movie/clip.mp4` (e.g. links to
`h264.ts` and `hevc-hev1.mp4` of the generated media) plays those as movies, the way a playlist entry is. With a
`scratch` store the position is kept, so a second launch checks the resume:

```sh
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --store scratch --keep \
    --route "player:Test Clip (MPEG-TS);wait:3;skip:30;seek:60%;wait:12;stop" -- \
    -FluxoDebugTestStreamURL http://127.0.0.1:18931 -FluxoDebugLoopbackPort 19151
Tools/Simulator/run.sh --clone fluxo-mykey-1 --store scratch --no-install \
    --route "player:Test Clip (MPEG-TS);probe-playback:372" -- \
    -FluxoDebugTestStreamURL http://127.0.0.1:18931 -FluxoDebugLoopbackPort 19151
```

To see seeks the way a phone on Wi-Fi does, serve a movie with a burned-in counter through the server's latency and
bandwidth limits (`/lat/<ms>/slow/<KB/s>/`) as the seeded test clips (a folder with `movie/clip.mp4`, `movie/clip.ts`,
`movie/clip.mkv`, e.g. made from `testsrc` with a key frame every 10 s). The counter in the picture must match the
timeline after every seek:

```sh
python3 -I Tools/EngineSmokeTest/vod_server.py --root /tmp/fluxo-sim-media --port 18988 &
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --step-shots \
    --route "player:Test Clip (MPEG-TS);wait:6;player-controls:show;scrub-hold:50%;scrub-release;wait:1;probe-playback:300;seek-end:12;wait:6" -- \
    -FluxoDebugTestStreamURL http://127.0.0.1:18988/lat/150/slow/900 -FluxoDebugLoopbackPort 19181
```

The sequence that used to leave the bar stuck at the target while the picture played on, seconds later (a burst of
skips, then a drag just past what the player buffered: the engine had written that segment ahead from inside a GOP):

```sh
--route "player:Test Clip (MPEG-TS);wait:6;player-controls:show;scrub-hold:40%;scrub-release;seek-loading:45%;probe-playback:270;skip-burst:30x4;seek-past-buffer;drag:20%-70%"
```

Routes drive the app through `AppNavigation` (`Fluxo/App/AppNavigation.swift`: the selected tab or
sidebar item, the Home / Library / Search navigation paths and the search text)
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

`sample` (about 380 entries in 34 groups, ready in about 2 s) is imported through the real pipeline from
generated M3U files, then gets favorites, a watch history and three recordings:

- **Sky Italia**: Italian live TV in 8 groups (Sport, Intrattenimento, Cinema, News, Rai, Mediaset, Kids,
  Musica), with "Sky Sport F1", "IT | Sky Sport F1 FHD", quality tags and a very long channel name.
- **World TV**: 11 country groups ("UK | Sport", France, Deutschland, España…), including Japanese,
  Arabic and Greek names.
- **Cinema Club**: 96 movies in 8 groups and 11 series in 4 groups, with Xtream-style `/movie/` and `/series/`
  URLs. Each series names its episodes in another provider style (`Orbit S01E01`, `Harbor Lights S01 E01 - Title`,
  `The Night Desk 1x01 Title`, `Paper Kings Stagione 1 Episodio 1`, `IT: Office Plants S01E01 [MULTI] FHD`,
  `Deep Field (2021) S01E01`, `The Lantern Protocol Staffel 1 Folge 1`, `Sky Runners Episode 1`, …); Orbit has
  three seasons.
- **Loopback Test**: "Test Pattern (HLS)", "Test Pattern (MPEG-TS)", "Test Clip (MP4)", "Test Clip (Audio and Subtitles)", "Test Clip (Matroska Tracks)", "Test Pattern (Two Audio Tracks)", "Test Clip
  (MPEG-TS)" (the streams of `test-stream.sh`), "Unreachable Channel" (fails at once), and "Test Series" (two
  playable 60 s episodes, for the player's next-episode card: `player:Test Series S01E01;wait:62`, and a third one
  served slowly, so its download shows its progress). For the downloads: "Test Clip (Matroska)" and "Test Clip
  (Xtream)" (the Matroska clip, named and at an extensionless path: downloads convert it into MP4), "Test Movie (HLS)"
  (the HLS with audio and subtitle renditions at a movie path) and "Test Clip (Slow Download)" (about 300 KB/s).

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
`/live/two-audio` (live raw MPEG-TS with an English AAC and a German AC-3 track: "Test Pattern (Two Audio
Tracks)"), `/movie/clip.mp4` and `/movie/clip.ts` (60 s on demand, with byte ranges; `?slow=1` sends the MP4 at about 300
KB/s, as does `/movie/slow.mp4`), `/movie/clip.mkv` and `/movie/play/42` (the clip as Matroska, named and
extensionless), `/movie/tracks.mkv` (60 s Matroska with English AAC and Italian AC-3 audio, SubRip English, ASS Italian
and forced English subtitles, played through the remux engine: "Test Clip (Matroska Tracks)"), `/movie/tracks/…` (the
HLS of `/tracks/` at a movie path), `/subtitles/clip.srt` (a SubRip file for the 60 s clips), `/tracks/master.m3u8` (60 s on demand HLS with an English and an Italian audio rendition, the latter tagged as an audio description, and English SDH and Italian WebVTT subtitles: "Test Clip (Audio and Subtitles)"), and `/logo/<n>.png`,
`/poster/<n>.png`. It needs `ffmpeg` (`/opt/homebrew/bin/ffmpeg`, or `FFMPEG=`), and `/usr/bin/python3`.
The content is synthetic test patterns, so the loopback bind is its only protection; do not change it.

## iPhone Duo

The iPhone Duo simulator has two integrated displays, `LCD` and `LCD-1`; `run.sh` and `shot.sh`
screenshot both (`--display=` of `simctl io`). The screens are listed by `xcrun simctl io <udid>
enumerate`, and `xcrun simctl io <udid> screenConfig --display=LCD power off|on` switches one off.

The simulator is a book-style foldable (`iPhone19,4`): `LCD` is the cover display (466 x 678 pt, the
hinge side on the left, used folded) and `LCD-1` the inner display (669 x 951 pt, natively landscape, 951 x
669 pt, folding across its middle). The clone boots folded: the app runs on `LCD`, reports its hinge as
closed (`onHingeChange`), no reserved regions, and the system puts the status bar, the toolbar items and the
tab bar in one vertical bar on the trailing edge (`UITraitCollection.verticalBarEdge`, part of the safe area).
`LCD-1` stays black. Neither `simctl` nor Xcode's tools can open the hinge (the runtime's own display-swap
tool is not shipped), so the inner display and the open postures cannot be seen in the simulator.
Harness runs log what the app receives (`Display posture: window 466 x 678; hinge closed 0°; …` in
`app.log`).

To check the layouts of the open postures, simulate one on a larger simulator (the iPad Pro 13-inch shows the
951 x 669 pt inner display centered, with a dashed line on the fold):

```sh
Tools/Simulator/run.sh --device "iPad Pro 13-inch (M5)" --clone fluxo-mykey-2 --step-shots \
    --route "seed-guide;player:Sky Sport F1;posture:flat;posture:tabletop;posture:closed" -- -FluxoDebugPosture book
```

| Argument / route | Effect |
|---|---|
| `-FluxoDebugPosture closed\|book\|flat\|tabletop` | Simulated hinge and fold: closed; partly open with the fold from top to bottom (book); fully open (flat); partly open with the fold from side to side (the phone standing like a laptop). |
| `-FluxoDebugPostureSize <w>x<h>\|full` | Size of the simulated display (default 951x669, 669x951 for tabletop, 466x678 for closed); `full` keeps the window. |
| `posture:<closed\|book\|flat\|tabletop\|real>` | Changes the simulated posture while the app runs (playback continues). |

`GestureTests.testFoldableChannelListScrollsAndSwitchesWithoutClosing` (needs a simulator of at least
951 x 669 pt) scrolls the channel list next to the video, switches channel from it and hides it.

## Landscape screenshots

`simctl` cannot rotate a simulator, and iPadOS ignores the app's own rotation requests in its windowed modes.
`GestureTests/testLayoutScreenshots` turns the device with XCUITest instead: each scene (`name|portrait or
landscape|light or dark|route`, separated by `;;`) launches the app with the harness, runs the route, turns the
device and takes `<name>.png`:

```sh
Tools/Simulator/run.sh --device "iPad Pro 13-inch (M5)" --clone fluxo-mykey-2 --keep
TEST_RUNNER_FLUXO_LAYOUT_SHOTS="home|landscape|dark|seed-guide;home;;panel|landscape|dark|seed-guide;side-panel:channels;player:Sky Sport F1" \
    Tools/Simulator/gesture-tests.sh fluxo-mykey-2 -only-testing:GestureTests/GestureTests/testLayoutScreenshots
```

The test turns the device back to portrait at the end; with `TEST_RUNNER_FLUXO_LAYOUT_KEEP_ORIENTATION=1` it
leaves it turned, and as a clone keeps its last orientation, later `run.sh` runs on it (cold launches with
`simctl launch`) are in landscape too. `testDragChannelOntoLibraryTab`
(iPad) drags a channel row onto Library in the sidebar and checks that it became a favorite.
`testSidePanelScheduleMenu` (iPad) opens the context menu of a row in the player's side panel, checks that it has
no guide matching, and that Today's Schedule shows the schedule in the panel, with a way back.

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
