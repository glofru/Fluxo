# Player

- **Routing** (`PlaybackRoute`, from the URL and the kind of the entry): HLS playlists and MP4/MOV
  files play directly in AVPlayer. Raw MPEG-TS channels (no extension or `.ts`, or `udp://`, `rtp://`,
  `rtmp://`, `rtsp://`) go through the remux engine, which writes local HLS that
  AVPlayer reads from the loopback server (see "Loopback server" below; 127.0.0.1 only).
  Live channels with `.m3u8` URLs play directly in AVPlayer, so they use the
  DVR window of the source playlist (if it has one) and cannot be recorded.
  Movies and episodes AVPlayer cannot open go through the engine's on-demand mode: Matroska, WebM, AVI,
  WMV / ASF, Ogg, FLV, MPEG-PS / VOB, MPEG-TS / M2TS files (Xtream Codes `…/movie/user/pass/123.ts`),
  extensionless and `.php` URLs (see [Formats](#formats)). A movie that plays directly but fails (a server without
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
  main playlist move the reader, a rendition's request waits for its segment. A request for a segment that will
  not come answers at once (`fluxo_remux_request_segment` returns -2: no such segment, or the session finished,
  failed or was cancelled), so the player is never left waiting on a dead session.
- **Seeks that end the input** are failed seeks, not the end of the movie: FFmpeg's FLV demuxer reads whatever is at
  a byte position as a tag, so a byte seek that landed inside a tag ran its parser past the end of the file, and the
  engine marked the movie as ended there (every later segment answered -2 until it was opened again). FLV byte
  seeks now go to the first tag at or after the estimated position (`fluxo_flv_tag_at_or_after`: a tag header, its
  `PreviousTagSize` and the next header must agree, within 256 KB). And whatever the format, an end of input before
  the first segment after a seek is complete, more than 30 s before the end of the input, makes the seek again: by
  time when it was a byte seek, then by reading the input again from its start, for that input from then on
  (`fluxo_vod_retry_seek`). `run_probe.sh` seeks forward and back in every container of the format matrix, FLV
  included, also from a server without byte ranges.
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
  through the engine, which still works on the segment and fails it itself after 45 s, within the loopback server's
  limit) is made again from the key
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
  `Tools/EngineSmokeTest/run_seek.sh` measures all of this (see [Seek latency](#seek-latency)).
- **Deterministic start**: the engine has its own HLS segmenter and reports each
  completed segment. The player item is created once, after the first segment
  exists and the server is listening. There is no polling.
- **Loopback server** (`SimpleHTTPServer`, FlyingFox): it gives the engine's files to AVPlayer and listens on
  127.0.0.1 only, never on the network. Within the device it answers only the player:
  - the port is one the system picks when the server starts (port 0), so no other app can count on it (a server started
    again, after iOS reclaimed its socket in the background, asks for the same port first, so the items of the session
    keep their addresses; debug builds can fix it with `-FluxoDebugLoopbackPort`);
  - every address has the random token of its playback session as its first path component (`/<128-bit hex>/<file>`,
    a new one per channel or movie, compared in constant time): anything else is 404, including the files of an
    earlier session;
  - the `Host` header must be `127.0.0.1:<port>`: a web page that a DNS rebinding attack points at 127.0.0.1 sends its
    own host name and gets 421;
  - flat file names of the HLS types only, from the one directory;
  - a server that cannot bind or listen is a player error with Try Again ("The player couldn't start its local stream
    server."), not a channel that stays on "Connecting…".
  Its time limit for a request (60 s, `LoopbackTimeouts.request`) is longer than the engine's wait for an on-demand
  segment (45 s, `LoopbackTimeouts.segmentWait`), from the same constant: FlyingFox's default of 15 s answered 500
  for any segment that took 15 to 45 s (a slow server, a far seek), and the player went through its rebuilds to an
  error. A request the server ends (its limit, or it stops) is cancelled in the engine too
  (`StreamRemuxer.requestFile` resolves the wait). `run_vod.sh slow-segment` plays a seek whose segment takes about
  25 s: one request, no error (with the old 15 s limit: an HTTP 500 in AVPlayer's error log).
- **Time shift (DVR)**: live channels keep a sliding window of 30 minutes by
  default (5 to 120 minutes in Settings, `PlayerPreferences`), with a disk budget of
  512 MB per 30 minutes, or a tenth of the free disk space if that is smaller.
  Segments that leave the window are deleted. You can pause, resume, scrub, skip
  back or forward (10 s / 30 s by default, configurable), and go back to live
  (`AVPlayerViewModel`).
- **Paused live channels** keep reading, so the window covers what is missed, until it would buy nothing more
  (`PausedTimeShiftPolicy`): the engine closes the input (`fluxo_remux_set_input_suspended`; the window and the
  playlist stay) once the full window starts letting go of media within 20 s of the paused position (the position
  stays playable), or after 2 minutes of pause on an expensive or constrained network (cellular, a personal hotspot,
  Low Data Mode) or in Low Power Mode. Never while recording. Playing again, going live or recording opens the input
  at once, without "Reconnecting…": the playlist continues after an `EXT-X-DISCONTINUITY`, the timeline without a
  gap (the part of the broadcast that aired meanwhile is not in the window). The player's item does not survive the
  pause: AVPlayer gives up on a live playlist that stays unchanged (CoreMedia -12888, seven times in about 40 s), and
  then waits forever at the end of what it had after the resume (macOS), or fails the item with -11866 "Playback
  Stopped" (iOS, which the item recovery then played again, unasked, from the end of the window). So the engine marks
  the playlist as ended while the input is closed (`EXT-X-ENDLIST`: not reloaded, the paused item stays playable within
  the window), reports the suspension (`FluxoRemuxEventInputSuspended`, with the last segment before it), and
  playing on attaches a new item once the engine wrote the first segment after the resume, at the same media. The
  media are named by their date: the engine's `EXT-X-PROGRAM-DATE-TIME` follows its media timeline (the wall clock of
  the session's first segment plus the durations, as `EXTINF` says them, of the segments before, across discontinuities
  too), not the wall clock of each segment, so `currentDate()` minus `currentTime()` is the same everywhere in an item,
  whichever segment's date AVPlayer extrapolates from, and every item of the session shows the same media at the same
  date (`PausedTimeShiftPolicy.MediaClock`, read when an item becomes ready, before it plays: once it plays, AVPlayer's
  dates are those of its media, a few frames off the playlist's, 0.08 to 0.12 s with the test channel, while its
  time stays the playlist's). The old item's position (or where a seek under way within its media goes)
  becomes a date, and the new item continues at that date once it is ready and has one (`resumeDate`,
  `resumeItemTime`, `AVPlayerViewModel.continueAfterSuspension` and `resumeAfterSuspension`); Go Live continues at the
  end of the frozen media, where the media after the resume follow. No playlist read at the wrong moment can shift it.
  (So the dates fall behind the wall clock by the time an input was closed or reconnecting: nothing in the app reads
  them as the time of day.) While the input is closed the old item's seekable range is that of the frozen media, by the
  same clock (on macOS AVPlayer reports a range of no length past the media for an item whose playlist is marked as
  ended), and Play does not seek to the oldest media then (`continuesFromOldestMedia`). A Play that comes after the
  engine was asked to close the input still gets its new item; the engine does not mark the playlist as ended at all
  when the Play comes before it does. `run_probe.sh suspend`
  checks the engine side: no segment while suspended, the playlist marked as ended only then, segments again within
  4 s of the resume, the suspension reported once, every segment's date its predecessor's plus its `EXTINF`, across
  the discontinuity; `run_vod.sh live-pause` the player side with AVPlayer: 70 s
  suspended without a playlist error, the frozen media holding the paused position, then a new item that shows the
  paused frame (compared with the frame 2 s later) and plays on past the resume with the same clock, also in a window
  that slides meanwhile and closes the input when the policy says so (`live-pause-sliding`); the app in the iOS
  Simulator with `-FluxoDebugPower low-power` and the route `player:Test Pattern (MPEG-TS);wait:8;pause;wait:195;
  resume;wait:5;probe-playback` the whole path (suspended after 2 minutes, still paused 70 s later, plays on).
- **Reconnection**: when a live input drops or ends, the engine reconnects with
  backoff (0.5 s to 8 s, 10 attempts). Buffered media keeps playing in the
  meantime, and the playlist continues with `EXT-X-DISCONTINUITY`.
- **Dead channels fail fast** (every platform): the first open makes one connection per attempt
  (`FluxoRemuxConfig.quick_open`; FFmpeg's own reconnection on network errors, 0 + 1 + 3 s per attempt, comes back
  once the input is open), and the engine tries again only when it can help (`fluxo_first_open_retries`): a refused or
  reset connection or a failed name lookup once, 0.5 s later (IPTV servers often refuse the first connection of a
  burst); a server refusing the account (403, 429, other 4xx, 5xx: one connection per account, the previous channel's
  still open) three times, 0.5, 1 and 2 s apart; a timed-out connection (FFmpeg's 5 s to connect), 404, 401, a missing
  protocol or a format that cannot play not at all. Measured with `run_probe.sh` (macOS, before → after): refused
  19.7 s → 0.54 s, unknown host 20.1 s → 0.57 s, 404 and 401 at once, 403 and 503 3.7 s (unchanged), an unreachable
  address 5.1 s. That last one is FFmpeg's TCP connect timeout (`tcp.c`: 5 s, not `rw_timeout`): only the tcp
  protocol's own `timeout` option shortens it, and that option is also the read timeout of the connection and stays
  in the http protocol's options for its reconnections, so a shorter one for the first open would cut the live read
  timeout (15 s) of that connection too. Left at 5 s.
- **Error messages** name what failed and why in the user's language: the engine's English message
  ("Unable to open the stream: Connection refused") is translated in both parts (`EngineMessage`; the reason from
  FFmpeg's error code, `FluxoRemuxEvent.error_code`: refused, timed out, reset, unreachable, 400, 401, 403, 404, 429,
  other 4xx, 5xx, damaged data, end of stream, disk full, and an input/output error while the input opens, which is
  how FFmpeg reports a failed name lookup: "the server couldn't be found or reached"; other reasons stay in English).
  The engine's own words go to the log. Screens that explain failures in plain words read the code and what failed
  (`EngineMessage.error(code:message:)`, `reason(of:)`, `AVPlayerViewModel.itemFailureError`), not the text.
- **Recording**: the record button writes the live stream to
  `Documents/Recordings/<channel>-<date>.ts`, which is a second output of the
  engine. When the recording stops, it is converted to `.mp4` (stream copy) so
  that you can play it and seek in it. Recordings can be listed, played and
  deleted from the player, Library (the Library tab on iPhone and iPad, Library › Recordings on Apple TV) or the
  Library section of the Mac's sidebar. The conversion writes a
  hidden temporary file that is renamed when complete. Recordings interrupted
  by a crash are converted at the next launch.
- **Recording limits** (`RecordingLimits`): a recording does not start with less than 1 GB free, stops when the free
  space falls under 512 MB (checked every 10 s of recording; the engine itself stops only on a write error, once the
  disk is full), and stops at the length set in Settings › Recordings › Stop Recording After (4 hours unless changed;
  30 minutes to 6 hours, or No Limit), keeping what it recorded, with a message in the player. The Recordings folder is
  excluded from device backups (an hour of HD is several GB of the user's iCloud storage); Apple TV keeps them in
  Caches anyway.
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
  time (see [iPad](interface.md#ipad)). Startup cleanup (leftover segments, interrupted
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

## Formats

AVPlayer plays HLS and MP4 / M4V / MOV / 3GP itself; everything else goes through the remux engine (see "Routing"
above). The engine copies every stream AVPlayer decodes from HLS and converts the others while it reads the input
(`Engine/FluxoTranscoder*.c`), so live channels, movies, episodes, recordings and downloads all get the same formats:

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
- **Encoder back-pressure**: FFmpeg's VideoToolbox encoder gives back at most one packet per picture it is sent and
  keeps the rest until it is flushed, and nothing else stops the reader from running ahead of the encoder (a movie is
  converted at full speed: the 60 s read-ahead of playback, or a whole download conversion). The converter counts the
  pictures in flight (sent minus packets received) and flushes the encoder, which waits until VideoToolbox has
  finished all of them, then opens a new one: at a segment start (a key frame it places anyway) above 24, or at once,
  with a key frame of its own, at 48 (`FLUXO_ENCODER_DRAIN_AT_KEY`, `FLUXO_ENCODER_MAX_IN_FLIGHT`,
  FluxoTranscoder.c). Both are above an encoder's own pipeline, so they cost nothing while it keeps up: a safety net,
  which none of the measured runs reached (at most 17 in flight, below). Measured with
  90 s of 1080p MPEG-2 converted as on an iPhone (`probe.c convert` / `vod`, `FLUXO_ENCODER_TRACE` prints the most in
  flight and the flushes), with and without the bound: M4 Mac, hardware encoder: at most 12 in flight, about 10 s
  and 75 MB peak for the file conversion, 8 s and 70 MB for 64 s of on-demand playback, the same both ways; the
  software encoder on the Mac (in its own process): at most 17; the iOS Simulator (software encoder, in the app's
  process, `xcrun simctl spawn`): at most 17 in flight, 420–440 MB peak and about 50 s both ways (the
  production-readiness report measured 280–360 MB there). The Simulator's peak is the same with and without the bound,
  so it is not a backlog of pictures: 17 pictures of 1080p NV12 are about 50 MB, and the rest is the working memory of
  the software encoder and the decoders, which was not broken down further. The growth the report measured (871
  sample buffers) did not happen at this version, and the bound keeps it from happening. Devices use the hardware
  encoder; their memory and CPU during a long 1080p MPEG-2 / VC-1 conversion still need measuring on a device.
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
Tools/EngineSmokeTest/run_probe.sh     # the engine without AVPlayer: seeks in every container, dead channels, pauses
SANITIZE=1 Tools/EngineSmokeTest/run_probe.sh   # the same with AddressSanitizer + UndefinedBehaviorSanitizer
SANITIZE=1 Tools/EngineSmokeTest/leaks.sh       # the leak check's sessions under the sanitizers instead of `leaks`
```

`run_probe.sh` (`probe.c`) drives the engine directly and is quick enough for the sanitizers: segment requests in the
order of a player that seeks forward and back in 12 containers over HTTP (FLV with and without byte ranges, Matroska
with tracks, MP4 `hev1`, MPEG-TS, AVI, WMV, MPEG-PS, WebM); dead channels with a time limit each (refused, unknown
host, 404, 401: 1.5 s; 403, 503: 4.5 s); a session that ended answers -2 for a segment not on disk; seeks in an FLV
whose metadata say 120 s more than it has (`flv-overlong.flv`): within its media they play, past its real end the
engine answers -2 within seconds (it used to read the whole input again from its start first); a live input
suspended and resumed. Every check passes, also with `SANITIZE=1` (any AddressSanitizer or UndefinedBehaviorSanitizer
report fails it; built with `-fno-sanitize-recover=all`), and `leaks.sh` reports no leak; UBSan found the signed
overflow `fluxo_vod_route` had (a key frame interval computed from `AV_NOPTS_VALUE` before its check).

`run_vod.sh` generates 10-minute test movies and serves them on 127.0.0.1 the way IPTV panels do (Xtream
Codes paths, extensionless and `.php` URLs, a server without byte ranges, a throttled one, one connection per
account that refuses a second one or drops the older one; Matroska with two audio tracks and subtitles in H.264
and HEVC, whose audio switch and subtitle timing are checked too). Each case is
played by `VODCheck` (the app's `PlaybackRoute`, `StreamRemuxer` and loopback server, on a port of its own, with
AVPlayer): skip +30 s twice, scrub to 25 / 50 / 90 %, skip back, then close and resume at the saved
position; after each step playback must continue there with video frames that are not black.

## Seek latency

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

## Source files

- **`AVPlayerViewModel`** (`Features/Player`): `AVPlayerViewModel.swift` has its state, channel selection, zapping and
  the lifecycle hooks; extensions hold the rest by concern: `+Transport` (play / pause, skips, seeks, the seeker),
  `+Recording`, `+Playback` (starting and tearing down playback, item failures, the fallback to the engine, stalls,
  disk space), `+State` (engine events, the playback state, Now Playing, the energy profile, the timeline),
  `+PausedTimeShift` (a paused live channel: closing the engine's input, the new item after it, with the rules in
  `PausedTimeShiftPolicy.swift`), `+PictureInPicture`, `+Cast` and `+AudioSession`. `PlaybackTimeline.swift` is the
  fast-changing position. `SimpleHTTPServer.swift` is the loopback server (and `LoopbackTimeouts`).
- **The remux engine** (`Features/Player/Engine`, C): `FluxoRemuxEngine.h` is its interface (the only header Swift sees).
  `FluxoRemuxEngine.c` has the session, its thread, events and file conversion; `FluxoEngineInput.c` the input,
  `FluxoEngineOutput.c` the muxers, `FluxoEngineHLS.c` the segmenter and its playlists, `FluxoEngineRenditions.c`,
  `FluxoEngineText.c` (WebVTT, language tags) and `FluxoEngineMasterPlaylist.c` the master playlist and its renditions,
  `FluxoEngineRecording.c` recordings and requests from other threads, `FluxoEngineLive.c` the live packet loop and
  reconnection, and `FluxoEngineVODPlan.c`, `FluxoEngineVODPackets.c` and `FluxoEngineVOD.c` on-demand inputs. They share
  `FluxoEngineInternal.h` (limits, types, the functions one file calls in another; hidden from the binary's exports).
  The converter is `FluxoTranscoder.h` / `.c` (decisions, the stream reader) with `FluxoTranscoderVideo.c` and
  `FluxoTranscoderAudio.c`, sharing `FluxoTranscoderInternal.h`. The tools that build the engine take every `.c` file
  of the folder (`FLUXO_ENGINE_SOURCES` in `Tools/FFmpeg/env.sh`).
