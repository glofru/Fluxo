# Fluxo

Fluxo is a SwiftUI IPTV / M3U player for iOS and macOS.

## Building

Open `Fluxo.xcodeproj` in Xcode 26 or later and run the `Fluxo` scheme.
The app needs iOS 26.1 / macOS 26 (iOS 26.1 is the first release that can hide the tab bar accessory, so
the mini player shows only while something plays).

Live streams go through a small C remux engine
(`Fluxo/Features/Player/Engine`) built on FFmpeg's libavformat, libavcodec
and libavutil. The engine copies the stream into HLS segments on disk, and a
local HTTP server bound to `127.0.0.1` gives them to AVPlayer.

There is nothing to install: FFmpeg ships with the repository (see "FFmpeg" below), and the
Swift packages, [FlyingFox](https://github.com/swhitty/FlyingFox) (the loopback HTTP server) and
Google's [Cast SDK](https://github.com/googlecast/google-cast-ios-sdk) (iOS only, see "Chromecast"
below), are resolved by Xcode on its own. The app builds for iOS devices, the iOS Simulator and
macOS.

The macOS build is signed ad hoc ("Sign to Run Locally") so that it builds without a Mac
Development certificate. To distribute the app, set the macOS code signing style back to
Automatic. `Fluxo/Fluxo-macOS.entitlements` grants the sandbox `network.client` (to read
streams) and `network.server` (for the loopback HLS server). It also has
`com.apple.security.cs.disable-library-validation`, which only the ad hoc signature needs: an ad
hoc signature has no Team ID, so the hardened runtime's library validation would refuse to load
the embedded `FFmpeg.framework`. Remove that entitlement when you sign with a development team.

Command-line builds:

```sh
# iOS device (unsigned)
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO

# iOS Simulator
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

# macOS
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -destination 'platform=macOS' build
```

