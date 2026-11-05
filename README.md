# Fluxo

Fluxo is a SwiftUI IPTV / M3U player for iOS, macOS and tvOS (see "Apple TV").

## Building

Open `Fluxo.xcodeproj` in Xcode 26 or later and run the `Fluxo` scheme.
The app needs iOS 26.1 / macOS 26 (iOS 26.1 is the first release that can hide the tab bar accessory, so
the mini player shows only while something plays).

Live streams go through a small C remux engine
(`Fluxo/Features/Player/Engine`) built on FFmpeg's libavformat, libavcodec
and libavutil. The engine copies the stream into HLS segments on disk (converting the audio and video
AVPlayer cannot decode, see "Formats"), and a local HTTP server bound to `127.0.0.1` gives them to AVPlayer.

There is nothing to install: FFmpeg ships with the repository (see "FFmpeg" below), and the
Swift packages, [FlyingFox](https://github.com/swhitty/FlyingFox) (the loopback HTTP server) and
Google's [Cast SDK](https://github.com/googlecast/google-cast-ios-sdk) (iOS only, see "Chromecast"
below), are resolved by Xcode on its own. The app builds for iOS devices, the iOS Simulator, macOS, Apple TV
and the tvOS Simulator, from the one `Fluxo` target and scheme.

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

# Apple TV (unsigned) and the tvOS Simulator
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -destination 'generic/platform=tvOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -configuration Debug -destination 'generic/platform=tvOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

The SwiftData schema is the list in `Fluxo/App/Database/ModelRegistry.swift`; add new `@Model`
types there. `.swiftlint.yml` configures [SwiftLint](https://github.com/realm/SwiftLint) for
manual runs (`swiftlint lint`); it is not part of the build.

### FFmpeg

`Vendor/FFmpeg/FFmpeg.xcframework` is a minimal FFmpeg 9.0.2 built from the official release
tarball by `Tools/FFmpeg/build-xcframework.sh` (pinned version and SHA-256, plus the release
signature when `gpg` is installed). It contains one dynamic framework, `FFmpeg.framework`,
with libavformat, libavcodec, libswscale, libswresample and libavutil linked into a single library that exports
only the public API (`av_*`, `avio_*`, `avcodec_*`, `avformat_*`, `avutil_*`, `avsubtitle_*`, `swr_*`, `sws_*`; no
internal `avpriv_*` / `ff_*` symbols), for iOS (arm64), the iOS Simulator (arm64, x86_64), macOS
(arm64, x86_64: macOS 26 still runs on Intel Macs, and Xcode builds universal Release apps), tvOS (arm64) and the
tvOS Simulator (arm64, x86_64), with the same components and configure flags on every platform.
The public headers are in `Vendor/FFmpeg/include`, and `Vendor/FFmpeg/BUILD_INFO.txt` lists the
exact configuration. The iOS slice is about 8 MB.

- **What is in it**: everything is disabled except what the engine reaches:
  - demuxers: MPEG-TS (and M2TS), HLS, MP4 / MOV / 3GP, FLV, Matroska / WebM, AVI, ASF (WMV), Ogg, MPEG-PS (VOB),
    WAV, RTSP/RTP and elementary audio/video, and WebVTT (the HLS demuxer probes the subtitle renditions of a master
    playlist and fails without it);
  - the MPEG-TS and MP4 muxers; the file, HTTP(S), TCP, TLS, UDP, RTP, RTMP(S/T) and AES (`crypto`) protocols;
  - parsers and the bitstream filters the muxers insert (`aac_adtstoasc`, `h264_mp4toannexb`, `hevc_mp4toannexb`,
    `extract_extradata`);
  - decoders: the ones `avformat_find_stream_info` uses to read stream parameters (H.264, HEVC, AAC, AC-3, E-AC-3,
    MP3, and the MP2 audio and MPEG-2 video of DVB-derived channels; without a decoder a live input waits out the
    whole 3 s probe), and the ones the converter decodes (see "Formats" below): MPEG-1 / MPEG-2, MPEG-4 Part 2 and
    Microsoft's MPEG-4 variants, H.263 / Sorenson Spark, VC-1 / WMV 7-9, VP8, VP9, Theora, Motion JPEG; DTS, Dolby
    TrueHD / MLP, FLAC, ALAC, Opus, Vorbis, MP1 / MP2, WMA 1 / 2 / Pro, AMR-NB / WB, Nellymoser, IMA / MS ADPCM and
    the PCM variants of WAV, AVI, MOV, Blu-ray and DVD;
  - encoders: FFmpeg's own AAC encoder, and `h264_videotoolbox` (the system's hardware H.264 encoder through
    VideoToolbox); the VideoToolbox VP9 decoder (`vp9_videotoolbox`) for devices that have one; libswscale and
    libswresample for the pixel and sample conversions.
  No filters, devices or programs. `srt://` needs libsrt (and a crypto library), which is not included: such channels
  fail at once with "Unsupported stream type".
- **HTTPS** uses Secure Transport, the TLS backend FFmpeg has for Apple platforms without an
  extra library, with the system trust store and certificate verification on (TLS 1.2). The only
  external libraries are the system's (Secure Transport, zlib, VideoToolbox, CoreMedia, CoreVideo), so nothing is
  taken from Homebrew.
