---
title: Fluxo Privacy Policy
---

# Fluxo Privacy Policy

*Last updated: November 6, 2026. Applies to Fluxo for iPhone, iPad, Mac and Apple TV.*

Fluxo is a player for the M3U playlists and XMLTV guides **you** add. Its developer runs no server, has no account
system, and does not collect, receive, sell or share any data about you. There is no advertising, no analytics and
no tracking in the app.

## What stays on your device

Everything Fluxo knows about you stays on your device:

- the playlists and guide addresses you add (they can contain the user name and password of your provider),
  their channels, programmes and logos;
- favorites, watch history, resume points, reminders and settings;
- recordings and offline downloads. They play only in Fluxo and are not shared with other apps;
- recommendations ("For You"), smart search and programme summaries. They are computed **on the device**, with
  Apple's on-device models where available. Nothing is sent to the developer or to a cloud AI service.

## What Fluxo connects to, and why

Fluxo talks only to the servers below. Each one receives your device's IP address and the usual technical data of an
internet request (time, app name in the user agent), as with any app that uses the internet.

| Who | When | What they receive |
|---|---|---|
| **Your providers** (the servers in the playlists and guide addresses you add) | When Fluxo imports or refreshes a playlist or a guide, loads logos and artwork, and plays a channel, movie or episode | The addresses you added, including any user name, password or token they contain |
| **The demo playlist hosts** (only if you add the demo playlist): GitHub (the playlist file), the Blender Foundation (`download.blender.org`), Apple (`devstreaming-cdn.apple.com`) and Unified Streaming (`demo.unified-streaming.com`) | When you add or play the demo playlist | The request for the file or stream |
| **Apple iCloud** (only if iCloud sync is on) | To sync your playlists, guide addresses, favorites, history and settings between your devices | This data, in your **private** iCloud database, which only your Apple Account can read. Stream addresses are encrypted on the device before they are sent; with Advanced Data Protection they are end-to-end encrypted. Fluxo's developer cannot read it. Settings › iCloud › What's Synced and Privacy lets you delete it |
| **Google Cast** (iPhone and iPad, only when you cast) | When you look for Chromecast devices and play something on one | See "Google Cast" below |

Fluxo uses the **local network** only to play streams from servers in your home (a TV tuner, a media server) and,
on iPhone and iPad, to find Chromecast devices after you open the Cast picker.

## Google Cast

Casting uses Google's Cast SDK, which is included in the iPhone and iPad app.

- Device discovery starts only when you open the Cast picker. Fluxo turns off the SDK's analytics logging
  (`disableAnalyticsLogging`).
- Even so, Google declares in the SDK's privacy manifest that it may collect a **device identifier**, **diagnostic
  data** and **product interaction** data, *not linked to your identity and not used for tracking*, for analytics and
  app functionality. Google's handling of this data is described in the
  [Google Privacy Policy](https://policies.google.com/privacy) and the
  [Google Cast terms](https://developers.google.com/cast/docs/terms).
- To play a channel, Fluxo sends its **stream address** (which can contain your provider's user name and password),
  its name and its logo to your Chromecast. Google's Default Media Receiver on the Chromecast then loads the stream
  from your provider.

If you never cast, the Cast SDK sends nothing.

## Apple services

Siri, Spotlight, Shortcuts, the Top Shelf of Apple TV and notifications get the names of channels, programmes and
reminders so that they can show or say them; this happens on your device under Apple's privacy policy. iCloud sync is
described above.

## Children

Fluxo is not directed at children and collects no data from anyone.

## Your choices

- Delete a playlist, the watch history, recordings or downloads in the app (Settings), or delete the app to remove
  everything it stored on the device.
- Turn iCloud sync off, and delete Fluxo's iCloud data, in Settings › iCloud.
- Don't use casting to avoid the Google Cast SDK's data collection.

## Changes and contact

Changes to this policy are published here, in Fluxo's public repository, with the date above
([history](https://github.com/glofru/Fluxo/commits/main/docs/privacy.md)). For questions, open an issue at
[github.com/glofru/Fluxo/issues](https://github.com/glofru/Fluxo/issues).
