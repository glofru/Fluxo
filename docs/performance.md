# Memory and battery

## Memory

- **Playback sessions** (checked with the harness: 2 and then 12 play-and-close cycles in one launch, `heap`): no
  `AVPlayerItem` or app object outlives its session. One `FigTimebase` (384 bytes) does: the default proxy timebase of
  each `AVPlayerItem`, which stays registered in `NotificationCenter` by the system frameworks after the item is gone
  (`leaks --traceTree`: held only by `_CFXNotificationRegistrarAddObject`). Recreating the periodic time observer per
  session did not release it, and the registrant is inside AVFoundation, not the app: about 38 KB after 100 sessions,
  left as it is.

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
- **The engine's network input** (the URL loading system, see [Network input](player.md#network-input)): at most
  4 MB waits per connection (the task is suspended above it, resumed below 1 MB), so a connection the engine does
  not read (a paused movie, the read-ahead reached) holds about that, plus what the system's network stack had
  already received.
  Against FFmpeg's http protocol (`Tools/EngineSmokeTest/run_http.sh cost`, macOS, four runs): the same peak memory
  reading a 1080p movie at 4 MB/s (18 to 20 MB against 18 to 19 MB for the whole process), and about twice the CPU time
  for the system's HTTP and TLS stack: 2.4 to 3.1 % of a core against 1.3 to 1.7 % over HTTP, 3.0 to 3.7 % against 1.4
  to 1.9 % over TLS 1.2; a live channel of 2.4 Mbit/s the same with both (0.7 to 1.0 % against 0.7 to 0.9 %). Read at
  the speed of the loopback interface (gigabytes per second, which no real network delivers), the system's network
  stack buffers more than the task's suspension stops: the process then peaks at 26 to 131 MB against 17 to 18 MB
  (`leaks.sh`, `FOOTPRINT_ONLY=1`: 32.5 MB against 12.9 MB after 12 cycles of every kind of session; it does not grow
  with more sessions, and `leaks` finds nothing).
- **Observation**: the player, the timeline, the recordings, the import center and
  Settings use `@Observable`. A view re-renders only for the properties it reads, so,
  for example, playback state changes no longer re-render the playlist browser.

Measurement tools (macOS):

```sh
Tools/ImageLoaderBenchmark/run.sh   # former logo path vs LogoImageLoader, on 127.0.0.1
Tools/EngineSmokeTest/leaks.sh      # engine sessions under `leaks --atExit`; FOOTPRINT_ONLY=1 prints the footprint per cycle
Tools/EngineSmokeTest/run_http.sh cost   # CPU time and memory of the engine's two HTTP inputs, on 127.0.0.1
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