- **License**: the build enables no GPL, version 3 or non-free component (no libx264, libfdk-aac or other external
  codec library: the AAC encoder is FFmpeg's own, H.264 is encoded by the operating system), so it is LGPL v2.1 or
  later. It is linked dynamically and embedded as `Fluxo.app/Frameworks/FFmpeg.framework`
  (`Contents/Frameworks` on macOS), so it can be replaced with another build of the same
  library; the license text is in `Vendor/FFmpeg/LICENSE` and inside the framework. Anyone
  distributing the app must also offer the FFmpeg source (the release tarball) and this build
  script.
- **Rebuild** (about 10 minutes; Xcode only, no Homebrew packages): `Tools/FFmpeg/build-xcframework.sh`.
  `SLICES` builds a subset, e.g. `SLICES="tvos-arm64 tvossim-arm64 tvossim-x86_64"` (a platform is always built
  with all its architectures): the platforms left out are copied unchanged from the current xcframework, so their
  binaries stay byte for byte the same (`BUILD_INFO.txt` lists them). The tvOS slices were added that way.
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
  names (episode markers, see "Series"; "Series" groups). Each group gets the most common kind of its
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
- **Library** (`Features/Library/LibraryView.swift`, iOS): the tab with what the user keeps. A first section links
  to Favorites (with their count) and Recently Watched (with the last thing watched), then the offline downloads
  (see "Offline downloads"), then the recordings are listed in place (play, share, delete; Delete All in the More
  menu). Library replaced the Favorites tab: Favorites already lead Home (a row with See All), so a tab repeated Home,
  while the recordings were only reachable from a Home toolbar button or the player's menu.
- **macOS** uses a sidebar (Home, TV Guide, Search, a Library section with Favorites, Recently Watched, Downloads
  and Recordings, and each playlist) and a Settings window (Cmd-,). iPhone uses tabs; iPad uses a sidebar-adaptable
  tab view (see "iPad" below).

## Offline downloads

Movies and episodes (never live channels) download to watch without a network (`Features/Downloads`).

- **Where**: Download in every movie and episode menu (cards, rows, the series page), a download button on each
  episode of a series page, and Download Season above its episodes (a tap downloads the episodes not downloaded yet;
  its menu pauses or deletes the season). Cards and rows show a downloaded arrow, or a progress ring while it
  downloads; series cards how many episodes are downloaded.
- **How** (`DownloadProbe`, `DownloadTransport`): the first 4 KB of the link are read (a ranged request) and the
  content is recognized by its signature, then its type and extension, since IPTV links are often extensionless:
  - HLS goes through `AVAssetDownloadURLSession` with an `AVAssetDownloadConfiguration`: the variant of the Video
    Quality setting (Best, up to 1080p, 720p or 480p; the size is estimated from its bit rate and the duration), the
    audio renditions in the user's languages and every subtitle, so Audio and Subtitles still switch offline (the
    player's menu lists only what was downloaded, `AVAssetCache`). The `.movpkg` stays where AVFoundation puts it,
    stored relative to the home folder (the container moves with updates), with the `important` storage priority.
  - MP4 / MOV / M4V / MP3 / AAC download as they are in a background `URLSession`.
  - What AVPlayer cannot play (Matroska / WebM, AVI, WMV, Ogg, MPEG-TS, FLV, MPEG-PS) downloads the same way, then the
    remux engine copies it into an MP4 (`fluxo_remux_convert_file`; video and audio, not the subtitles), converting the
    streams AVPlayer does not decode (DTS audio, Xvid video, ...: see "Formats"), so it plays and seeks like any file.
    A file whose video the engine can neither copy nor convert (AV1 without an AV1 decoder) fails at the conversion with
    "This video format can't be played on this device"; links that return a web page are refused.
- **Queue**: two transfers at a time, the others wait in order; pause (file transfers keep resume data and continue
  where they stopped, HLS tasks are suspended), resume, cancel, retry, delete; Pause All / Resume All. Network failures
  are retried three times from where they stopped, and again when the network returns; a refused or vanished link
  (401, 403, 404, 410: expired tokens or credentials) is looked up again in the current copy of the playlist before it
  fails. The free space is checked first (the size, twice it for a file that is converted, plus 500 MB).
- **In the background**: the transfers run in background sessions, so they continue while the app is suspended or
  terminated; iOS relaunches the app to deliver their results (`backgroundTask(.urlSession(matching:))`) and the
  transfers that survived a relaunch are adopted at launch. An interrupted conversion starts again at the next launch.
- **Settings › Downloads**: Use Cellular Data (off by default; each kind of transfer has a session that may and one
  that may not use cellular data, and running transfers move when it changes), Video Quality, Delete Watched Downloads
  (a download played to the end is deleted once something else plays), Download Next Episode (finishing a downloaded
  episode downloads the next one), the space used and Delete All Downloads.
- **Offline playback**: a download is keyed like a bookmark (playlist + stream URL), so a downloaded movie or episode
  plays from its file wherever it is started (a card, Continue Watching, the series page, Siri), with its resume
  position, watched state and series progress; Chromecast still gets the stream URL.
- **Library**: Downloading (progress, size, time left, "Waiting for Wi-Fi" or "Waiting for a network connection"),
  then the downloads: movies one per row, a series as one row with its episodes behind it (by season), the first five
  with See All. Each keeps its artwork (shown offline), size, duration, quality and languages. The Mac sidebar has a
  Downloads entry. A download whose media the system removed (storage pressure) says so and offers Download Again.
- **Offline**: `NetworkMonitor` (`NWPathMonitor`) knows when the device has no network at all. Home then says "You're
  Offline" with the downloads first, the player says at once that something that is not downloaded needs a connection
  (and starts it when the network returns) instead of spinning until a timeout, and the TV guide refreshes wait for the
  network. Everything else (playlists, guide, artwork in the logo cache) comes from the device.
- **Storage**: files in `Application Support/Downloads/<id>/` (excluded from device backups: they can be downloaded
  again), the manifest in `Downloads/downloads.json` (not SwiftData: it describes files and must survive a reset of
  the library store). Downloads are deleted with their playlist.
- **Simulator**: background HLS downloads need a signed app (an unsigned build fails with "does not have write access
  to destination directory"); `Tools/Simulator/build.sh` builds unsigned, so build the simulator app with
  `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual` to try them. See the download routes in `Tools/Simulator/README.md`.

## Series

On-demand entries named like episodes are grouped into series, so a series shows once everywhere (Home's billboard,
rows, category cards and grids, Search, For You, Because You Watched, Continue Watching) and opens its own page.

- **Parsing** (`Features/Series/EpisodeParser.swift`): a scan over the scalars of the name, with a lowercase,
  accent-free copy, about 2 µs per name. Strong markers (a season and an episode) are `S01E02`, `S01 E02`, `s1e2`,
  `S01.E02`, `S01xE02`, `S01 Ep. 02`, `T01E02`, `1x02`, `Season 1 Episode 2`, `Series 2 Episode 3` and the
  localized words (Stagione / Episodio, Staffel / Folge, Temporada / Episodio / Capítulo, Saison / Épisode, Seizoen
  / Aflevering, Sezon / Odcinek / Bölüm, Säsong / Avsnitt, сезон / серия, also as "2. Staffel" or "1 сезон 2
  серия"); double episodes (`S01E01E02`) count as the first. Weak markers (an episode number only: `Episode 12`,
  `Ep. 3`, `E05`, `Folge 5`, `Puntata 6000`) count only for entries that are series by their URL (`/series/`) or
  category, never to turn a movie into a series. The text before the marker becomes the series title, without
  provider prefixes (`IT:`, `|EN|`, `[4K]`, `4K-IT:`; `CSI: Miami` keeps its title), file tags (FHD, 4K, HEVC,
  `[MULTI]`, `SUB ITA`, …) and a year in parentheses, which goes into the key (`Doctor Who (1963)` and
  `Doctor Who (2005)` stay apart); scene names (`Breaking.Bad.S01E01.720p`) read dots as spaces; the text after it
  becomes the episode title. A name with nothing before the marker takes the series title from its category
  (`Series | Breaking Bad`), unless the category only says "Series". Anything else stays a single entry.
- **Model**: each episode keeps its series key and, packed into one attribute (`StoredEpisode`: each attribute of
  a model costs about 0.25 s per 100k inserts), its series title, season, number and title on its `PlaylistChannel`, and
  `isListed` is false for every episode but the first of its series in its category (that "head" stands for the
  series in the category's rows and grids; every listing query filters on it, so paging, orders, the A–Z index and
  counts are unchanged). `PlaylistSeries` sums up a series of an import (title, year, artwork of the first episode
  with a poster, category, first and last position, episode and season counts); groups know their `listedCount`
  and `seriesCount` ("3 series · 30 episodes"). `SeriesBookmark` (playlist + series key, so it survives refreshes,
  deleted with its playlist) keeps the favorite, the episode watched last and the episodes watched. The resume
  position of each episode stays on its `ChannelBookmark`, as for movies.
- **Existing libraries**: imports stored before series existed (or by an older `EpisodeParser.version`) are grouped
  at launch on a background context (`SeriesIndexer`, about 1 to 4 s for 100k entries); their favorites and history
  are linked to their series and episodes watched to the end count as watched. The store migrates by itself (new
  attributes have defaults).
- **Series page** (`SeriesDetailView`): the poster on a blurred backdrop, the title, year and counts, Continue (resume
  the episode watched last, else play the next unwatched one, else Watch Again), favorite, Mark Series as Watched /
  Unwatched, the seasons as chips (Specials last, a checkmark on watched seasons), and the episodes with their
  number, title, watched state, progress and time left; Up Next is highlighted. An episode's menu has Resume / Play
  from Beginning, Mark as Watched / Unwatched, Mark Watched Up to Here and its own favorite.
- **Tracking**: playing an episode makes it the series' last episode; playing it to the end (the last 3 %) marks it
  watched. Continue Watching shows a series once: the episode that stopped part-way, or "Up Next" with the next
  episode. In the player, an episode longer than 5 minutes shows Next Episode during its credits, and its end
  shows the next episode with an 8 s countdown (Cancel, Play Again; no countdown with VoiceOver or Switch Control).
  On iPad and the iPhone Duo the player's channel list shows the series' episodes while an episode plays.
- **Search** lists a series once, with its counts, when its title or one of its episodes ("Ozymandias") matches; its
  episodes are on its page. Recommendations (For You, smart search, Because You Watched) suggest series as a whole.
- **For App Intents** (`SeriesLookup`, off the main actor, values only): `series(matching:importIDs:limit:in:)`,
  `episodes(of:in:)`, `episodeToPlay(for:in:)` (where the viewer left off) and `nextEpisode(after:in:)`.

To check the parser on 100+ real-world names, an import of 100k entries with series, the series queries (timings)
and the migration and backfill of a store written by the previous version:

```sh
Tools/SeriesCheck/run.sh              # ENTRIES=20000 for a quicker run, PARSER_ONLY=1 for the parser only
```

To check every Home and Search query against an on-disk store (100k channels), including the token
search (matches, ranking, typos) and its timings:

```sh
CHANNELS=100000 Tools/HomeQueriesCheck/run.sh
```

## Player

- **Routing** (`PlaybackRoute`, from the URL and the kind of the entry): HLS playlists and MP4/MOV
  files play directly in AVPlayer. Raw MPEG-TS channels (no extension or `.ts`, or `udp://`, `rtp://`,
  `rtmp://`, `rtsp://`) go through the remux engine, which writes local HLS that
  AVPlayer reads from the loopback server (`127.0.0.1:19123` only).
  Live channels with `.m3u8` URLs play directly in AVPlayer, so they use the
  DVR window of the source playlist (if it has one) and cannot be recorded.
  Movies and episodes AVPlayer cannot open go through the engine's on-demand mode: Matroska, WebM, AVI,
  WMV / ASF, Ogg, FLV, MPEG-PS / VOB, MPEG-TS / M2TS files (Xtream Codes `…/movie/user/pass/123.ts`),
  extensionless and `.php` URLs (see "Formats" below). A movie that plays directly but fails (a server without
  byte ranges), whose video or audio AVPlayer cannot decode (HEVC tagged `hev1`, which plays as audio over black;
  DTS or TrueHD, which AVFoundation does not even list, so the movie seems silent; on iPhone and iPad MPEG-4
  Part 2, H.263 and MPEG-2 video: `PlaybackRoute.engineReason`) or that keeps waiting for data for 12 s
  (servers that allow one connection per account stall AVPlayer's seeks) moves to the engine, at the
  same position.
- **On demand through the engine** (`fluxo_remux_request_segment`): the engine plans a complete VOD
  playlist before playback starts, from the duration and the key frame index of the input (MP4,
  Matroska Cues, AVI), or one segment every 4 s cut at the next key frame (MPEG-TS, files without an
  index). Segments are produced when AVPlayer asks the loopback server for them: a request far from
  what the engine reads seeks the input there (`av_seek_frame`, keeping the real timestamps, so every
  segment plays where the playlist puts it), so skipping, scrubbing to any point and resuming play at
  once. The engine reads 60 s ahead of the player, then pauses until half of it is used (the radio
  rests in between), keeps at most the time-shift disk budget of segments (the farthest from the
  player are deleted and made again if needed), and reopens the input after a read error (6 attempts,
  "Reconnecting…"). HTTP movies are read through the engine's own AVIOContext: a seek closes the connection
  before it opens one at the new position (FFmpeg's HTTP protocol opens the new one first, which accounts limited
  to one connection refuse), and a connection refused as busy (403, 429, 5xx) is tried again for a few seconds,
  at the start too (the previous channel's or AVPlayer's connection may still be open). Inputs that cannot seek (no byte ranges) are read on to the target, or again from
  the start for a jump back; inputs without a known duration are remuxed from start to end into a
  growing playlist that starts at the beginning. HEVC video gets fragmented MP4 segments (with an
  `EXT-X-MAP` initialization segment, `hvc1`): AVPlayer decodes HEVC from HLS only in fMP4. This also
  applies to live HEVC channels. Audio tracks and subtitles (see "Audio tracks and subtitles") are complete VOD
  playlists of the same segments, written with the main segment of the same number; only the requests of the
  main playlist move the reader, a rendition's request waits for its segment.
- **Seeking** (`PlayerSeeker`, `ScrubPreviewProvider`): every seek (scrubber, skip buttons, keyboard, remote
  commands, resume) goes through one coordinator. The scrubber's knob and times follow the finger and never the
  player's clock while it is dragged (a drag the system cancels ends like a release); after the release they stay at
  the target until playback is there (a spinner in the middle of the video after 300 ms), so the bar never jumps back
  to the old position. A seek always ends: once it completed and playback runs (or rests, paused) away from the
  target for a second, the bar follows playback again (logged as a landing error). Only the latest target wins: a seek in flight is
  replaced at most every 250 ms, and quick skip taps add up into one seek 300 ms after the last tap (each seek through
  the engine can cost a reconnection to the server). Released seeks are exact (a quarter of a second either way: with no tolerance at all AVPlayer buffers the next HLS
  segment before it plays, twice as long through the engine);
  local files (downloads, recordings) follow the finger with key frame seeks; movies AVPlayer plays from the network
  show frame previews over the knob (`AVAssetImageGenerator` on the item's asset, key frames, one in flight, cached;
  turned off for a file whose server refuses them); media through the engine shows the time only (its server often
  allows a single connection, which the engine holds). A seek that does not play without media arriving for 8 s (20 s
  through the engine, which still works on the segment and fails it itself after 45 s) is made again from the key
  frame before the target; then the item is recreated at the target (a movie AVPlayer plays itself moves to the
  engine; a new item from the engine starts at the target, `fluxo_remux_set_start_time`), and a stall on that item
  fails: "Couldn't play from this point." with Try Again over the timeline, reachable with VoiceOver and Full Keyboard
  Access, and announced (cleared by itself once playback runs at the target after all). A seek AVPlayer drops (it
  completes it as not finished while it starts an item) is made again at once, then 150 / 300 ms later, each time
  once the item is ready; after the third retry the recovery above takes over, so a seek never stays loading with
  nothing in flight (`run_vod.sh dropped`, the harness's `seek-drop:`). A seek that takes over 3 s shows where it
  goes under the spinner ("Loading 6:41…"); the spinner sits on the player's thin glass platter, legible over a
  bright picture. Picture in Picture's skip buttons seek AVPlayer themselves: in Picture in Picture, a jump of the
  item's time past what was buffered that the seeker did not make is made again through it (through the engine, AVPlayer asks for the
  segment before it posts the jump, too late for the engine to write it from a key frame: it played from the next
  key frame, 4.6 s late on `wifi` MPEG-TS; now within 0.3 s). Haptics: a tick when the drag starts and ends, a bump
  at either end of the bar, a light tap per skip.
- **Seeking through the engine**: a request that starts at most 10 s of media after what the engine reads is reached by
  reading on, a farther one by seeking the input (segments are as long as the GOPs of the input, often 10 s, so a
  count of segments was too coarse). A resume starts the engine at the saved position (`start_time`, written as
  `EXT-X-START`), so the first segment produced is the one there. Inputs without an index (MPEG-TS) are planned at
  nominal 4 s and now cut exactly at the planned times; AVPlayer places MPEG-TS segments by the playlist, so media that
  started earlier or later than planned showed the picture seconds off the timeline, and a seek into a segment that
  started inside a GOP showed the previous picture over the audio until the next key frame (to the end of the movie
  near its end). They are seeked by byte position estimated from the size and duration (one request instead of a
  timestamp search of a dozen), corrected from the bit rate when the landing is off, a GOP before the target. The
  first segment after a seek then starts at the key frame before it (its pre-roll), with those frames timed
  in the last ticks before the segment, so AVPlayer decodes them but shows at most the last one (the frame just before
  it; decode times never go back across segments); a seek into a segment on disk that starts inside a GOP
  writes it again that way. Every seek also tells the engine where it goes (`fluxo_remux_note_seek`), because a seek
  just past what the player buffered asks for the segment after the last one it loaded, which looks like playing on:
  that segment, written ahead or being written from inside a GOP, would play from its next key frame, seconds after
  the target (with the bar stuck at the target). Such a seek, and any seek into the segment the reader writes or
  reaches by reading on, starts a run of its own there. The reader keeps the packets read since the latest key frame
  (references, at most 48 MB), so that run starts with its pre-roll from memory ("replayed" through the router)
  instead of reading the GOP again from the network; farther seeks read it from the input as before. So every segment
  a player seeks into starts with a key frame and the playlists say so (`EXT-X-INDEPENDENT-SEGMENTS`; without it
  AVPlayer also loaded the segment before, a second seek of the input).
  `Tools/EngineSmokeTest/run_seek.sh` measures all of this (see "Seek latency" below).
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

- **Audio tracks and subtitles** (`MediaSelection.swift`, `Features/Player/Tracks`): the captions button of the
  player (and Playback > Audio and Subtitles on the Mac) lists the audio tracks (audio descriptions marked AD) and
  the subtitles (Automatic, Off, then each track, SDH and closed captions marked) of what plays:
  - **Streams AVPlayer plays itself**: the renditions of an HLS playlist (EXT-X-MEDIA audio, subtitles, closed
    captions) and the tracks of an MP4 / MOV file (AVMediaSelection).
  - **Streams of the remux engine** (raw MPEG-TS channels, Matroska / WebM / AVI movies and episodes, which now go
    through the engine as on-demand inputs): when the input has two audio tracks or more in a codec HLS players
    decode (AAC, AC-3, E-AC-3, MP3), or text subtitles (SubRip, ASS / SSA, WebVTT, timed text), the engine also
    writes a master playlist with one EXT-X-MEDIA rendition per track: the default audio stays in the main media
    playlist, every other audio track gets audio-only MPEG-TS segments, every subtitle stream WebVTT segments cut at
    the same times (`X-TIMESTAMP-MAP` mapped onto the segments' 1.4 s muxing delay; next to fMP4 HEVC video the
    audio segments have no muxing delay and the map starts at 0), with the language, the title,
    the default / forced flags and the accessibility characteristics of the streams. MP2 audio (DVB channels) is not
    offered: it is not an HLS codec and AVPlayer on iOS fails the whole item on it. Bitmap subtitles (DVB, PGS, DVD)
    and teletext cannot be converted and are not listed. The first segment's video tells whether the channel carries
    CEA-608 captions (A/53 user data), which the master then declares (`CLOSED-CAPTIONS`), or not (`NONE`, so no
    empty "CC" choice shows). Recordings keep every audio track (the MP4 then offers them too).
  - **Subtitle files** (movies, episodes, recordings): Load Subtitle File… opens a SubRip (.srt) or WebVTT (.vtt)
    file from Files (UTF-8, UTF-16 or Windows-1252; italic, bold and underline kept). It is copied into the app
    (`Application Support/Subtitles`, the 200 most recent) and loads again by itself when the item plays again;
    Subtitle Timing shifts it in half-second steps. The cues are drawn over the picture by `SubtitleOverlay` and
    follow the playback with a boundary time observer (no polling).
  - **Caption style**: subtitles of the stream are drawn by the video layer in the style of Settings >
    Accessibility > Subtitles & Captioning (System Settings > Accessibility > Captions on the Mac); subtitle files
    use the same style (font, size, colors and opacities, window, corner radius, text edge), read from
    MediaAccessibility and updated when it changes.
  - **Remembered languages** (`TrackPreferences`, Settings > Audio and Subtitles): a track chosen in the menu is
    remembered, and the next channel, movie or episode with a track in that language starts with it (also as
    AVPlayer's audio selection criteria, so it starts in that language). Subtitles: Automatic (the system decides),
    Off (forced subtitles in the audio's language still show) or a language. If the item fails right after an
    audio change (a codec the device cannot decode), the remembered audio language is dropped and the engine's
    stream recovers with its default track.
  - **Picture in Picture**: the stream's own subtitles and audio tracks stay in PiP (the player layer draws them).
    A subtitle file is drawn by the app's view, so it does not show in the PiP window.
  - **Chromecast**: the receiver reads the tracks of an HLS stream itself; while casting, the menu lists the
    receiver's audio and text tracks (`CastMediaStatus.tracks`) and changes them there (`setActiveTrackIDs`), with
    the remembered languages applied when the media loads, and subtitles use this device's caption style
    (`GCKMediaTextTrackStyle.createDefault()`). Subtitle files are not cast: the receiver would have to fetch them
    from this device, and the app never serves anything beyond 127.0.0.1.

### Formats

AVPlayer plays HLS and MP4 / M4V / MOV / 3GP itself; everything else goes through the remux engine (see "Routing"
above). The engine copies every stream AVPlayer decodes from HLS and converts the others while it reads the input
(`Engine/FluxoTranscoder.c`), so live channels, movies, episodes, recordings and downloads all get the same formats:

| Containers | How they play |
|---|---|
| HLS (`.m3u8`) | AVPlayer |
| MP4, M4V, MOV, 3GP | AVPlayer; the engine when AVPlayer fails, cannot decode a track, lists no audio track (DTS, TrueHD in MP4) or, on iPhone and iPad, the video is MPEG-4 Part 2 (beyond the Simple Profile at SD), H.263 or MPEG-2 |
| Matroska / WebM (`.mkv`, `.mk3d`, `.mka`, `.webm`), AVI (`.avi`, `.divx`, `.xvid`), WMV / ASF (`.wmv`, `.asf`, `.wma`), Ogg (`.ogg`, `.ogv`, `.oga`, `.opus`), FLV (`.flv`, `.f4v`), MPEG-PS (`.mpg`, `.mpeg`, `.vob`) | the engine |
| MPEG-TS, M2TS, MTS (`.ts`, `.m2ts`, `.mts`, `.m2t`, `.trp`), extensionless and `.php` links | the engine, live or on demand by the playlist entry's kind |

| Video | iPhone and iPad | Mac |
|---|---|---|
| H.264 (8-bit 4:2:0) | copied | copied |
| H.264 High 10, 4:2:2, 4:4:4; H.264 / HEVC with B-frames in AVI (no presentation times to copy) | converted to 8-bit H.264 | 10-bit 4:2:0 copied (the Mac decodes it), others converted |
| HEVC (`hvc1`, `hev1`, Main 10, HDR10) | copied, in fragmented MP4 tagged `hvc1` | same |
| AV1 | copied (fragmented MP4) on devices with an AV1 decoder (iPhone 15 Pro and later, M3 and later); elsewhere "This video can't be played: its video format (…) isn't supported." | same |
| VP9 | converted (AVPlayer does not decode VP9 from HLS, even where VideoToolbox can; VideoToolbox decodes it on devices that have a VP9 decoder) | same |
| MPEG-1 / MPEG-2 | converted, interlaced pictures deinterlaced | copied |
| MPEG-4 Part 2 (Xvid, DivX), DivX 3 / MS-MPEG4, H.263, Sorenson Spark, VC-1, WMV 7 / 8 / 9, VP8, Theora, Motion JPEG | converted | same |
| anything else (RealVideo, ProRes outside MOV, ...) | "unsupported video format" error | same |

| Audio | iPhone and iPad | Mac |
|---|---|---|
| AAC-LC, HE-AAC, AC-3, E-AC-3 (Dolby Atmos), MP3 | copied | copied |
| MP2 (DVB channels) | converted to AAC | copied |
| DTS (core and DTS-HD), Dolby TrueHD / MLP, FLAC, ALAC, Opus, Vorbis, PCM (WAV, AVI, MOV, Blu-ray, DVD), WMA 1 / 2 / Pro, AMR, ADPCM, Nellymoser, AAC LATM (DVB-T2), AAC Main / LTP | converted to AAC-LC (mono, stereo or 5.1, at most 48 kHz) | same |

Subtitles: SubRip, ASS / SSA, WebVTT and timed text become WebVTT renditions ("Audio tracks and subtitles");
bitmap subtitles (PGS, DVB, VobSub) are not shown.

- **Converting**: audio with FFmpeg's decoders and its AAC encoder (192 kbit/s stereo, 384 kbit/s 5.1, the fast
  coder); video with FFmpeg's decoders (VP9 with VideoToolbox's decoder where there is one) and the system's
  hardware H.264 encoder (`h264_videotoolbox`, power-efficient mode, no B-frames, about 0.12 bit per pixel:
  1.5 Mbit/s for SD, about 6 Mbit/s for 1080p25), with a key frame at every segment start, so seeking a converted
  movie works like any other (the segment of the new position is converted on request, from the key frame before
  it). Interlaced MPEG-2 and VC-1 pictures get a vertical blend; HDR VP9 becomes SDR. At most four audio tracks of
  one input are converted (the default first); each converted track is still an HLS rendition with its language.
- **Battery**: copying stays the norm (nothing is decoded); audio conversion costs a few percent of one core. Video
  conversion decodes in software (except VP9 on devices with a VP9 decoder) and encodes in hardware; on demand, the
  engine converts its 60 s read-ahead in a burst and then rests, so the cost is a short burst per minute rather than
  a constant load. A live MPEG-2 channel on iPhone is converted continuously. MPEG-4 Part 2 in MP4 / MOV at the
  Simple Profile and up to 640 × 480 (what iPhone and iPad list among their video formats) plays directly;
  Advanced Simple (Xvid, DivX) is converted.
- **Timestamps**: the engine moves timestamps to its own timeline as the input gives the packets, before anything
  is converted, so a live source that starts its clock again (a restart, a restreamer that switches source, a
  spliced programme) jumps at the same moment on every stream. A converted picture whose time goes back anyway (a
  container without that handling) starts a new encoder at the new time, keeping the key frame interval.
- **Background and Picture in Picture**: converted video needs the hardware encoder, and the system may refuse
  it while the app is in the background. The engine then cuts the segments on the audio, so the sound goes on
  (the picture stops), and the picture comes back with a key frame once an encoder opens again (tried about once
  a second). On demand, the segments read ahead meanwhile stay without a picture until the movie is opened again.
  Copied video is not affected. Not yet checked on a device (the Simulator and the Mac never refuse the encoder;
  `FLUXO_TEST_REFUSE_ENCODER` simulates it in `run_converted.sh`).
- **Downloads** (`DownloadConversion`): files that are not MP4 / MOV (Matroska, AVI, WMV, Ogg, MPEG-TS, ...), and
  MP4 / MOV files with a track AVPlayer does not play (DTS or TrueHD audio, `hev1` HEVC; on iPhone and iPad
  MPEG-4 Part 2 beyond the Simple Profile), are converted into MP4 after the download with the same rules; MP3 and
  MP2 audio become AAC there too (AVFoundation does not list MPEG audio stored in MP4). A conversion keeps every
  picture: when the video encoder is refused (the app went to the background) it waits a few seconds, then stops
  and runs again once the app is active, from the original that it keeps.
- **Checks**: `Tools/EngineSmokeTest/run_formats.sh` (macOS; `IPHONE=1` decides like an iPhone) and
  `Tools/Simulator/format-matrix.sh` (the app in the iOS Simulator) play one file of each combination below, served
  on 127.0.0.1, and check frames, audio, skipping, scrubbing and resuming. Last run:

| Case (container-video-audio) | macOS | iOS (Simulator) |
|---|---|---|
| `mp4-h264-aac` | direct: avc1 / aac | direct: avc1 / aac |
| `m4v-h264-aac` | direct: avc1 / aac | — |
| `mov-h264-alac` | direct: avc1 / alac | — |
| `mov-mpeg4-aac` | engine (fallback): avc1 / aac | engine: avc1 / aac |
| `mp4-mpeg4sp-aac` | direct: mp4v / aac | direct: mp4v / aac |
| `mp4-h264-ac3` | direct: avc1 / ac-3 | — |
| `mp4-hevc-eac3` | direct: hvc1 / ec-3 | direct: hvc1 / ec-3 |
| `mp4-hev1-aac` | engine (fallback): hvc1 / aac | engine: hvc1 / aac |
| `mp4-h264-dts` | engine (fallback): avc1 / aac | engine: avc1 / aac |
| `mp4-h264-opus` | direct: avc1 / opus | — |
| `mp4-h264-flac` | direct: avc1 / flac | — |
| `3gp-h263-aac` | direct: h263 / aac | engine: avc1 / aac |
| `mkv-h264-aac` | engine: avc1 / aac | engine: avc1 / aac |
| `mkv-h264-ac3` | engine: avc1 / ac-3 | engine: avc1 / ac-3 |
| `mkv-h264-eac3` | engine: avc1 / ec-3 | engine: avc1 / ec-3 |
| `mkv-h264-dts` | engine: avc1 / aac | engine: avc1 / aac |
| `mkv-hevc-dts` | engine: hvc1 / aac | engine: hvc1 / aac |
| `mkv-h264-truehd` | engine: avc1 / aac | engine: avc1 / aac |
| `mkv-h264-flac` | engine: avc1 / aac | engine: avc1 / aac |
| `mkv-h264-opus` | engine: avc1 / aac | engine: avc1 / aac |
| `mkv-h264-vorbis` | engine: avc1 / aac | engine: avc1 / aac |
| `mkv-h264-pcm` | engine: avc1 / aac | engine: avc1 / aac |
| `mkv-h264-mp2` | engine: avc1 / mp2 | engine: avc1 / aac |
| `mkv-h264-alac` | engine: avc1 / aac | — |
| `mkv-h26410-aac` | engine: avc1 / aac | engine: avc1 / aac |
| `mkv-hevc10-hdr10-eac3` | engine: hvc1 / ec-3 | engine: hvc1 / ec-3 |
| `mkv-av1-opus` | engine: av01 / aac | unsupported (no AV1 decoder) |
| `mkv-vp9-opus` | engine: avc1 / aac | engine: avc1 / aac |
| `mkv-mpeg2-ac3` | engine: mp2v / ac-3 | engine: avc1 / ac-3 |
| `mkv-xvid-mp3` | engine: avc1 / mp3 | — |
| `mkv-tracks-dts-ac3-srt-ass` | engine: avc1 / aac | engine: avc1 / aac |
| `webm-vp9-opus` | engine: avc1 / aac | — |
| `webm-vp8-vorbis` | engine: avc1 / aac | engine: avc1 / aac |
| `webm-av1-opus` | engine: av01 / aac | unsupported (no AV1 decoder) ¹ |
| `avi-xvid-mp3` | engine: avc1 / mp3 | engine: avc1 / mp3 |
| `avi-divx3-mp3` | engine: avc1 / mp3 | engine: avc1 / mp3 |
| `avi-h264-ac3` | engine: avc1 / ac-3 | — |
| `avi-mjpeg-pcm` | engine: avc1 / aac | engine: avc1 / aac |
| `ts-h264-aac` | engine: avc1 / aac | — |
| `ts-h264-latm` | engine: avc1 / aac | engine: avc1 / aac |
| `ts-mpeg2-mp2` | engine: mp2v / mp2 | engine: avc1 / aac ¹ |
| `ts-mpeg2i-mp2` | engine: mp2v / mp2 | engine: avc1 / aac |
| `ts-hevc-eac3` | engine: hvc1 / ec-3 | — |
| `m2ts-h264-dts` | engine: avc1 / aac | engine: avc1 / aac |
| `m2ts-h264-truehd` | engine: avc1 / aac | — |
| `mts-h264-ac3` | engine: avc1 / ac-3 | — |
| `flv-h264-aac` | engine: avc1 / aac | — |
| `flv-flv1-mp3` | engine: avc1 / mp3 | engine: avc1 / mp3 |
| `wmv-wmv2-wma2` | engine: avc1 / aac | engine: avc1 / aac |
| `mpg-mpeg2-mp2` | engine: mp2v / mp2 | engine: avc1 / aac ¹ |
| `vob-mpeg2-ac3` | engine: mp2v / ac-3 | engine: avc1 / ac-3 |
| `ogg-vorbis` | engine: – / aac | engine: – / aac |
| `opus-audio` | engine: – / aac | — |
| `hls-h264-aac` | direct: avc1 / aac | — |
| `xtream-extensionless-dts` | engine: avc1 / aac | engine: avc1 / aac |
| `xtream-avi` | engine: avc1 / mp3 | — |
| `php-xvid` | engine: avc1 / mp3 | — |
| `sample-wmv-vc1` | engine: avc1 / – | engine: avc1 / – |
| `sample-m2ts-vc1i-dts` | engine: avc1 / aac | engine: avc1 / aac |
| `sample-ogv-theora-vorbis` | engine: avc1 / aac | — |
| `live-ts-mpeg2-mp2` | engine-live: mp2v / mp2 | engine-live: avc1 / aac ¹ |
| `live-ts-h264-latm` | engine-live: avc1 / aac | engine-live: avc1 / aac ¹ |
| `live-ts-h264-aac` | engine-live: avc1 / aac | engine-live: avc1 / aac ¹ |

Each cell: the route, then the formats AVPlayer decodes (video / audio four-character codes: `avc1` / `aac` for
streams the engine converted; – when the file has no such track). "engine (fallback)": AVPlayer opened the file, then
the movie moved to the engine. —: not part of the Simulator run (the same decision as on the Mac).
¹ `run_formats.sh` with `IPHONE=1` on the Mac (the iPhone's decisions: MPEG-2 and MP2 converted), for cases the
Simulator run does not cover. AV1 needs a hardware decoder, which the Simulator does not have; on the Mac (M4) it is
copied. Checked on macOS 26 (M4 Pro) and the iOS 27.2 Simulator (iPhone 17e); not on a device.

Engine smoke tests (macOS). They build the engine against the bundled `FFmpeg.xcframework` and
serve a generated live stream on 127.0.0.1. Generating and checking the test streams needs the
`ffmpeg` / `ffprobe` programs (any recent build, e.g. `brew install ffmpeg`, used by the tests
only; set `FFMPEG` / `FFPROBE` to use others):

```sh
Tools/EngineSmokeTest/run.sh           # window cleanup, reconnection, recording + MP4 conversion
Tools/EngineSmokeTest/run_avplayer.sh  # AVPlayer pause/resume/skip/go-live on the engine output
Tools/EngineSmokeTest/run_tracks.sh    # audio tracks and subtitles: master playlist, renditions, WebVTT, AVPlayer
Tools/EngineSmokeTest/run_vod.sh       # movies: skip, scrub, resume on MP4 / MKV / TS / HLS, H.264 and HEVC
Tools/EngineSmokeTest/run_formats.sh   # the format matrix: every container / video / audio codec (see "Formats")
Tools/EngineSmokeTest/run_converted.sh # converted video: live timestamp restarts, a refused encoder, file conversion
```

`run_vod.sh` generates 10-minute test movies and serves them on 127.0.0.1 the way IPTV panels do (Xtream
Codes paths, extensionless and `.php` URLs, a server without byte ranges, a throttled one, one connection per
account that refuses a second one or drops the older one; Matroska with two audio tracks and subtitles in H.264
and HEVC, whose audio switch and subtitle timing are checked too). Each case is
played by `VODCheck` (the app's `PlaybackRoute`, `StreamRemuxer` and loopback server, on another port, with
AVPlayer): skip +30 s twice, scrub to 25 / 50 / 90 %, skip back, then close and resume at the saved
position; after each step playback must continue there with video frames that are not black.

### Seek latency

```sh
Tools/EngineSmokeTest/run_seek.sh                   # every route and network, with PlayerSeeker
SEEKER=legacy Tools/EngineSmokeTest/run_seek.sh     # the seeks the player made before PlayerSeeker
Tools/EngineSmokeTest/run_seek.sh ts poor           # cases whose name contains one of the words
```

`run_seek.sh` plays a 1080p H.264 movie (4.5 Mbit/s, a key frame every 10 s at most, 10 minutes) through every
on-demand route (AVPlayer directly: MP4 with the moov first and last; the engine: Matroska, MPEG-TS) from the loopback
server with the latency and bandwidth of a phone on Wi-Fi (`wifi`: 60 ms to the first byte, 3 MB/s; `poor`: 250 ms,
1.2 MB/s, about twice the bit rate), and seeks like people do: a drag, four quick +30 taps, a release just past what the
player buffered (and Picture in Picture's skip button just past it again, AVPlayer seeking itself), three -10 taps,
two releases in a row, a fine drag, 8 s before the end, back, a seek while paused, a
resume, a skip after it. Each seek is timed from the release (or the last tap) until the seek is over and the player
plays within 3 s of the target with frames that keep up with the clock. Median (worst) per case, before (the
player's seeks and the engine before `PlayerSeeker`) and after:

| Case | Before | After |
|---|---|---|
| lan, MP4 / moov last | | 0.20 s (0.52 s) / 0.15 s (0.52 s) |
| lan, Matroska / MPEG-TS | | 0.21 s (0.41 s) / 0.26 s (0.40 s) |
| wifi, MP4 | 0.99 s (4.39 s) | 0.95 s (4.42 s) |
| wifi, MP4 moov last | 1.10 s (3.83 s) | 1.51 s (4.42 s) |
| wifi, Matroska | 2.41 s (7.20 s) | 2.29 s (4.84 s) |
| wifi, MPEG-TS | 2.74 s (5.79 s), 2 of 11 failed | 3.38 s (4.67 s) |
| poor, MP4 | 2.41 s (6.04 s), 1 failed | 4.54 s (28.41 s: the resume, see below) |
| poor, MP4 moov last | 2.48 s (9.75 s) | 2.74 s (12.73 s) |
| poor, Matroska | 6.11 s (18.21 s) | 5.46 s (12.08 s) |
| poor, MPEG-TS | 7.19 s (15.98 s), 3 failed | 10.03 s (12.45 s) |

Resumes through the engine start where they continue (Matroska 18.2 s to 12.2 s on `poor`, 7.2 s to 4.7 s on
`wifi`). Before, the MPEG-TS seeks failed: four +30 taps landed 34 s past the target, a seek near the end played the
audio over a frozen picture to the end, and in the app the picture ran up to 14 s off the timeline. A release just
past the buffer played from the next key frame (MPEG-TS on `poor`: 5 s after the target, with the bar stuck at the
target); now it lands within 0.3 s of the target on every route (0.7 s on `poor` MPEG-TS, from the GOP in memory).
The cost of a file without an index is its GOP: a far seek reads the key frame before the target and the 4 s segment,
so MPEG-TS seeks on `poor` are correct now but slower than the wrong ones before; Matroska and MP4 are unchanged or
faster. The direct MP4 cases are within the noise of AVPlayer's own loading; their worst case is the resume, measured
from opening the movie again, which on `poor` takes about the 12 s after which a movie moves to the engine.

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

## Apple TV

Fluxo runs on Apple TV (tvOS 26 and later) from the same target as the iPhone, iPad and Mac app. The shared code
(the store, playlist import, the remux engine and its loopback server, the player view model, the TV guide,
search, recommendations, recordings, App Intents) is compiled for tvOS as it is; the screens are the TV's own
(`Fluxo/TV`). This first version is the foundation: the app launches, browses the library and plays; the TV
screens are first versions that the 10-foot UI replaces.

### One multiplatform target

tvOS was added to the existing `Fluxo` target (`SUPPORTED_PLATFORMS`, `TVOS_DEPLOYMENT_TARGET = 26.0`, device
family 3 for the tvOS SDKs) rather than to a target of its own:

- **One app record**: the same bundle identifier (`dev.watermelon.Fluxo`) on every platform is what universal
  purchase needs: one App Store product, bought once for iPhone, iPad, Mac and Apple TV. A second target would have
  to repeat it anyway.
- **The same pattern as macOS**: the target already builds two platforms, with the differences as SDK-conditional
  settings (`[sdk=macosx*]`); tvOS adds its own: its Info.plist (`Fluxo/Info-tvOS.plist`), app icon (below) and
  device family. Packages filter by platform (Google Cast stays iOS only; FFmpeg is linked on iOS, macOS and tvOS).
  The entitlements file is the iOS one (empty).
- **No second list of files**: the target uses a file-system synchronized group, so every new file builds for every
  platform, and a change that does not compile on one fails at once instead of drifting in a target nobody builds.
  A second target would need its own membership exceptions for every iOS-only file, kept in step by hand.
- **One scheme**: every platform builds with `-scheme Fluxo` and a destination.

The cost is that code which exists on one platform only says so in the source: files of the TV screens are wrapped in
`#if os(tvOS)` (a platform filter on the `TV` folder is ignored by the synchronized group, checked with Xcode 27.2), and the touch and pointer
screens that Apple TV replaces in `#if !os(tvOS)`: the iPhone / iPad / Mac player (`Features/Watch`), the root of their
windows (`ContentView`, `MacRootView`), the iPad player windows, the menu bar commands, the Cast button and picker.

### What tvOS does not have

What a platform can do is answered in one place, `App/Platform/PlatformFeatures.swift`, and features ask it instead of
testing the operating system; the APIs tvOS lacks are compiled out only in the file that calls them.

| Capability | On Apple TV |
|---|---|
| Offline downloads (`offlineDownloads`) | Off. tvOS keeps only a small amount of an app's data for sure and may delete everything else (caches) when it needs space, so a downloaded movie could be gone when it is watched; `AVAssetDownloadURLSession` and the storage priorities that protect downloads do not exist there. `DownloadCenter` starts empty and `canDownload` is false, so no screen offers Download. |
| Clipboard (`pasteboard`) | None: Copy Link, Share and the Paste button of Add Playlist are not shown. |
| Notifications with text (`textNotifications`) | tvOS notifications only badge the icon. Reminders are delivered by `ReminderDelivery`: system notifications on iPhone, iPad and Mac (`SystemReminderNotifications`), an alert in the app on Apple TV (`InAppReminderAlerts`, one timer for the next reminder, armed again at launch from the stored reminders), with Watch and Not Now. |
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

### The TV app (`Fluxo/TV`)

- **Root** (`TVContentView`): the tvOS top tab bar with the tabs of the iPhone, in the same order (Home, Guide,
  Library, Settings, Search), driven by `AppNavigation.tab`, so App Intents and the debug routes move it. It sets up
  what `ContentView` sets up elsewhere: the playlist and guide sheets, watch progress, VoiceOver announcements, the
  reminder alert, the play action of every card and the debug harness.
- **Pages** (`TVPages.swift`, first versions): Home (Continue Watching, Favorites, then the first live TV groups of
  each playlist, as shelves of cards), Guide (what is on now on the favorite and recent live channels, Refresh),
  Search (the app's token search, as a grid), Library (Favorites, Recently Watched, Recordings), Settings (the
  playlists: add, refresh, edit and delete through the shared playlist sheets; the version).
- **Cards** (`TVComponents.swift`): the system's card button style (they lift and tilt under focus), 16:9 artwork,
  shelves as focus sections; each card is one VoiceOver element with the channel and its group, and the hint "Plays".
- **Player** (`TVPlayerView`): `AVPlayerViewController` on the app's single `AVPlayer`, so the transport bar, the
  info panel, audio and subtitles and the Siri Remote work as in the TV app; live streams show their live edge and
  time-shift window. HLS plays directly, raw MPEG-TS and the other formats through the remux engine on 127.0.0.1, as
  on iPhone. Until the first frame (and after a failure) the channel and the player's state are shown. Menu closes
  the player and stops playback (there is no mini player on Apple TV); Picture in Picture is off until the TV player
  handles it (the app's own `PlayerSurface` drives none on tvOS).
- **Icon**: Icon Composer has no tvOS rendition, so `Design/Icon/render_tvos_assets.swift` draws the layers of
  `AppIcon.icon` (the brand gradient, the three stream bands, the play glyph) into the layered "App Icon & Top Shelf
  Image" brand assets (Back, Middle and Front layers for the parallax, and the Top Shelf images):
  `xcrun swift Design/Icon/render_tvos_assets.swift`.

### Trying it

```sh
Tools/Simulator/build.sh --platform tvos
Tools/Simulator/test-stream.sh start
Tools/Simulator/run.sh --device "Apple TV 4K (4th generation)" --clone fluxo-mykey-tv-1 --step-shots \
    --route "home;focus:Sky Sport F1;player:Test Pattern (MPEG-TS);wait:8;probe-playback"
```

See "Apple TV" in `Tools/Simulator/README.md` for the harness on tvOS.

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
- **Deleting a source** (Settings › TV Guide or Guide Sources: swipe, or the context menu; only guides you added,
  since a playlist's own guides follow its header): after the confirmation the row leaves at once
  (`EPGStore.deletingSourceIDs`), a running refresh of it is cancelled and awaited, then the source row and its
  manual matches are removed in one save (the guide stops showing it) and its programmes and channels are
  deleted off the main actor, 100 channels per save, so no save holds the store's write lock for long (about a
  second for 100,000 programmes). Reminders are snapshots and stay. Rows left by a deletion cut short are orphans,
  removed at the next launch. The swipe action has no destructive role on purpose: a destructive swipe action
  removes the row at once, which crashed the list when the deletion was only being confirmed.
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

It also deletes a full copy of the synthetic guide while the guide is read, and sources whose import is running
or was cancelled, and checks that nothing of them is left (`guide-check delete`). In the app, the
`delete-guide-source` debug route and `GestureTests.testDeleteGuideSource…` check the same with the Delete
button and real touches (see `Tools/Simulator/README.md`).

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
  can carry account credentials and identifiers end up in Spotlight, donations and shared shortcuts) is an
  `IndexedEntity`: favorites and recently watched channels (up to 250) are in Spotlight, and opening one plays it.
  Its synonyms are the names people say (`ChannelSpokenNames`: "IT: Sky Sport F1 FHD" is also "sky sport f1",
  "Rai 1 HD" also "rai 1" and "rai one"), and Siri's words go through `AppServices.resolveChannel` (every word of
  the name, the favorite among same-named channels, spelled-out numbers in the app's 16 languages: "Rai Uno" is
  Rai 1, a programme on air with that title, a channel number, then the closest name). A number is a position in
  the playlist only alone or with a word that says "channel" or "number" in one of the app's languages ("5",
  "channel 5", "canale 5", "5チャンネル"); "BBC 9" or "Eurosport 7" is a name, and the closest name must have the
  numbers said, so a channel the library lacks is reported as not found instead of playing another one.
  `ProgramEntity` is a guide programme (title, episode, start, end, description, categories, channel).
- Intents: Play Channel (`OpenIntent`, `PredictableIntent`), Play by Name (the system `PlayVideoIntent`),
  Continue Watching (the last unfinished movie or episode, where it stopped), Pause / Resume / Stop Playback,
  Start or Stop Recording (one intent with an action; start can play a channel first), Add to Favorites
  (idempotent), Remove from Favorites, Toggle Favorite, Get Favorites, Search in Fluxo (the system
  `ShowInAppSearchResultsIntent`), Find Channels, Get Suggestions, What's On (now and next of a channel, or what
  the favorite channels show), Search TV Guide, Show Channel Schedule, Set Programme Reminder, Open Screen (Home,
  TV Guide, Search, Favorites, Recently Watched, Recordings, Library; on iOS the last two open the Library tab), and Visual Intelligence search. Results come with a
  dialog and a snippet view. Opening a screen moves a full-screen player out of the way as its close button does
  (into Picture in Picture when Settings › Playback asks for it, else the mini player).
- App Shortcuts (`FluxoShortcuts`, the maximum of ten), with phrases in all 16 languages (`AppShortcuts.xcstrings`):
  see "Siri & Apple Intelligence" below.

### Siri & Apple Intelligence

**What the iOS 27.2 SDK offers, and what Fluxo uses** (checked in the SDK's `.swiftinterface` files):

| Capability | In Fluxo |
|---|---|
| App Shortcuts (`AppShortcutsProvider`): phrases that work without setup, at most ten shortcuts, each phrase with the app name; parameters only from an `AppEnum` or from the entities given to `updateAppShortcutParameters()` | Ten shortcuts. The channel parameter knows the favorites, the watch history and the first live channels of each playlist (up to 80), with spoken-name synonyms; refreshed at launch and, when these names change, after the favorites change or a channel starts (each refresh makes the system query the app again) |
| Assistant schemas, `@AppIntent(schema:)` (iOS 27 `AppSchema`), so Siri with Apple Intelligence understands an intent without a fixed phrase. Domains: assistant, audio (music, podcasts, audiobooks, radio), books, browser, calendar, camera, clock, files, journal, mail, maps, messages, notes, phone, photos, presentation, reader, reminders, spreadsheet, system, visualIntelligence, whiteboard, wordProcessor. **There is no video or TV domain** | `system.open` on Play Channel and `system.searchInApp` on Search in Fluxo (from iOS / macOS 27; `AppSchemaAdoption.swift` writes the extension the macro generates, since the macro cannot gate one conformance of a type that exists from iOS 26). `visualIntelligence.semanticContentSearch` (iOS 26, macOS 27) |
| System intent protocols: `OpenIntent`, `PlayVideoIntent`, `ShowInAppSearchResultsIntent`, `AudioPlaybackIntent` … | Play Channel, Play by Name, Search in Fluxo |
| Spotlight: `IndexedEntity`, `CSSearchableIndex.indexAppEntities`, iOS 27 `IndexedEntityQuery` (Spotlight asks the app to index again) | Channels, with alternate names; `IndexedEntityQuery` from iOS 27 |
| On-screen awareness: `View.appEntityIdentifier(_:)`, iOS 27 `MPNowPlayingInfoPropertyAppEntityIdentifiers` | The player view, and the Now Playing entry (so "this channel" works with the player closed) |
| Predictions and donations: `PredictableIntent`, `AppIntent.donate()` | Play Channel is donated whenever a channel starts (from the app, Siri or Shortcuts), so Siri can suggest the channel watched at that time of day |
| Visual Intelligence: `IntentValueQuery` over `SemanticContentDescriptor`, the `semanticContentSearch` schema | Camera or screenshot → Search → Fluxo's channels: the text in the image is read on the device (Vision, with channel names as custom words) and matched to channel names and guide titles, then the labels to guide categories (`VisualSearchIntents.swift`) |
| Foundation Models (on-device model, tool calling, `@Generable`) | For You, smart search, programme summaries (above); Find Channels uses smart search |
| `SiriTipView`, `ShortcutsLink` | Settings › Siri & Shortcuts |
| SiriKit media intents (`INPlayMediaIntent`) | Not used: they need an Intents extension and are for audio |

**Why "Play … in Fluxo" did not work** (found with the debug harness and the built app's `Metadata.appintents`):

1. Siri never learned a channel name. The Spotlight update began with `CSSearchableIndex.deleteAppEntities(ofType:)`,
   which never returns on iOS 27.2, and `updateAppShortcutParameters()` came after it: nothing was indexed and the
   phrase parameters were never registered, so "Play Sky Sport F1 in Fluxo" matched no shortcut. The phrases are
   now refreshed first, and the index deletes only the channels that left it. No bulk delete is used: in the iOS 27.2
   Simulator `deleteAllSearchableItems()` did not return within 5 s either, and a late one could remove the new
   entries.
2. Even then Siri knew only favorites and recently watched channels: none after a fresh install. It now also
   knows the first live channels of each playlist, and their spoken names ("Sky Sport F1", not "IT: Sky Sport F1
   FHD").
3. A channel Siri does not know made the whole phrase fail. "Watch TV in Fluxo" / "Play a channel in Fluxo" now
   make Siri ask "Which channel?", and the answer is searched in every playlist.
4. No assistant schema: Siri with Apple Intelligence had no standard meaning for Fluxo's intents. Play Channel
   and Search in Fluxo now adopt `system.open` and `system.searchInApp`.
5. Stop Recording and a few actions had no phrase in most languages; the phrase sets of all 16 languages were
   checked (every phrase has the app name and only parameters of its intent).
6. Spotlight ran the wrong action for a channel. The system turns every channel of a phrase parameter into a
   tile titled with the channel's name alone, so with channel phrases for What's On, Add to Favorites and
   Recording too, Spotlight listed each channel several times, and opening its top hit told what is on or added
   a favorite instead of playing. Only Play Channel has channel phrases now; the other three act on the channel
   that plays ("Record this in Fluxo") or ask for one, and Siri AI and the Shortcuts app still fill in any channel.
7. A request that played a channel or opened a screen while a channel schedule was open showed the result behind
   that sheet. Intents now close it first (Recordings are a screen of the Library tab, not a sheet).
8. A channel name with a number that the library lacks played another channel: "Play Rai 4 in Fluxo" (or "BBC
   Four", which becomes "BBC 4") on a playlist without it played the fourth channel of the playlist. A number is
   now a playlist position only alone or next to "channel" / "number", and the closest name must have the numbers
   said (`siri-resolve-check` in the debug harness).

**What to say** (English; every language of the app has its own phrases, see Settings › Siri & Shortcuts):

- "Play Sky Sport F1 in Fluxo", "Watch Rai 1 on Fluxo", "Switch to BBC One in Fluxo"; "Watch TV in Fluxo" (Siri
  asks which channel: say any channel name or number)
- "Continue watching in Fluxo", "What's on in Fluxo" (what the favorite channels show), "What should I watch on
  Fluxo"
- "Search Fluxo" (then the words), "Search the Fluxo guide", "Open the TV guide in Fluxo", "Show my Fluxo
  recordings"
- "Add this channel to my Fluxo favorites", "Start recording in Fluxo", "Stop recording in Fluxo", "Remind me
  about a show in Fluxo"
- "Pause" / "Resume" (Siri's own, through Now Playing). With Siri and Apple Intelligence, requests in other
  words ("open Sky Sport F1 in Fluxo", "find football in Fluxo", "what's on Rai 1 in Fluxo") reach the schema
  intents and the actions without phrases, with the channel resolved through the same search.
- Spotlight: type a favorite or recently watched channel (or the name of a Fluxo action); opening the channel
  plays it.

**Steps on a device**

1. iPhone, iPad or Mac on iOS / iPadOS / macOS 27 (26 for everything but the schemas and the Now Playing entity)
   with Apple Intelligence for the Siri AI part (iPhone 15 Pro or later, iPad or Mac with M1 or later).
2. Install Fluxo and open it once, with a playlist imported. Wait a few seconds: the phrases and Spotlight are
   updated after launch. Mark a few favorites: Siri learns those first.
3. Settings › Apps › Fluxo › Siri: keep "Learn from this App", "Show App in Search"
   and "Show Content in Search" on.
4. Open the Shortcuts app › Fluxo: the ten shortcuts are listed (Open Screen as one tile per screen), plus one
   Play Channel tile per channel Siri knows by name and one Set Reminder tile per upcoming programme. If
   they are not there, the phrases are not registered yet: reopen Fluxo, or restart the device.
5. Say or type (Type to Siri) a phrase above.

**User-side requirements and common mistakes**

- The request must contain "Fluxo". "Play Sky Sport F1" without it goes to the Apple TV app or Music: no app
  can take over playback requests without its name (the SDK has no video schema).
- Siri's language is what counts, not the app's: with Siri in Italian, say the Italian phrases ("Metti Rai 1 su
  Fluxo", "Cosa c'è su Fluxo"). Fluxo has phrases in its 16 languages; in another Siri language, only the
  Shortcuts app works.
- Apple Intelligence needs a supported device, Siri language = device language (a supported one), the model
  downloaded (Settings › Apple Intelligence & Siri), and a region where it is available. Without it, App Shortcut
  phrases still work; only free-form requests need it.
- A channel name in a phrase must be one Siri knows (favorites, recently watched, first channels of a playlist).
  For any other, say "Watch TV in Fluxo" and then the name, or add the channel to the favorites.
- Open the app once after every install or update from Xcode, TestFlight or the App Store; App Shortcuts
  register at install, the channel names after the first launch. Debug builds from Xcode and TestFlight builds
  behave the same; a build from another bundle identifier is another app to Siri.
- Siri cannot be checked in the Simulator ("Siri is not enabled on this device" on iOS 27.2): try the phrases
  on a device. The Simulator's Shortcuts app and Spotlight do work (`Tools/Simulator/siri-tests.sh`).
- The first Set Reminder brings Fluxo to the front, once, for the notification permission; with notifications
  off for Fluxo it answers that reminders need them (Settings › Apps › Fluxo › Notifications).
- Visual Intelligence needs a device with the Camera Control or the Action button (or a screenshot), and
  Apple Intelligence on.
- Shortcuts built with the earlier Start Recording and Stop Recording actions must be rebuilt with Recording
  (Start or Stop): the two actions are now one (release note for the first TestFlight build).
- A Debug run of the macOS app on an isolated library (`-FluxoDebugStore`) neither indexes Spotlight nor donates
  to Siri: it shares the bundle identifier with the real app.

**How this was checked**

- `Metadata.appintents` of the built app (`extract.actionsdata`, `root.ssu.yaml`): 20 intents on iOS and macOS
  (19 in the Simulator, whose SDK has no Visual Intelligence), the schemas `system.open`, `system.searchInApp`
  and `visualIntelligence.semanticContentSearch`, two entities, three queries (two in the Simulator), ten App
  Shortcuts with their phrases in 16 languages, and no warning from `appintentsmetadataprocessor`.
- The debug harness runs every intent in the app, resolving parameters through the entity queries as Siri
  does (`DebugIntentRoutes.swift`; `Tools/Simulator/README.md`, routes `intent:`, `siri-resolve:`,
  `siri-resolve-check`, `siri-names`, `visual-search:`, `visual-ocr:`, `spotlight-reindex`), with the outcome in
  `Status/intents.log`.
- `Tools/Simulator/siri-tests.sh` (an XCUITest bundle) opens the Shortcuts app on a Simulator clone, checks the
  ten shortcuts and runs What's On through the system (its dialog and snippet answer), searches Spotlight for a
  seeded favorite and opens it (Fluxo comes to the front and plays it), screenshots Settings › Siri & Shortcuts,
  and asks Siri (not available in the Simulator).

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
- **Settings** (a tab on iOS, the Settings window ⌘, on macOS): time-shift length, skip
  intervals, automatic PiP (iOS), TV guide sources and the reminder time, recordings count / size / location (Show in Finder on macOS,
  the Files app on iOS through `UIFileSharingEnabled`), delete all recordings, temporary stream
  files, logo cache, watch history, and the app and FFmpeg versions.
- **Recordings** (in the Library tab on iOS, the sidebar on macOS, and the player's menu): play, share, Show in
  Finder (macOS), delete, delete all.
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

## Liquid Glass (iOS 26)

Glass is used for the navigation and control layer only (tab bar, toolbars, the mini player,
the playlist chips, the player controls, sheets). Cards, rows and banners are content and use
plain surfaces or small materials.

- **Tab bar**: a native `TabView` with Home, Guide, Library, Settings and a `.search` role tab. It
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
  `.number.grouping(.never)`, and so do season and episode numbers (`EpisodeFormat.number`: "S2023 E5").
- Dates, times, durations, sizes and time codes use format styles (`.dateTime`, `.interval`,
  `Duration.formatted`, `.byteCount`), never fixed formats or `String(format:)`.
- Whole sentences are keys; a sentence is never assembled from translated pieces. The parts of a subtitle
  line (a kind, a group, a playlist name) are joined with `TextParts.line`, which puts each part in a bidi
  isolate and uses the separator of the language (in Arabic it carries a letter mark, so the line reads
  right to left); VoiceOver labels use `TextParts.spoken` / `TextParts.sentences` (、 and 。 in Japanese and
  Chinese).
- Nothing localized is stored: the guide keeps "S1 E5" and empty titles (`GuideFormat.episode`, "Untitled"
  when shown), a failed guide refresh keeps a `GuideRefreshFailure` code, a failed download keeps a
  `DownloadFailure.Reason` (with the engine's English message) and a download its picture height and the codes of
  its languages, a recording without a channel
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

## Battery

Playback is where the energy goes, so the app sizes the work of playback to what is on screen and to the state of the
device (`Fluxo/App/Power/PowerMonitor.swift`, `Fluxo/Features/Player/PlaybackEnergyProfile.swift`):

- **No video decoding for the mini player.** While a channel plays with the player screen closed (and not in Picture in
  Picture), the player layer lets go of the `AVPlayer`, which then only plays the audio; it takes it again as soon as
  the player screen starts to open, so the video is there during the transition. In the background the system already
  stops drawing the video of the app; the layer is kept there, because Picture in Picture starts from it.
- **The display may sleep** while only the mini player plays (`preventsDisplaySleepDuringVideoPlayback` follows
  whether the video is on screen: the player screen or Picture in Picture). On macOS this also keeps the display awake
  while a video plays in the window, as other video players do.
- **Position sampling** (the timeline of the controls, the watch progress, the seek checks) runs twice a second only
  while the player screen can show it, once a second in Picture in Picture, every two seconds otherwise.
- **Adaptive streams** (HLS with several qualities, which AVPlayer plays itself) are limited to their lowest quality
  while only the audio is heard in the background, to 720p in Picture in Picture, to 1080p in Low Power Mode, to 720p
  when the device is hot (serious thermal state) and 480p when it is critical (`preferredMaximumResolution`,
  `preferredPeakBitRate`). Streams with one quality (the remux engine's, most IPTV channels) are not affected.
- **Optional work waits.** The automatic TV guide refresh (at launch and hourly) waits while something plays or the
  device is hot, and runs 30 s after playback ends; in Low Power Mode a guide is refreshed after 36 hours instead of 12.
  The Apple Intelligence suggestions of Home and the Guide do not run while the player screen covers them, and the
  Spotlight / Siri phrase update after a channel change waits until the channel was kept for 90 s (or the app goes to
  the background), instead of running at every zap.
- **Status symbols rest.** The LIVE waves, the recording dot and the "now playing" waveform animate, then rest three
  seconds before the next run (`ambientSymbolEffect`), instead of redrawing the screen (and the glass behind them, over
  the video) at every frame; they do not animate in Low Power Mode or when the device is hot.
- **The remux engine sleeps** while it is read ahead of the player (a movie or episode, 60 s ahead) or has read the
  whole input: requests and cancellation wake it (a counter of wake-ups under its lock, so none is missed), instead of
  polling four times a second for as long as the movie plays.
- Settings › Playback says when Low Power Mode or the heat changes what the app does.

Measured in the iPhone 17e simulator (iOS 27.2) with the sample library and the loopback test streams
(`top -l -s 5 -c d` on the app process, 30–40 s per case after the route settled; the Mac was busy with other work, so
differences of a percent or two are noise). The simulator decodes video in software and renders Liquid Glass in the app
process, so the absolute numbers are higher than on a device; the differences are what matters:

| Case | CPU before | CPU after | Context switches/s before → after |
|---|---|---|---|
| Home, idle | 0.9 % | 0.8 % | 104 → 97 |
| TV Guide, idle | 3.9 % (launch work) | 1.4 % | 202 → 113 |
| Live HLS (AVPlayer), controls hidden | 15.1 % | 14.4 % | 1192 → 1173 |
| Live MPEG-TS (remux engine), controls hidden | 12.6 % | 12.3 % | 1265 → 1252 |
| Live MPEG-TS, controls shown | 22.2 % | 21.2 % | 2817 → 2493 |
| **Live MPEG-TS, mini player** | **12.5 %** | **3.1 %** | **1322 → 363** |
| Live MPEG-TS, background (audio) | 2.4 % | 2.4 % | 298 → 299 |
| Movie through the engine, controls hidden | 14.7 % | 14.6 % | 1050 → 1085 |
| Movie played by AVPlayer, controls hidden | 14.3 % | 12.5 % | 1060 → 1071 |
| Movie through the engine, background (audio) | 2.4 % | 2.3 % | 284 → 276 |

Idle screens were already idle (no timers: `TimelineView(.everyMinute)` only, no polling); the first seconds after a
launch are the launch work. The debug harness has `power:` / `-FluxoDebugPower` (pretend Low Power Mode or a thermal
state), `power-log` (what the app does now) and `energy-check` (the rules of the profile); see
Tools/Simulator/README.md.
