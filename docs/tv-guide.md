# TV guide (EPG)

The Guide (`Features/Guide`) is a tab on iOS and a sidebar entry on macOS. It shows a time grid of the live
channels that have a guide, programme details, programme search and reminders.

- **Sources** (`EPGSource`): the XMLTV URLs of a playlist header (`#EXTM3U url-tvg="…"`, `x-tvg-url` or
  `tvg-url`, which can list several comma-separated URLs) are stored at import (`Playlist.guideURLString`) and
  become guide sources. For playlists imported before this, the guide reads only the first line of the playlist
  once. You can add XMLTV URLs in Settings › TV Guide (Add Guide Source). The app has no built-in guide: the
  former "Use Free Guide" shortcut to epgshare01's scraped country guides was removed, because their terms do not
  allow it (see `docs/AppStore/legal-review.md`); a user can still add any guide address, epgshare01's included.
- **Download and parsing** (`EPGImporter`): the file is streamed to disk, then read by `XMLTVParser` (SAX
  `XMLParser`) through `InflatingInputStream`, which inflates `.xml.gz` with zlib as it is read. The XML is never
  held in memory. The parser runs on a utility queue and keeps only the programmes from 6 hours ago to 7 days
  ahead, of the channels that can match a live channel of a playlist. Programmes are written in batches of
  2,000 into short-lived background contexts, under a new import ID, and become visible when the whole guide is
  stored (a failed refresh keeps the previous guide, and so does a file cut short when the previous guide had
  more programmes). When the stored guide was read for the same playlist channels, the request is conditional
  (`If-None-Match` / `If-Modified-Since`): a 304 or an identical file (SHA-256) is not read again.
- **Import speed** (`Tools/GuideCheck/run.sh`, 1,500 channels x 8 days, half of them wanted): 261,750 programmes
  import in about 19 s on a Mac (the 161 s once measured came from an overloaded host; parsing alone is about 3 s,
  the rest is SwiftData inserting). The redundant `[importID]` index was dropped (about 1 %). Batches of 5,000 would
  be 6 % faster but take 18 MB more at the peak (10,000: no faster, 60 MB more), so they stay at 2,000 for Apple TV
  and the background refresh. `BATCH=<n>` compares sizes. Each import's history is pruned (see [Library store](library-store.md)).
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
- **Programme details** (`ProgrammeDetailView`, a sheet or the iPad / Mac inspector): Watch, Record (a programme
  on air, on a channel the engine plays) and Remind Me. Record plays the channel and records it once its stream is
  open (`PlayChannelAction.playAndRecord`); while the channel records (the mini player, Picture in Picture), the sheet
  shows REC with the duration (`RecordingBadge`) and Stop Recording, which saves the recording to Recordings.
- **Reminders** (`ReminderCenter`): a local notification 5 minutes before the start (0 to 30 minutes in
  Settings); tapping it, or its Watch action, plays the channel. The notification carries only the reminder
  key (stream URLs can embed account credentials); the channel is read from the store. The reminders list is in
  the Guide toolbar. Opening a notification only records what to play (`channelToOpen`); the window plays it once
  it is on screen, so a cold launch from the notification waits for the UI. A notification whose reminder no longer
  exists (deleted since, or its programme ended more than 12 hours ago) opens the TV guide with "Reminder Not Found"
  instead. Deleting a playlist cancels its reminders.

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
