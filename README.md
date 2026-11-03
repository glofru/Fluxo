# Fluxo

Fluxo is a SwiftUI IPTV / M3U player for iOS and macOS.

## Building

Open `Fluxo.xcodeproj` in Xcode 26 or later and run the `Fluxo` scheme.
The app needs iOS 26 / macOS 26.

Live streams go through a small C remux engine
(`Fluxo/Features/Player/Engine`) built on FFmpeg's libavformat, libavcodec
and libavutil. The engine copies the stream into HLS segments on disk, and a
local HTTP server bound to `127.0.0.1` gives them to AVPlayer.

### iOS

The bundled FFmpeg 6 frameworks in `fmpeg-arm64/ffmpeg/framework` are linked
and embedded. You do not need to install anything. These frameworks contain
only an iOS device `arm64` slice, so build for a real device
(`generic/platform=iOS`). The iOS Simulator cannot link them.

### macOS

The Mac app links FFmpeg from Homebrew. Install it first:

```sh
brew install ffmpeg
```

The project expects FFmpeg at `/opt/homebrew/opt/ffmpeg` (Apple silicon
Homebrew). To use another prefix, change the `FFMPEG_MACOS_PREFIX` build
setting. The app loads the Homebrew dylibs at runtime, so the hardened runtime
uses the `com.apple.security.cs.disable-library-validation` entitlement
(`Fluxo/Fluxo-macOS.entitlements`). The same file grants the sandbox
`network.client` (to read streams) and `network.server` (for the loopback HLS
server).

The macOS build is signed ad hoc ("Sign to Run Locally") so that it builds
without a Mac Development certificate. To distribute the app, set the macOS
code signing style back to Automatic. A distributed build must also embed
FFmpeg, because it cannot depend on Homebrew being installed.

Command-line builds:

```sh
# iOS device (unsigned)
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO

# macOS
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -destination 'platform=macOS' build
```

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

- **Home** (`Features/Home`) shows a playlist switcher ("All Playlists" plus one
  chip per playlist), a featured carousel, Continue Watching, Favorites, and the
  groups of the chosen kind (Live TV / Movies / Series). Each group is a lazy row
  of its first 24 channels, with "See All" opening a paged grid. Group rows are
  fetched 8 at a time as they scroll in.
- **Content kinds** are guessed once at import time (`ChannelContentKind`) from
  the URL (Xtream `/movie/` and `/series/` paths, file extensions) and from the
  names (`S01E02`, "Series" groups). Each group gets the most common kind of its
  channels. Playlists imported before this change show as Live TV until refreshed.
- **Favorites and watch history** are `ChannelBookmark` rows keyed by
  playlist + stream URL, so they survive refreshes (which rewrite channel rows),
  and they are deleted with their playlist. The history keeps the 200 most recent
  entries.
- **Search** debounces typing by 250 ms and runs the name query on a background
  context, with a limit, over the selected playlist or all of them.
- **macOS** uses a sidebar (Home, Search, Favorites, Recently Watched,
  Recordings, and each playlist) and a Settings window (Cmd-,). iOS uses tabs.

To check every Home and Search query against an on-disk store (100k channels):

```sh
CHANNELS=100000 Tools/HomeQueriesCheck/run.sh
```

## Player

- **Routing** (`PlaybackRoute`): HLS playlists and MP4/MOV files play directly in
  AVPlayer. Raw MPEG-TS channels (no extension or `.ts`, or `udp://`, `rtmp://`,
  `rtsp://`, `srt://`) go through the remux engine, which writes local HLS that
  AVPlayer reads from the loopback server (`127.0.0.1:19123` only).
  Live channels with `.m3u8` URLs play directly in AVPlayer, so they use the
  DVR window of the source playlist (if it has one) and cannot be recorded.
  An on-demand `.ts` file served over HTTP ends normally once its last byte is
  read; any other end of a live input is treated as a dropped connection.
- **Deterministic start**: the engine has its own HLS segmenter and reports each
  completed segment. The player item is created once, after the first segment
  exists and the server is listening. There is no polling.
- **Time shift (DVR)**: live channels keep a sliding window of at most 30
  minutes and at most 512 MB, or a tenth of the free disk space if that is
  smaller. Segments that leave the window are deleted. You can pause, resume,
  skip back 10 s or forward 30 s, and go back to live (`AVPlayerViewModel`).
- **Reconnection**: when a live input drops or ends, the engine reconnects with
  backoff (0.5 s to 8 s, 10 attempts). Buffered media keeps playing in the
  meantime, and the playlist continues with `EXT-X-DISCONTINUITY`.
- **Recording**: the record button writes the live stream to
  `Documents/Recordings/<channel>-<date>.ts`, which is a second output of the
  engine. When the recording stops, it is converted to `.mp4` (stream copy) so
  that you can play it and seek in it. Recordings can be listed, played and
  deleted from the player or from the Watch toolbar. The conversion writes a
  hidden temporary file that is renamed when complete. Recordings interrupted
  by a crash are converted at the next launch.
- **One player per app**: `FluxoApp` owns the only `AVPlayerViewModel`. The
  main UI is a single `Window` on macOS, and multiple scenes are disabled on
  iOS, because the loopback port, the PiP surface and the segment directory can
  have only one owner. Startup cleanup (leftover segments, interrupted
  recordings) runs once per process, before the first session starts, and only
  in the instance that holds `tmp/fluxo-instance.lock`, so a second copy of the
  app sharing the same container never deletes files the first one writes.
- **Picture in Picture**: the `AVPlayerViewController` (iOS) or `AVPlayerView`
  (macOS) belongs to the view model (`PlayerSurface`), so PiP keeps running when
  the player screen closes. Stopping PiP presents the player again. On iOS the
  audio session uses `.playback` / `.moviePlayback` and the `audio`
  background mode.

Engine smoke tests (macOS, Homebrew FFmpeg). They serve a generated live
stream on 127.0.0.1:

```sh
Tools/EngineSmokeTest/run.sh           # window cleanup, reconnection, recording + MP4 conversion
Tools/EngineSmokeTest/run_avplayer.sh  # AVPlayer pause/resume/skip/go-live on the engine output
```

Debug builds (`Fluxo/App/Debug/DebugAutoplay.swift`) also accept `-FluxoDebugAutoplayURL <url>`, which plays a stream at
launch, and `-FluxoDebugRecordSeconds <n>`, which records it for n seconds.

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
