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
