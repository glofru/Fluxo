# Fluxo

Fluxo is an IPTV player for the M3U playlists and XMLTV guides you add, on iPhone, iPad, Mac and Apple TV. It is
written in SwiftUI and SwiftData, plays what AVPlayer cannot through a small FFmpeg-based remux engine, and keeps
everything on the device: no account, no server, no analytics. It is open source under the MIT License.

- **Live TV, movies and series** from any M3U / M3U8 playlist (Xtream-style ones included): channels by category,
  series grouped by season and episode, favorites, Continue Watching, search that forgives typos.
- **Plays almost anything**: HLS directly; raw MPEG-TS, RTMP, RTSP, UDP, Matroska, AVI, WMV and more through the
  remux engine, which converts the audio and video the system player cannot decode. Time-shift on live channels,
  recordings, offline downloads, Picture in Picture, AirPlay and Chromecast (iPhone and iPad).
- **TV guide** from XMLTV sources, matched to the channels by id and by name, with reminders.
- **Fluxo Intelligence**: recommendations, smart search and programme summaries computed on the device with Apple's
  on-device models, App Intents for Siri and Shortcuts, Spotlight.
- **Apple TV**: its own interface for the Siri Remote, the Top Shelf, Siri and voice search.
- iCloud sync of playlists, favorites and history in the user's private database.

Fluxo provides no channels or content: it plays what the user adds.

## Building

Open `Fluxo.xcodeproj` in **Xcode 27.2** and run the `Fluxo` scheme: one multiplatform target for iOS and iPadOS 27,
macOS 26 and tvOS 26. There is nothing to install: FFmpeg is in the repository (`Vendor/FFmpeg`) and Xcode resolves
the Swift packages (FlyingFox; the Google Cast SDK through `Vendor/GoogleCast`). From the command line:

```sh
Tools/CI/build.sh iossim       # also: ios, mac, tvos, tvsim (unsigned; fails on any warning)
Tools/CI/test.sh               # the unit tests, on a simulator clone of their own
Tools/CI/checks.sh             # the checks under Tools/
```

Details (signing, the build number, the Swift language mode, the FFmpeg build and its debug symbols):
[docs/building.md](docs/building.md).

## Testing and CI

- **Unit tests**: `FluxoTests` (Swift Testing), run by the scheme's Test action through the test plan
  `Fluxo.xctestplan`: M3U parsing, series and episode parsing, search ranking, TV guide matching and XMLTV, playback
  routing, the featured picks and the adult-content filter, the library store and its schema migration, the
  downloads list, the on-device diagnostic reports. See [docs/testing.md](docs/testing.md).
- **Checks** under `Tools/` (`Tools/CI/checks.sh`): the app's sources compiled with `swiftc` against large synthetic
  libraries, guides and playlists, migrations from older commits, the engine against local test streams, the
  acknowledgements against what ships.
- **Simulator harness** (`Tools/Simulator`, Debug builds): isolated seeded libraries, scripted routes, screenshots and
  XCUITest bundles that drive the installed app. See [Tools/Simulator/README.md](Tools/Simulator/README.md).
- **CI**: `.github/workflows/ci.yml` builds the five platform gates, runs the unit tests (iOS Simulator and Mac) and
  the checks. Xcode 27.2 is on GitHub's `xcode-27` image only; [docs/ci.md](docs/ci.md) explains it and how to use a
  self-hosted Mac.

## Documentation

| Page | What it covers |
|---|---|
| [Building](docs/building.md) | Requirements, signing, command-line builds, the Swift 6 language mode, the FFmpeg build |
| [Testing](docs/testing.md) · [CI](docs/ci.md) | The unit tests and the test plan, the Tools checks, the workflow and its runners |
| [Library store](docs/library-store.md) | The SwiftData stores, the versioned schema, migration and recovery |
| [Playlists, Home and search](docs/library.md) | Playlist import, Home, favorites, Library, search |
| [iCloud sync](docs/icloud-sync.md) | What syncs, how, how stream addresses are protected, capabilities |
| [Offline downloads](docs/downloads.md) · [Series](docs/series.md) | Downloads of movies and episodes; series grouping |
| [Player](docs/player.md) | The player, the remux engine, formats, seeking, recordings |
| [Chromecast](docs/chromecast.md) | Casting on iPhone and iPad, the Cast SDK package |
| [Apple TV](docs/apple-tv.md) | The tvOS app, its player, the Top Shelf, Siri |
| [TV guide](docs/tv-guide.md) | XMLTV sources, matching, reminders |
| [Apple Intelligence and Siri](docs/siri-and-apple-intelligence.md) | Recommendations, smart search, App Intents, the device checks |
| [Interface and design](docs/interface.md) | Screens, iPad, the foldable iPhone, Liquid Glass, the brand |
| [Accessibility](docs/accessibility.md) · [Localization](docs/localization.md) | VoiceOver, Dynamic Type and the audit; the 17 languages |
| [Memory and battery](docs/performance.md) | Measurements and what keeps them low |
| [Diagnostics](docs/diagnostics.md) | Crash and performance reports kept on the device; FFmpeg's dSYMs |
| [License, privacy and the App Store](docs/license-and-privacy.md) | Licenses of the included software, privacy, App Store material (`docs/AppStore`) |

## License

Fluxo's own code is released under the [MIT License](LICENSE). FFmpeg (LGPL v2.1 or later), FlyingFox (MIT) and the
Google Cast SDK (Google's terms) keep their own licenses: see [License, privacy and the App Store](docs/license-and-privacy.md)
and Settings › About › Acknowledgements. The privacy policy is [docs/privacy.md](docs/privacy.md).
