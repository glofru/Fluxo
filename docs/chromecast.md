# Chromecast

Fluxo casts to Chromecast and Google TV / Cast-enabled TVs and speakers on iOS and iPadOS (`Features/Cast`).

- **SDK**: the official [Google Cast iOS Sender SDK](https://developers.google.com/cast/docs/ios_sender) 4.8.6:
  Google's signed binary `GoogleCast.xcframework` (device and Simulator slices), the archive of the `GoogleCastDynamic`
  product of [`googlecast/google-cast-ios-sdk`](https://github.com/googlecast/google-cast-ios-sdk), through a local
  Swift package, `Vendor/GoogleCast` (same URL and checksum). Google's own package also adds its `gtm-session-fetcher`
  dependency, a static library linked into the app, while `GoogleCast.framework` already contains GTMSessionFetcher
  and binds to its own copy: every GTMSessionFetcher class was in the app twice, and the Objective-C runtime warned at
  launch ("Class GTMSessionFetcher… is implemented in both…"; which copy a lookup by name finds is undefined). The local
  package links the framework alone, so there is one copy. Updating the SDK: the new URL and checksum in
  `Vendor/GoogleCast/Package.swift`, then `Tools/Legal/extract-googlecast-licenses.sh` and
  `Tools/Legal/check-acknowledgements.sh` (the check also fails if Google's package comes back). It is linked on iOS
  only (a platform filter): Google ships no sender SDK for macOS, so
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
