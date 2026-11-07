# App Review notes

Paste the "Notes" part into App Store Connect › App Review Information › Notes (it is short on purpose). The rest
of this page is the background for answering App Review's questions.

## Notes (for App Store Connect)

```
Fluxo is a media player for IPTV playlists (M3U) and TV guides (XMLTV) that the user adds. The app does not
provide, sell, host or link to any channel, movie or series: it starts empty, and says so on the first screen,
in Add Playlist and in Settings › About ("Fluxo doesn't provide any channels or content. Add only playlists from
providers you subscribe to or have the right to use."). There is no built-in channel list or guide.

HOW TO TEST (no account or login is needed):
1. Launch Fluxo. On the first screen tap "Try the Demo Playlist", then Add.
   (Or tap Add Playlist and enter: https://raw.githubusercontent.com/glofru/Fluxo/main/docs/demo/fluxo-demo.m3u)
2. The demo playlist has only free, legal content: a live test stream (Unified Streaming's public demo),
   Apple's HLS example stream, and three Creative Commons films of the Blender Foundation (Tears of Steel,
   Sintel, Elephants Dream, CC BY), streamed from blender.org.
3. Home shows them under Live TV and Movies. Tap one to play. Sintel is a Matroska (MKV) file, which Fluxo plays
   through its own FFmpeg-based engine.
4. Recording: while the live test stream plays, tap the record button; recordings are in Library.
5. Casting (iPhone/iPad): the Cast button appears when a Chromecast is on the same network.

PERMISSIONS: Local Network is asked only when the user opens the Cast picker or plays a stream from a server on
the local network. Notifications are asked only when the user sets a programme reminder.

APP TRANSPORT SECURITY: NSAllowsArbitraryLoads is set because the playlists, guides, logos and streams are
user-supplied addresses on the user's own providers, and many IPTV providers and home servers (TV tuners,
media servers) only offer plain http://. Fluxo has no server of its own. Add Playlist warns when an http://
address contains a user name or password.

RECORDINGS AND DOWNLOADS: they are for personal, in-app viewing only. They cannot be shared, exported or opened
in the Files app.

Open source (MIT): https://github.com/glofru/Fluxo. Privacy policy:
https://github.com/glofru/Fluxo/blob/main/docs/privacy.md
```

## Background

### Guideline 5.2 (intellectual property)

- **No content.** The Release build bundles no stream, playlist or guide (the Debug harness and its seeds are
  compiled out with `#if DEBUG`). The built-in "Use Free Guide" shortcut to scraped XMLTV listings (epgshare01) was
  removed (see `legal-review.md`); guides come only from the user's playlists (`url-tvg`) and the addresses the user
  adds.
- **Notice.** `ContentNotice` (Fluxo/App/Legal/LegalInfo.swift): the first-run screen, Add Playlist and Settings ›
  About, on every platform.
- **5.2.3 (downloading media from third-party sources).** Downloads and recordings copy streams of the user's own
  provider for time-shifted personal viewing. They stay inside the app: no Share, no Show in Finder, and
  `UIFileSharingEnabled` is off, so the Files app and the Finder do not list the app's Documents. Playlists can
  still be opened *from* Files ("Open in Fluxo"; `LSSupportsOpeningDocumentsInPlace`).
- **Demo content.** `docs/demo/fluxo-demo.m3u`, see `docs/demo/README.md` for the licenses. The app offers it as
  "Try the Demo Playlist" (first-run screen) and "Use the Demo Playlist" (Add Playlist). The playlist file is served
  from the repository, so a stream that disappears can be replaced without an app update. Check every stream before
  each submission (`docs/demo/README.md` has the command).

### Guideline 2.1 (completeness)

The app is fully functional with the demo playlist; no account, purchase or provider is needed for review.

### App Transport Security

`NSAllowsArbitraryLoads = true` (Info.plist, Info-tvOS.plist). Justification as in the notes. Narrower settings do
not work: the hosts are unknown at build time (user-supplied), and `NSAllowsArbitraryLoadsForMedia` does not cover
playlists, XMLTV guides, logos and the engine's own HTTP requests. The loopback HLS server listens on `127.0.0.1`
only and is not reachable from the network.

### Export compliance

`ITSAppUsesNonExemptEncryption = NO`, see `export-compliance.md`.

### Things App Review may ask about

- **"Your app appears to provide access to pirated content."** Answer with the notes above: no content, no
  directory, the notice, and the demo playlist. Fluxo is a player in the same category as VLC or Infuse.
- **Local network prompt on iPhone without casting.** It appears when a playlist points at a server on the local
  network (a TV tuner); the usage string says so.
- **Multicast (`udp://@239…`).** Not supported on iPhone and iPad (no multicast entitlement); the player says so at
  once.