The SwiftData schema is the list in `Fluxo/App/Database/ModelRegistry.swift`; add new `@Model`
types there. `.swiftlint.yml` configures [SwiftLint](https://github.com/realm/SwiftLint) for
manual runs (`swiftlint lint`); it is not part of the build.

### FFmpeg

`Vendor/FFmpeg/FFmpeg.xcframework` is a minimal FFmpeg 9.0.2 built from the official release
tarball by `Tools/FFmpeg/build-xcframework.sh` (pinned version and SHA-256, plus the release
signature when `gpg` is installed). It contains one dynamic framework, `FFmpeg.framework`,
with libavformat, libavcodec and libavutil linked into a single library that exports only the
public API (`av_*`, `avio_*`, `avcodec_*`, `avformat_*`, `avutil_*`, `avsubtitle_*`; no internal
`avpriv_*` / `ff_*` symbols), for iOS (arm64), the iOS Simulator (arm64, x86_64) and macOS
(arm64, x86_64: macOS 26 still runs on Intel Macs, and Xcode builds universal Release apps).
The public headers are in `Vendor/FFmpeg/include`, and `Vendor/FFmpeg/BUILD_INFO.txt` lists the
exact configuration.

- **Remux only**: everything is disabled except what the engine reaches: the MPEG-TS, HLS,
  MP4/MOV, FLV, Matroska, MPEG-PS, RTSP/RTP and elementary audio/video demuxers, WebVTT (the HLS
  demuxer probes the subtitle renditions of a master playlist and fails without it), the MPEG-TS and
  MP4 muxers, the file, HTTP(S), TCP, TLS, UDP, RTP, RTMP(S/T) and AES (`crypto`) protocols, the
  H.264 / HEVC / AAC / AC-3 / MPEG audio parsers, the decoders `avformat_find_stream_info` uses
  to read stream parameters (H.264, HEVC, AAC, AC-3, E-AC-3, MP3, and the MP2 audio and MPEG-2
  video of DVB-derived channels; without a decoder a live input waits out the whole 3 s probe),
  and the bitstream filters the muxers insert (`aac_adtstoasc`, `h264_mp4toannexb`,
  `hevc_mp4toannexb`, `extract_extradata`).
  No filters, scalers, resamplers, devices or programs. `srt://` needs libsrt (and a crypto
  library), which is not included: such channels fail at once with "Unsupported stream type".
- **HTTPS** uses Secure Transport, the TLS backend FFmpeg has for Apple platforms without an
  extra library, with the system trust store and certificate verification on (TLS 1.2). The only
  external libraries are Secure Transport and the system zlib, so nothing is taken from Homebrew.
- **License**: the build enables no GPL, version 3 or non-free component, so it is LGPL v2.1 or
  later. It is linked dynamically and embedded as `Fluxo.app/Frameworks/FFmpeg.framework`
  (`Contents/Frameworks` on macOS), so it can be replaced with another build of the same
  library; the license text is in `Vendor/FFmpeg/LICENSE` and inside the framework. Anyone
  distributing the app must also offer the FFmpeg source (the release tarball) and this build
  script.
- **Rebuild** (about 5 minutes; Xcode only, no Homebrew packages): `Tools/FFmpeg/build-xcframework.sh`.
  To add a component, add it to the lists at the top of the script, rebuild and run
  `Tools/FFmpeg/check.sh`, which checks the version, the license and the components, and opens
  any URLs passed to it (`Tools/FFmpeg/check.sh https://…` checks HTTPS).

## Playlist import

Playlists are streamed from the network (`DownloadManager`), parsed incrementally
by a byte-level M3U parser (`M3UParser`), and stored in batches on a background
`ModelContext` (`PlaylistImporter`). The main actor only receives throttled
progress (`PlaylistImportCenter`). A refresh writes a complete new copy of the
channels and switches to it only when the copy is fully stored. If the refresh is
cancelled or fails, the previous channels are kept.

To benchmark the old and new pipelines on a synthetic 100k-entry playlist, and to
run the parser edge-case self test:

```sh
Tools/PlaylistBenchmark/run.sh             # ENTRIES=20000 for a quicker run
```

## Home, favorites and search

- **Home** (`Features/Home`) shows the featured billboard, a playlist switcher ("All Playlists" plus one
  chip per playlist), Continue Watching (movies and episodes with a progress bar and the time left, live
  channels with what is on now), On Now (large cards of what the user's favorite and recent channels show,
  from the TV guide, topped up with other channels of the scope that have a guide; hidden without a guide),
  Favorites, Because You Watched (more of the category of the last thing watched), then the groups of the
  chosen kind (Live TV / Movies / Series): a strip of category cards and a lazy row per group with its
  first 24 channels. Group rows are fetched 8 at a time as they scroll in.
- **Category browsing** (`Features/Browse`): category cards show an artwork mosaic of the first channels
  with a logo (four logos, or three fanned posters; one indexed fetch of 4 rows per card) and the count.
  "See All" of the strip opens the category browser (every category of the kind, two or more columns, a
  name filter, playlist / A–Z / size order, 60 cards per page). A category (`CategoryDetailView`) has a
  pinned bar of its sibling categories to hop between them without going back, a list (channel numbers,
  logos, LIVE, the programme on air with its progress and time left, what comes next) or a grid, the
  orders Channel Number / Name (A–Z) / Recently Added (last playlist entries first, where providers append
  new VOD) / Most Watched (the most played channels of the category from the history, then the rest), a
  search within the category (500 matches at most), and an A–Z quick scroller on the trailing edge in the
  A–Z order (it reads only the names of the category). Channels are fetched as values on a background
  context, 120 at a time. The order and layout are remembered per kind, and the first row seen per
  category and order (60 categories at most, offsets only), so coming back scrolls to where you left.
- **Channel numbers** are the position of the entry in its playlist, from 1, as set-top boxes number them.
- **Channel rows** swipe right to play, left to add or remove the favorite and to open the channel's
  schedule (today and the next days from the guide, with reminders); the context menu has the same actions.
- **Favorites** (`Features/Favorites`): what the favorites show now, as large cards, then every favorite with
  its artwork, playlist and category, the programme on air with its progress and what follows (or the watch
  progress of a movie), in sections by type or playlist (or none), a type filter, swipe and menu actions, and
  the user's own order (Edit on iOS, drag on macOS; `ChannelBookmark.favoriteOrder`, new favorites first).
- **Watch progress** (`WatchProgressRecorder`): the position of movies and episodes is saved every 10 s of
  playback, on pause, at the end, when another item starts and when the app leaves the foreground, and
  playback resumes there (once the item can seek that far, within 20 s of the start). The last 3 % (at most
  5 minutes) count as watched and clear the position; positions under 30 s are not resumed. The context menu
  offers Play from Beginning. Recently Watched lists the history by day.
- **Content kinds** are guessed once at import time (`ChannelContentKind`) from
  the URL (Xtream `/movie/` and `/series/` paths, file extensions) and from the
  names (`S01E02`, "Series" groups). Each group gets the most common kind of its
  channels. Playlists imported before this change show as Live TV until refreshed.
- **Favorites and watch history** are `ChannelBookmark` rows keyed by
  playlist + stream URL, so they survive refreshes (which rewrite channel rows),
  and they are deleted with their playlist. The history keeps the 200 most recent
  entries.
- **Search** is token based (`SearchMatcher`, `ChannelSearchIndex`): every word of the query must
  match a word of a channel or group name, in any order ("Sky F1" finds "Sky Sport F1", "f1 sky"
  too), ignoring case, accents, width and punctuation ("IT | Sky-Sport" = "it sky sport"). A word
  matches exactly, as a prefix, inside a word, across words ("skysport"), or, for words of 4+
  letters, with one typo (two from 8 letters; digits never). Results are ranked: the exact name,
  then names that start with the query, then by match quality, words in order and fewer extra words.
  The names of each visible import are read once into memory (on a background context, about a
  second for 100k channels, started when Search appears), and each keystroke then scans them in
  about 5 ms (50 ms for a typo search), 250 ms after the last keystroke. Only the best 150 channels
  and 20 groups are fetched from the store.
- **macOS** uses a sidebar (Home, TV Guide, Search, Favorites, Recently Watched,
  Recordings, and each playlist) and a Settings window (Cmd-,). iPhone uses tabs; iPad uses a sidebar-adaptable
  tab view (see "iPad" below).

To check every Home and Search query against an on-disk store (100k channels), including the token
search (matches, ranking, typos) and its timings:

```sh
CHANNELS=100000 Tools/HomeQueriesCheck/run.sh
```

## Player

- **Routing** (`PlaybackRoute`): HLS playlists and MP4/MOV files play directly in
  AVPlayer. Raw MPEG-TS channels (no extension or `.ts`, or `udp://`, `rtp://`,
  `rtmp://`, `rtsp://`) go through the remux engine, which writes local HLS that
  AVPlayer reads from the loopback server (`127.0.0.1:19123` only).
  Live channels with `.m3u8` URLs play directly in AVPlayer, so they use the
  DVR window of the source playlist (if it has one) and cannot be recorded.
  An on-demand `.ts` file served over HTTP ends normally once its last byte is
  read; any other end of a live input is treated as a dropped connection.
- **Deterministic start**: the engine has its own HLS segmenter and reports each
  completed segment. The player item is created once, after the first segment
  exists and the server is listening. There is no polling.
- **Time shift (DVR)**: live channels keep a sliding window of 30 minutes by
  default (5 to 120 minutes in Settings, `PlayerPreferences`), with a disk budget of
  512 MB per 30 minutes, or a tenth of the free disk space if that is smaller.
  Segments that leave the window are deleted. You can pause, resume, scrub, skip
  back or forward (10 s / 30 s by default, configurable), and go back to live
  (`AVPlayerViewModel`).
- **Reconnection**: when a live input drops or ends, the engine reconnects with
  backoff (0.5 s to 8 s, 10 attempts). Buffered media keeps playing in the
  meantime, and the playlist continues with `EXT-X-DISCONTINUITY`.
- **Recording**: the record button writes the live stream to
  `Documents/Recordings/<channel>-<date>.ts`, which is a second output of the
  engine. When the recording stops, it is converted to `.mp4` (stream copy) so
  that you can play it and seek in it. Recordings can be listed, played and
  deleted from the player, the Home toolbar or the macOS sidebar. The conversion writes a
  hidden temporary file that is renamed when complete. Recordings interrupted
  by a crash are converted at the next launch.
- **Player screen (iOS)** (`PlayerPresentation`): a layer above the tabs rather than a full-screen
  cover. It grows out of the card or mini player that opened it, follows the finger 1:1 when dragged
  down (the app shows dimmed behind it; dragging up rubber-bands), and closes when released past a
  fifth of the screen or flicked down, or springs back. The timeline scrubber has its own drag, so
  scrubbing never moves the screen. The mini player opens it with a tap or a swipe up.
- **Theme** (`App/Design/Theme.swift`): the colors of the app icon as asset colors (light and dark):
  Fluxo Violet is the accent, Flux Pink marks live TV, Signal Cyan time-shift; content surfaces, the
  timeline gradient and the type scale are defined there too.
- **One player per app**: `FluxoApp` owns the only `AVPlayerViewModel`, because the loopback port, the PiP
  surface and the segment directory can have only one owner. The main UI is a single `Window` on macOS. iPad
  windows (scenes of the same process) share that player, and `WindowCoordinator` shows it in one window at a
  time (see "iPad" below). Startup cleanup (leftover segments, interrupted
  recordings) runs once per process, before the first session starts, and only
  in the instance that holds `tmp/fluxo-instance.lock`, so a second copy of the
  app sharing the same container never deletes files the first one writes.
- **Picture in Picture**: the player draws its own controls, so the video is a bare
  `AVPlayerLayer` driven by an `AVPictureInPictureController` (`PlayerSurface`). Both
  belong to the view model, so PiP keeps running when the player screen closes, and the
  PiP button of the player (or Playback > Picture in Picture, ⌥⌘P) starts it. Stopping
  PiP presents the player again. On iOS PiP also starts automatically when you leave the
  app while a video plays, and when you close the player (the chevron or a swipe down) while
  it plays (two Settings toggles); the X at the top right stops playback. The audio session uses `.playback` /
  `.moviePlayback` and the `audio` background mode. `NowPlayingController` publishes the
  channel to the Lock Screen / Now Playing menu and handles its play, pause, skip and
  next / previous channel commands.

Engine smoke tests (macOS). They build the engine against the bundled `FFmpeg.xcframework` and
serve a generated live stream on 127.0.0.1. Generating and checking the test streams needs the
`ffmpeg` / `ffprobe` programs (any recent build, e.g. `brew install ffmpeg`, used by the tests
only; set `FFMPEG` / `FFPROBE` to use others):

```sh
Tools/EngineSmokeTest/run.sh           # window cleanup, reconnection, recording + MP4 conversion
Tools/EngineSmokeTest/run_avplayer.sh  # AVPlayer pause/resume/skip/go-live on the engine output
```

Debug builds have a test harness for the simulators (`Tools/Simulator/README.md`): an isolated in-memory or
temporary library (`-FluxoDebugStore`), seeded sample content with local artwork (`-FluxoDebugSeed sample|large`),
deep-link routes to any screen (`-FluxoDebugRoute "group:Sport;player:Sky Sport F1"`), forced appearance and
Dynamic Type, loopback test streams, and scripts that clone a simulator, run the app and screenshot every
display:

```sh
Tools/Simulator/build.sh
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --step-shots --route "home;search:Sky;player:Sky Sport F1"
```

Debug builds (`Fluxo/App/Debug/DebugAutoplay.swift`) also accept `-FluxoDebugAutoplayURL <url>`, which plays a stream at
launch, `-FluxoDebugRecordSeconds <n>`, which records it for n seconds, and `-FluxoDebugPictureInPicture YES`, which
starts Picture in Picture once it is possible and stops it 6 seconds later. The shared scheme builds Release, so build
these with `-configuration Debug`.

## Chromecast

Fluxo casts to Chromecast and Google TV / Cast-enabled TVs and speakers on iOS and iPadOS (`Features/Cast`).

- **SDK**: the official [Google Cast iOS Sender SDK](https://developers.google.com/cast/docs/ios_sender) 4.8.6,
  added as Google's Swift package [`googlecast/google-cast-ios-sdk`](https://github.com/googlecast/google-cast-ios-sdk)
  (product `GoogleCastDynamic`, a signed binary xcframework with device and Simulator slices, plus Google's
  `gtm-session-fetcher` package). It is linked on iOS only (a platform filter): Google ships no sender SDK for macOS, so
  the Mac app has no cast UI (`CastController.isSupported` is false there). The SDK does discovery, device
  authentication, the session, session resumption, the Cast terms of service prompt and the media channel; a native
  CASTV2 implementation was not needed. Its analytics logging is turned off.
- **Receiver**: Google's Default Media Receiver (app ID `CC1AD845`), so there is no receiver app to register.
  `Info.plist` lists the Bonjour services `_googlecast._tcp` and `_CC1AD845._googlecast._tcp` and has a Local Network
  usage description. Discovery starts only when the cast button is first tapped (that is when iOS asks for Local
  Network access); afterwards it runs while the app is active (active scans while the device picker is open, Google's
  cheaper passive scans otherwise), and the cast button shows only while a Cast device is on the network or a session
  exists. While it is hidden, the player's ••• menu has "Cast to a Device…", so the picker and its tips (Local
  Network access) stay reachable.
- **Cast button**: on the player's top glass capsule (next to AirPlay) and in the expanded mini player. It opens the
  device picker sheet: the devices, the connected device with its volume (the volume buttons control it too while
  Fluxo is in the foreground) and Stop Casting. Over the player the sheet is dark, like the system's AirPlay picker
  over video; on iPad it is a compact form sheet.
- **What is cast**: the channel's **original stream URL** (`CastMedia`). The Chromecast reads the stream itself; the
  loopback HLS server of the remux engine is never exposed (it stays on 127.0.0.1). HLS, DASH, MP4 / WebM / Matroska
  and audio files are sent with their MIME type, live channels as live streams, movies and episodes as on-demand media
  starting at the position they had here. Raw MPEG-TS channels (no extension or `.ts`) are sent as `video/mp2t`, then,
  for Xtream Codes style URLs, as the HLS variant most IPTV panels also publish (`…/123.ts` → `…/123.m3u8`,
  `/user/pass/123` → `/live/user/pass/123.m3u8`), and, unless the URL ends in `.ts`, as the same URL with the HLS
  type (some providers serve HLS from extensionless or `.php` URLs). If the receiver refuses them all, the player says
  so and the channel keeps playing on the device. Recordings (local files), loopback URLs and `udp` / `rtp` / `rtmp` / `rtsp` /
  `srt` inputs cannot be cast and say why.
- **While casting** (`AVPlayerViewModel`, "Chromecast"): local playback stops (the engine and player item are torn
  down, so the provider sees a single connection, the Chromecast's; a running recording is finished and saved). The
  player shows "Casting to …" with the device volume instead of the video, and its controls drive the receiver: play
  / pause, skip and scrubbing in on-demand media, channel up / down and new channels from Home (they load on the
  Chromecast), stop (the receiver stops, the session stays). The mini player shows "On <device>". Stop Casting, or a
  session that drops, plays the channel on the device again, on-demand media from the receiver's position; "Try Again"
  after a receiver error continues from there too. A session the SDK resumes after a relaunch is adopted, so the mini
  player can control it, and so is media another sender (a phone, Google Home) loads on the same receiver.
- **In the background**: the SDK suspends the session when Fluxo goes to the background (its default) and resumes it
  on return; the Chromecast keeps playing meanwhile. Local playback is stopped while casting, so iOS suspends the app
  and the Lock Screen controls are not expected to reach the TV (not verified on hardware yet): use the TV remote or
  Google Home until Fluxo is back in the foreground. (Keeping the session alive in the background would need a silent
  audio session, which costs battery, so it is not done.)

**Testing with a real Chromecast** (on an iPhone or iPad; Google supports the Simulator for development only, and
guest mode, pairing without the same Wi-Fi, was removed from the SDK in 4.8.1):

1. Put an iPhone or iPad and a Chromecast (or a TV with Chromecast built-in) on the same Wi-Fi network; guest and
   "client isolation" networks block discovery.
2. Build and run the `Fluxo` scheme on the device (Debug or Release), play a channel and tap the cast button in the
   player. Allow Local Network access when iOS asks (Settings › Privacy & Security › Local Network › Fluxo, if it was
   declined).
3. Pick the device: the channel starts on the TV, the phone shows "Casting to …". Check play / pause, the volume
   slider and buttons, channel up / down, a movie (scrubbing, skip, the position carried over), Stop Casting (the
   channel plays on the phone again) and the X (the TV stops, the session stays connected).
4. Try a raw MPEG-TS channel (no extension or `.ts`): it plays if the provider publishes an HLS variant, otherwise the
   player explains that Chromecast can't play it and keeps it on the phone. The app log (`Cast` and `Player`
   categories of `dev.watermelon.Fluxo`) shows each stream the receiver was asked to load.

Without a Chromecast, Debug builds have a simulated receiver (`-FluxoDebugCast simulated`, or the `cast:<device>`
route of `Tools/Simulator`) that shows the whole cast UI and refuses raw MPEG-TS like the real receiver:

```sh
Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --step-shots \
    --route "player:Sky Sport F1;cast:Living Room;wait:3;cast-picker;stop-casting"
```

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

## TV guide (EPG)

The Guide (`Features/Guide`) is a tab on iOS and a sidebar entry on macOS. It shows a time grid of the live
channels that have a guide, programme details, programme search and reminders.

- **Sources** (`EPGSource`): the XMLTV URLs of a playlist header (`#EXTM3U url-tvg="…"`, `x-tvg-url` or
  `tvg-url`, which can list several comma-separated URLs) are stored at import (`Playlist.guideURLString`) and
  become guide sources. For playlists imported before this, the guide reads only the first line of the playlist
  once. You can add XMLTV URLs in Settings › TV Guide, with a shortcut to the free country guides of
  [epgshare01](https://epgshare01.online) (free, updated daily, gzip). Other free guides that work as a URL:
  [open-epg.com](https://www.open-epg.com) (download at most once a day) and i.mjh.nz (Pluto TV, Samsung TV Plus,
  Plex and others). iptv-org/epg is a set of grabber scripts to run on a computer: it has no hosted guides that a
  phone can download. epg.pw did not respond during the research.
- **Download and parsing** (`EPGImporter`): the file is streamed to disk, then read by `XMLTVParser` (SAX
  `XMLParser`) through `InflatingInputStream`, which inflates `.xml.gz` with zlib as it is read. The XML is never
  held in memory. The parser runs on a utility queue and keeps only the programmes from 6 hours ago to 7 days
  ahead, of the channels that can match a live channel of a playlist. Programmes are written in batches of
  2,000 into short-lived background contexts, under a new import ID, and become visible when the whole guide is
  stored (a failed refresh keeps the previous guide, and so does a file cut short when the previous guide had
  more programmes). When the stored guide was read for the same playlist channels, the request is conditional
  (`If-None-Match` / `If-Modified-Since`): a 304 or an identical file (SHA-256) is not read again.
- **Refresh policy**: at launch and every hour for guides older than 12 hours, after a playlist import (new
  guides of its header load, and guides already loaded for it are read again if its channels changed), from Settings / the Guide / File › Refresh TV Guide (⌥⌘R), and from a background app
  refresh task on iOS (`BGTaskSchedulerPermittedIdentifiers` and the `fetch` background mode in Info.plist).
  Programmes that ended more than 6 hours ago are deleted.
- **Matching** (`EPGChannelMatcher`, `ChannelNameNormalizer`): `tvg-id` first (case-insensitive, with or without
  a `@feed` suffix), then the normalized name (case, diacritics, width, provider prefixes such as `IT:` or
  `|UK|`, bracketed notes, HD / FHD / 4K / HEVC / 1080p tags and a trailing country code removed), then the
  tvg-id read as a name and a looser key ("Rai Uno" = "Rai 1"). The guides of the channel's own playlist are
  tried first. Touch and hold (right-click) a live channel and choose Guide Channel… to pick its guide channel
  by hand, or to turn the guide off for it (`EPGChannelOverride`).
- **API** (`EPGStore`, main actor; queries run in `EPGReader` off the main actor and return values):
  `nowNext(for:)`, `programmes(for:in:)`, `upcoming(for:from:limit:)`, `guideChannels(importIDs:)`,
  `searchProgrammes(_:importIDs:)`, and `reminders` (`ReminderCenter`). `revision` changes when guide data or
  matching change. `NowNextReader`, `ChannelProgrammeLine`, `ChannelCardProgrammeOverlay` and
  `PlayerProgrammeInfo` show now / next on channel cards, search rows and the player.
- **Reminders** (`ReminderCenter`): a local notification 5 minutes before the start (0 to 30 minutes in
  Settings); tapping it, or its Watch action, plays the channel. The notification carries only the reminder
  key (stream URLs can embed account credentials); the channel is read from the store. The reminders list is in
  the Guide toolbar.

To check the parser, gzip, matching, the SwiftData import and every guide query on real public guides and on a
synthetic large guide, with timings and peak memory:

```sh
Tools/GuideCheck/run.sh                 # 1,500 channels x 8 days synthetic; OFFLINE=1 skips the downloads
```

Debug builds also accept `-FluxoDebugGuideDemo YES` (an in-memory store with sample playlists and a sample
guide; the real library is not opened), `-FluxoDebugOpenGuide YES`, `-FluxoDebugGuideSearch <term>`,
`-FluxoDebugGuideDetail YES`, `-FluxoDebugGuideSources YES` and, on macOS, `-FluxoDebugSnapshot <name>` (PNGs of
the windows in the app's temporary folder, then quit). See `App/Debug/DebugGuideDemo.swift`.

## Apple Intelligence and Siri

Everything below runs on the device. The language features use the Foundation Models framework
(`SystemLanguageModel.default`) and nothing else: no Private Cloud Compute, no server, no third-party model. Each
feature has a built-in fallback, so the app works fully when Apple Intelligence is off, not supported, still
downloading or does not support the app's language (`FluxoIntelligence.status`, re-read when the app becomes
active). Settings › Apple Intelligence has a switch for the features and explains why they are unavailable.

- **For You** (Home, `Features/Intelligence/Recommendations`): candidates come from the library (channels of
  the groups the viewer watches most, channels named like the most watched ones, favorites past the first ones,
  and for a new library the first groups; never what the Continue Watching and Favorites rows next to it already
  show), a built-in ranking (group affinity, on-air
  programmes, at most three per group, varied reasons) is shown at once, and with Apple Intelligence the model then picks eight and writes a short reason for each
  (`ChannelPicks`, `@Generable` structured output). It may call the `searchChannels` tool (the Search token
  index) to add candidates, at most twice. Picks are numbers checked against the candidates, so nothing can be
  invented. Results are cached per scope and taste fingerprint (most watched channels, favorites, a three-hour
  slot of the day; a SHA-256 digest, the same in every launch): the model runs again only when one of these
  changes, and its picks survive a relaunch.
- **For You Tonight** (Guide; "For You Today" before the evening): programmes on now and in the next six hours on the viewer's channels and groups,
  ranked by channel affinity, timing and recurring categories, then picked and explained by the model
  (`ProgrammePicks`, with a `searchGuide` tool). The strip collapses to one line.
- **Smart search** (Search, `Features/Intelligence/Search`): queries of two or more words with a cue the name
  search cannot use ("football tonight", "italian news channels", "something like Sky Sport F1"), or that find
  nothing, become a `SmartSearchPlan` (keywords with synonyms and translations, kind, country, time window, a
  channel to find similar ones to). The model writes it as structured output; `SmartSearchRules` does the same
  for common words in English, Italian, German, French and Spanish without it, and backs up the model's plan
  (the model's fields are checked against the query). The plan runs through the regular channel, group and
  programme searches, so every result is real; "Smart Results" show the understood query as chips. The viewer's
  own words match as the regular searches do; added synonyms and translations ("serie a", "info", "tg"), and
  words under three letters, must be whole words of a programme's title, subtitle or categories (or of a
  channel or group name), so "football tonight" does not list every description that says "series". A kind
  alone is a search too: "films tomorrow" or "serie tv stasera" list the guide's programmes whose category
  names the kind (`Film`, `Movie / Drama`, `Serie TV`) and the groups and channels named for it ("Cinema",
  "Sky Cinema Uno"); competitions named with a kind word ("Serie A", "Serie B") stay keywords. A country
  filters programmes as it filters channels, and "tonight" after midnight is the rest of the night.
- **Programme summaries** (programme screen): descriptions of 280 characters or more get a one- or two-sentence
  summary, streamed as it is written and kept for the session.
- **Language**: reasons and summaries are written in the app's language; when the small model answers in another
  one (checked with `NLLanguageRecognizer`), they are translated in one more request.
- Typical timings on a Mac with Apple Intelligence: 4–7 s for a recommendation list, 1–2 s for a query plan.
  `-FluxoDebugIntelligence available|off|unavailable|notReady|unsupported` (Debug builds) forces a status to check
  the fallbacks.

**Siri, Shortcuts and Spotlight** (`App/Intents`). `FluxoApp` registers `AppServices` (player, library, guide,
navigation, intelligence) with `AppDependencyManager`; intents run in the app's process and get it with
`@Dependency`, on iOS and macOS.

- Entities: `ChannelEntity` (it stands for playlist + stream URL, so it survives playlist refreshes; the system only
  sees an opaque identifier, `ChannelEntityID`: the playlist UUID and a keyed HMAC of the URL, since stream URLs
  can carry account credentials and identifiers end up in Spotlight, donations and shared shortcuts; string search
  uses the typo-tolerant Search index; suggestions are favorites, then history) is an `IndexedEntity`: favorites
  and recently watched channels (up to 250) are in Spotlight, and opening one plays it. `ProgramEntity` is a guide
  programme (title, episode, start, end, description, categories, channel).
- Intents: Play Channel (`OpenIntent`), Play by Name (the system `PlayVideoIntent`: a channel by name, or the
  channel airing a programme with that title), Pause / Resume, Start / Stop Recording (start can play a channel
  first), Add to Favorites (idempotent) and Toggle Favorite, Search in Fluxo (the system `ShowInAppSearchResultsIntent`), Find Channels, Get
  Suggestions, What's On (now and next of a channel, or what the favorite channels show), Search TV Guide,
  Set Programme Reminder, and Open Screen (Home, TV Guide, Search, Favorites, Recently Watched, Recordings).
  Results come with a dialog and a snippet view. The iOS 27.2 SDK has no assistant schema for video or TV apps
  (its `AppSchema` domains are audio, books, browser, camera, mail, photos, reader and others), so Fluxo uses
  the system video and search intents instead. The player marks the playing channel with
  `appEntityIdentifier(_:)` (on-screen awareness), so Siri and Apple Intelligence can resolve "this channel".
  Set Programme Reminder opens the app the first time, so the system can ask for notification permission.
- App Shortcuts (`FluxoShortcuts`, ten shortcuts): "Play Sky Sport F1 in Fluxo", "What's on in Fluxo",
  "What's on Rai 1 in Fluxo", "What should I watch on Fluxo", "Search the Fluxo guide", "Search Fluxo",
  "Open TV Guide in Fluxo", "Set a reminder in Fluxo", "Favorite this channel in Fluxo", "Start recording in
  Fluxo", "Stop recording in Fluxo". Siri's own "Pause" and "Resume" reach Fluxo through Now Playing.

To try them: run the app once (App Shortcuts register when it is installed), then open the Shortcuts app on the
device, the Simulator or the Mac: Fluxo's shortcuts are listed under the app, and every action can be added to a
new shortcut and run from there. Say or type (Type to Siri) the phrases on a device or Mac with Siri on. Spotlight
lists favorite and recent channels a few seconds after launch.

## User interface

- **Player screen** (`Features/Watch/WatchChannelView.swift`): the video fills the screen
  (iOS full-screen cover; on macOS it covers the main window, whose toolbar is hidden
  meanwhile). The top bar shows close, the channel logo and name, the status (connecting,
  buffering, reconnecting, `LIVE`, time-shifted `-m:ss`, paused, ended, error) and the
  recording indicator, plus PiP, AirPlay, full screen (macOS) and a menu (fill / fit,
  recordings, stop). The bottom bar has a scrubber (on-demand position, or the time-shift
  window of a live channel), channel down / up, skip back / forward, play / pause, Record
  and Go Live (see "Liquid Glass" below for how these controls morph). Controls fade out after 4 s of playback without interaction and come back on
  a tap or mouse move; they stay up while paused, buffering, failed, scrubbing or with
  VoiceOver on. Errors and the end of a stream show a card with Try Again / Play Again.
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
- **Settings** (a tab on iOS, the Settings window ⌘, on macOS): time-shift length, skip
  intervals, automatic PiP (iOS), TV guide sources and the reminder time, recordings count / size / location (Show in Finder on macOS,
  the Files app on iOS through `UIFileSharingEnabled`), delete all recordings, temporary stream
  files, logo cache, watch history, and the app and FFmpeg versions.
- **Recordings**: play, share, Show in Finder (macOS), delete, delete all.
- **Menu bar** (macOS, and the iPad menu bar): File > New Window (⌥⌘N, iPad), Add Playlist… (⌘N), Refresh All
  Playlists (⌘R), Refresh TV Guide (⌥⌘R); Go > Home (⌘1), TV Guide (⌘2), Favorites (⌘3), Recently Watched (⌘4),
  Recordings (⌘5), Settings (⌘6, iPad), Search (⌘F); Playback > Play/Pause (Space), Skip Back / Forward (⌘← / ⌘→),
  Go Live (⌘L), Channel Up / Down (⌘↑ / ⌘↓), Record (⇧⌘R), Picture in Picture (⌥⌘P), Fill Video, Show
  Player (⇧⌘P), Stop Playback (⌘.). Commands act on the focused window. Shortcuts that would clash with text
  editing (Space, the arrows) are only enabled while the player is on screen. Escape closes the player; in a wide
  player ⇧⌘L shows or hides the channel list.
- **Haptics** (iOS): channel changes, recording start / stop, favorites, and the result of a
  playlist import.

## iPad

- **Sidebar** (`App/AppTabView.swift`): a `.sidebarAdaptable` tab view. The sidebar lists Home, Guide, Favorites,
  Recently Watched, Recordings, Settings, Search and a Playlists section (the Home of each playlist, with its
  refresh / edit / delete menu, and Add Playlist). It shows by default when the window is wide (landscape, at least
  1,100 points, so the iPad mini too), decided in the first layout of the window (a `GeometryReader`: the tab view
  reads its default placement only once); narrower windows start with the floating tab bar and its sidebar
  button. Edit in the sidebar pins entries to the tab bar (tab customization, kept in `UserDefaults.fluxo`).
  Narrow windows (Slide Over, a third of Split View) are compact and look like the iPhone. The iPad-only tabs are
  not declared on iPhone, whose tab bar is unchanged.
- **Inspectors**: in a regular width window, programme details open in an inspector next to the Guide grid. In a
  wide window (the sidebar rule above) a channel's schedule (its Guide swipe or menu action) opens in an inspector
  next to Home, Favorites, Recently Watched, Search and the playlists, which stay usable: another channel replaces
  it. In portrait and narrower windows, where an inspector would cover the content, it is a centered form sheet;
  in compact widths a sheet, as on iPhone.
- **Player side panel** (`Features/Watch/PlayerSidePanel.swift`): in a wide player (iPad in landscape, at least
  900 points), the top bar has a button for a glass panel next to the video: the channels of the playing channel's
  category with what each shows now (tap to switch, the playing one highlighted and scrolled to), or the playing
  channel's guide by day with reminders. The video shrinks to make room. The panel and its tab are remembered;
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
  onto Favorites in the sidebar or the tab bar (spring-loaded), the Favorites row of Home or the Favorites screen,
  which adds them to the favorites; the Mac sidebar's Favorites accepts them too. A web link dropped on a window opens Add Playlist with it; an M3U / M3U8 file dropped on a
  window (or opened in Fluxo from Files, `CFBundleDocumentTypes`) is copied to `Application Support/Playlists` and
  imported from that copy (`LocalPlaylistFiles`, which resolves the copy in the current container on every
  refresh and deletes it with the playlist). The Edit Playlist form accepts that file address only for the
  playlist that owns it; typed addresses must be http or https.
- **Pointer and keyboard**: cards lift and list rows highlight under the pointer; the menu bar commands above have
  keyboard shortcuts and show in the shortcut overlay (hold ⌘).

## Liquid Glass (iOS 26)

Glass is used for the navigation and control layer only (tab bar, toolbars, the mini player,
the playlist chips, the player controls, sheets). Cards, rows and banners are content and use
plain surfaces or small materials.

- **Tab bar**: a native `TabView` with Home, Guide, Favorites, Settings and a `.search` role tab. It
  minimizes while scrolling down (`tabBarMinimizeBehavior(.onScrollDown)`).
- **Mini player** (`PlayerBottomAccessory` in `App/ContentView.swift`): the
  `tabViewBottomAccessory`, shown only while something plays (on iOS 26.1+ through
  `isEnabled:`; iOS 26.0 cannot hide it and shows "Not Playing"). It reads
  `tabViewBottomAccessoryPlacement`: expanded, it shows the artwork, the title, a status line
  (LIVE and group, recording with a pulsing symbol, PiP, buffering), play / pause and close;
  inline (next to the minimized tab bar), only the artwork, the title and play / pause.
- **Zoom transitions** (`App/Design/ZoomTransitions.swift`): the full-screen player zooms out of
  the card, billboard artwork, search result or mini player that opened it
  (`matchedTransitionSource` + `navigationTransition(.zoom)`); `PlayChannelAction` passes the
  source to `AVPlayerViewModel.presentationSourceID`, and paths without a card (PiP restore,
  recordings, Show Player) zoom from the mini player. A category zooms out of its
  Home row or its category card (Home, search, the category browser), and the Recordings sheet out of its
  toolbar button.
- **Home**: the featured billboard runs under the status bar and the floating toolbar, its
  blurred artwork uses `backgroundExtensionEffect()` (it also extends under the iPad sidebar and
  the landscape safe areas), stretches on overscroll and fades into the background so both light
  and dark mode stay legible. The inline title fades in once the billboard has scrolled away;
  the scroll edge effect is `.soft`. Recordings and the playlist menu are separate toolbar glass
  groups (`ToolbarSpacer(.fixed)`). The playlist chips share a `GlassEffectContainer` and the
  tinted selection glass keeps its `glassEffectID`, so it morphs from chip to chip.
- **Player controls**: floating glass clusters in one `GlassEffectContainer`. Channel and skip
  buttons merge into a capsule on each side (`glassEffectUnion`), play / pause is a larger
  circle tinted with the accent color while paused, Record stretches into a red-tinted
  `REC m:ss` timer with a pulsing dot, and a red LIVE indicator morphs into `-m:ss Go Live`
  when the stream is time-shifted (`glassEffectID`). PiP, AirPlay and the menu share one capsule.
- **Sheets**: Add / Edit Playlist and Recordings use `.medium` / `.large` detents; their forms
  hide the grouped background so the sheet's glass shows at partial height, and they use the
  iOS 26 `.cancel` / `.close` / `.confirm` button roles.
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

## Accessibility

The building blocks are in `Fluxo/App/Accessibility` (`AccessibilitySupport.swift`: stacked layouts, card
scaling, the Large Content Viewer, Smart Invert, Button Shapes, announcements; `ChannelAccessibility.swift`:
what every channel card and row says and offers), the player's in `Features/Player/PlayerAnnouncements.swift`
and `Features/Player/MediaSelection.swift`, and the colors in `App/Design/Theme.swift`.

- **VoiceOver**: every card and row is one element that says the number, name, kind, favorite state, the
  programme on air (from the guide) or the time left of a movie, and plays when activated. Its custom actions
  (Actions rotor) add or remove the favorite, open the channel's schedule, play and record (live channels the
  remux engine records) and play from the beginning. Section titles are headings; long lists have a
  Favorites rotor, the guide grid a Channels rotor (each row is a container named after its channel, its
  programmes say their time, "On now, 20 min left" or "Ended", with Watch and Remind Me actions). The player
  is modal (VoiceOver stays in it), focuses the channel name when it opens, answers Magic Tap (play / pause)
  and the escape gesture (close); its scrubber is adjustable and says the position, or the time behind live.
  The mini player is a "Mini Player" container whose title opens the player. VoiceOver hears what the player
  does on its own, wherever the user is: the channel that starts ("Sky Sport F1, live"), buffering or
  connecting that lasts more than 2 s, reconnecting, failures (high priority), the end, recording started /
  stopped / failed, back to live and Cast. Search says how many results a query found.
- **Dynamic Type** up to AX5: rows, headers (See All moves under the title), the billboard, Settings and the
  On Now cards stack at the accessibility sizes; cards of the horizontal rows grow (`CardScale`) and their
  titles get more lines; segmented pickers become menus; the guide switches to a list of channels with now /
  next (Automatic layout; Grid and List can be chosen in its menu). Controls that keep their size (the
  player's buttons, the mini player) show in the Large Content Viewer; the player's text grows up to AX2.
- **Contrast** (WCAG 2.2 AA, measured in `Theme.swift`): text and thin glyph colors pass 4.5:1 on the
  backgrounds of their mode, icons 3:1; white text sits on fill colors that pass in both modes
  (`accentFill`, `liveFill`, `cyanFill`, `favoriteFill`). Secondary and tertiary text use `Theme.secondaryText`
  and `Theme.tertiaryText` (about 5.6:1 and 4.6:1 on white) instead of the system's `.secondary` and
  `.tertiary` (3.4:1 and 1.9:1).
  Every color asset has an Increase Contrast variant; hairlines, the timeline track, labels and scrims over
  video get stronger with it, and the LIVE badge gets a border.
- **Reduce Motion** (no zooms, pulses or autoplaying animations), **Reduce Transparency** (opaque scrims and
  backdrops; Liquid Glass adapts by itself), **Differentiate Without Color** (a checkmark on the selected
  chip, a live symbol and a thicker border on the guide's programme on air), **Button Shapes** (`See All`,
  `TV Guide` get a shape), **Smart Invert** (artwork, logos and video keep their colors).
- **Subtitles, captions and audio tracks**: the player's Audio and Subtitles button (and Playback > Audio and
  Subtitles) lists what the item has: HLS renditions, MP4 tracks, CEA-608 captions. Audio descriptions are
  marked AD, SDH subtitles and closed captions too. Automatic follows the system (Subtitles & Captioning,
  Audio Descriptions, languages), and the AVPlayerLayer draws captions in the system caption style.
- **Voice Control** names for icon buttons ("Close", "Stop", "Subtitles") and channels (the name without its
  provider prefix and quality tags: "Tap Sky Sport F1"). **Keyboard**: Go menu (⌘1 Home, ⌘2 TV Guide,
  ⌘3 Favorites, ⌘4 Recently Watched, ⌘5 Recordings, ⌘6 Settings on iPad, ⌘F Search), the Playback menu (space, ⌘← / ⌘→, ⌘↑ / ⌘↓,
  ⌘L, ⇧⌘R, ⌘.), Escape closes the player; the player's controls never hide while an assistive technology
  (VoiceOver, Switch Control, Voice Control, Full Keyboard Access) is on.

### Audit

`Tools/Simulator/accessibility-audit.sh` runs the Xcode accessibility audit (`performAccessibilityAudit`) on
15 screens in three variants of a simulator (default, AX5, dark with Increase Contrast) and writes one report
per variant (see `Tools/Simulator/README.md`); `testMediaSelectionMenu` checks the Audio and Subtitles menu
with the test streams. Manual checks before a release, on a device:

1. VoiceOver: Home to a channel and back, the Actions rotor of a card (Favorite, Schedule, Play and Record),
   the Channels rotor of the guide, the player (focus on open, Magic Tap, scrubber, escape), the mini
   player, the announcements when a channel buffers, fails and records.
2. Settings > Accessibility > Display & Text Size > Larger Text at the largest size: every tab, a category,
   the player; nothing is clipped, long press the player's buttons for the Large Content Viewer.
3. Increase Contrast, Reduce Transparency, Differentiate Without Color, Button Shapes, Smart Invert and
   Reduce Motion, one at a time, on Home, the guide and the player.
4. Subtitles & Captioning > Closed Captions + SDH, and a caption style: a stream with captions shows them
   in that style; Audio Descriptions picks the AD track.
5. Voice Control ("Show names", "Tap Sky Sport F1", "Tap Stop") and Full Keyboard Access (Tab through Home,
   ⌘1–⌘6 and ⌘F, space in the player); on the Mac, keyboard navigation of the sidebar and VoiceOver.
6. Right-to-left (`-NSForceRightToLeftWritingDirection YES`): rows, cards and the player mirror (the
   layouts use leading / trailing only).

## Localization

English is the development language. The project lists Spanish, French, German, Italian, Portuguese
(Brazil), Dutch, Polish, Russian, Turkish, Arabic, Hindi, Indonesian, Japanese, Korean and Chinese
(Simplified, Traditional) in its known regions. All text is in three String Catalogs in `Fluxo/`:

- `Localizable.xcstrings`: the interface on iOS and macOS, menu commands, VoiceOver text, errors, the
  notifications of reminders, and the App Intents strings (action names and descriptions, parameters,
  dialogs, entity and enum names, Siri synonyms of the screens).
- `AppShortcuts.xcstrings`: the Siri phrases of the App Shortcuts (`FluxoShortcuts.swift`). Every phrase
  keeps `${applicationName}`.
- `InfoPlist.xcstrings`: the Local Network permission prompt, and the names of the M3U Playlist document
  type and of the Fluxo Channel file type (the two last are manual entries: Xcode does not extract them).

Rules the code follows:

- SwiftUI literals (`Text`, `Button`, `Label`, `.navigationTitle`, `.accessibilityLabel`, …) are localized
  keys. Text built outside a view uses `String(localized:comment:)`, App Intents use
  `LocalizedStringResource`. A view that stores a title as `String` (`PlayerBadge`, `HomeSectionHeader`,
  `largeContentControl`, …) gets a `String(localized:)`, because a literal given to a `String` parameter is
  not extracted. Text that is not for people (identifiers, URLs, the prompts of the on-device model,
  debug-only text, previews) uses `Text(verbatim:)` or a plain `String`.
- Counts are interpolated as integers (`"\(count) channels"`), not as `count.formatted()`: the catalog then
  has plural variations for them, and the number still gets the grouping of the locale. Channel numbers use
  `.number.grouping(.never)`.
- Dates, times, durations, sizes and time codes use format styles (`.dateTime`, `.interval`,
  `Duration.formatted`, `.byteCount`), never fixed formats or `String(format:)`.
- Whole sentences are keys; a sentence is never assembled from translated pieces. The parts of a subtitle
  line (a kind, a group, a playlist name) are joined with `TextParts.line`, which puts each part in a bidi
  isolate and uses the separator of the language (in Arabic it carries a letter mark, so the line reads
  right to left); VoiceOver labels use `TextParts.spoken` / `TextParts.sentences` (、 and 。 in Japanese and
  Chinese).
- Nothing localized is stored: the guide keeps "S1 E5" and empty titles (`GuideFormat.episode`, "Untitled"
  when shown), a failed guide refresh keeps a `GuideRefreshFailure` code, a recording without a channel
  name keeps no title ("Recording from <date>" when shown), and the recordings folder is always
  `Recordings`. Pending reminder notifications are rewritten when the language or the time format changes.
- The messages of the C remux engine are English; `EngineMessage.localized` (`StreamRemuxer.swift`)
  translates the part that says what failed and keeps FFmpeg's technical reason.
- The suggestions of Apple Intelligence are written in the language of the interface
  (`OnDeviceModel.responseLanguage`, from `Bundle.main.preferredLocalizations`, with its script or region:
  "Chinese (Traditional)", "Portuguese (Brazil)").

Xcode updates the catalogs when it builds. From the command line, `xcrun xcstringstool sync` does the same
with the `.stringsdata` files of a build (in `Objects-normal/<arch>` of the derived data); use those of an
iOS and a macOS build, as some strings exist on one platform only. Every string has a comment that says
where it is shown and what its placeholders are; add one (`comment:`) to new strings whose meaning is not
obvious from the English alone.

## Memory

- **Logos and posters** (`Fluxo/App/Images`): every image goes through the shared
  `LogoImageLoader`, shown by the `LogoImage` view. Images are decoded off the main
  thread with ImageIO directly at the displayed size
  (`CGImageSourceCreateThumbnailAtIndex`), never at the source resolution. Decoded
  bitmaps live in a cost-bounded `NSCache` (about 1.5% of RAM, 24 to 96 MB), which is
  emptied on iOS memory warnings and when the app goes to the background. Downloaded
  bytes are kept in an on-disk `URLCache` (`Caches/LogoImages`, 200 MB), which you can
  clear in Settings. Requests for the same image share one load, and a load is cancelled
  when the last view waiting for it disappears. Inline `data:image` logos are decoded
  once and then served from memory.
- **SwiftData**: the Watch list fetches groups 25 at a time and loads the next page when
  the last section appears. Each group strip fetches 50 channels, and "Show all" pages its
  grid 60 channels at a time. The player only keeps `PlayableChannel` values, never
  models. Imports use short-lived background contexts, one for each batch.
- **Player**: AVPlayer buffers at most 8 s ahead for local (remuxed) streams and 30 s for
  remote items. Stopping playback releases the player item and the engine session. The
  time-shift window is limited to 30 min / 512 MB, and never more than a tenth of the
  free disk space (with a 64 MB minimum). Remuxed on-demand items (local `.ts` files,
  such as recordings that could not be converted to MP4) are kept whole, so every
  position stays seekable; they are only played when the copy (about the size of the
  file) fits in the free space with a 256 MB margin.
- **Observation**: the player, the timeline, the recordings, the import center and
  Settings use `@Observable`. A view re-renders only for the properties it reads, so,
  for example, playback state changes no longer re-render the playlist browser.

Measurement tools (macOS):

```sh
Tools/ImageLoaderBenchmark/run.sh   # former logo path vs LogoImageLoader, on 127.0.0.1
Tools/EngineSmokeTest/leaks.sh      # engine sessions under `leaks --atExit`; FOOTPRINT_ONLY=1 prints the footprint per cycle
```
