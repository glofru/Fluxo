# Building

Open `Fluxo.xcodeproj` in **Xcode 27.2** and run the `Fluxo` scheme. 27.2 is the version the project is built and
tested with (SDKs 27.2, Swift 6.4); Xcode 26 cannot build it at all (iOS 27 deployment target and APIs), and earlier
Xcode 27 releases are not checked. Test (⌘U) runs the unit tests, see [Testing](testing.md); CI builds every
platform on each push and pull request, see [CI](ci.md).

**Requirements**: iOS and iPadOS 27 or later (`IPHONEOS_DEPLOYMENT_TARGET = 27.0`), macOS 26 or later and tvOS 26 or
later. On iPhone and iPad the app uses the iOS 27 APIs directly, with no code paths for older releases: the player's
status bar (`ToolbarPlacement.statusBar`), the App Intents schemas, Spotlight's `IndexedEntityQuery` and the Now
Playing entity (see [Apple Intelligence and Siri](siri-and-apple-intelligence.md)). The Mac and Apple TV builds keep their availability
checks for what comes with macOS 27 and tvOS 27, and the foldable iPhone's hinge APIs stay behind iOS 27.1.

Live streams go through a small C remux engine
(`Fluxo/Features/Player/Engine`) built on FFmpeg's libavformat, libavcodec
and libavutil. The engine copies the stream into HLS segments on disk (converting the audio and video
AVPlayer cannot decode, see [Formats](player.md#formats)), and a local HTTP server bound to `127.0.0.1` gives them to AVPlayer.

There is nothing to install: FFmpeg ships with the repository (see [FFmpeg](#ffmpeg)), and the
Swift packages, [FlyingFox](https://github.com/swhitty/FlyingFox) (the loopback HTTP server) and
Google's [Cast SDK](https://developers.google.com/cast/docs/ios_sender) (iOS only, `Vendor/GoogleCast`, see
[Chromecast](chromecast.md)), are resolved by Xcode on its own. The app builds for iOS devices, the iOS Simulator, macOS, Apple TV
and the tvOS Simulator, from the one `Fluxo` target and scheme.

The scheme runs **Debug** (Run, Test, Analyze) and profiles and archives **Release** (Profile, Archive), so
Instruments measures optimized code.

**Signing.** iPhone, iPad and Apple TV are signed automatically by the team (`4MJXMYZ3D9`) in both configurations.
On the Mac, **Release** is signed automatically by the team too, with the hardened runtime and library validation
on: `Fluxo/Fluxo-macOS.entitlements` grants only the sandbox, `network.client` (to read streams) and
`network.server` (for the loopback HLS server), and the team signature covers the embedded `FFmpeg.framework`.
**Debug** on the Mac is signed ad hoc ("Sign to Run Locally"), so it builds and runs without a Mac Development
certificate; it uses `Fluxo/Fluxo-macOS-Debug.entitlements`, which adds
`com.apple.security.cs.disable-library-validation`: an ad hoc signature has no Team ID, so library validation
would refuse to load the framework. Release never has that entitlement. Neither Mac build has iCloud yet (see
[Capabilities and signing](icloud-sync.md#capabilities-and-signing)).

**Build number.** `CURRENT_PROJECT_VERSION` (CFBundleVersion of the app and of the Top Shelf extension, which must
match) is set per upload with `Tools/Release/set-build-number.sh [<n>]` (agvtool; the project uses the
`apple-generic` versioning system) or `CURRENT_PROJECT_VERSION=<n>` on a CI `xcodebuild archive`. The App Store
checklist is `docs/AppStore/README.md`.

Command-line builds:

```sh
# iOS device, Release (unsigned)
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -configuration Release -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO

# iOS Simulator
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

# macOS: Debug signed ad hoc, or Release (team-signed; CODE_SIGNING_ALLOWED=NO for an unsigned check)
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -configuration Debug -destination 'platform=macOS' build
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -configuration Release -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

# Apple TV, Release (unsigned) and the tvOS Simulator
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -configuration Release -destination 'generic/platform=tvOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -configuration Debug -destination 'generic/platform=tvOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Without `-configuration`, `xcodebuild build` uses the scheme's Run configuration (Debug).

The SwiftData schema is versioned (`Fluxo/App/Database/FluxoSchema.swift`) and its models are listed in
`Fluxo/App/Database/ModelRegistry.swift`, as user data or cache; see [Library store](library-store.md) before changing a model.
`.swiftlint.yml` configures [SwiftLint](https://github.com/realm/SwiftLint) for
manual runs (`swiftlint lint`); it is not part of the build.

## Swift

Every Swift target builds in the **Swift 6 language mode** (`SWIFT_VERSION = 6.0`): the app, the Top Shelf extension,
the unit tests (`FluxoTests`) and the UI test bundles of `Tools/Simulator`. It is the newest mode of the Swift 6.4 compiler in Xcode 27.2 (the
compiler accepts 4, 4.2, 5 and 6), so concurrency checking is complete and a possible data race is a compile error, not
a warning. The build has no warnings, and it should stay that way.

Four upcoming features of the next language mode are on as well (project-level `SWIFT_UPCOMING_FEATURE_*` settings,
so every target gets them):

- **`NonisolatedNonsendingByDefault`**: an async function that is not isolated to an actor runs on the actor of its
  caller instead of the global executor (`nonisolated(nonsending)`), so calling it does not send its arguments to
  another isolation domain. The functions that must not run on their caller's actor are marked `@concurrent`, which is
  how every such function ran before the change: SwiftData fetches on a background `ModelContext`, file, image and
  network work, the loopback server's request handler, the App Intents queries, the recommenders. A new async function
  that does real work off the main actor needs `@concurrent` too; one that only awaits other async calls does not.
  Closures given to `Task.detached`, task groups and the SDK keep running where they did.
- **`InferIsolatedConformances`**: a conformance of a main-actor type is isolated to the main actor, so delegates that
  the SDKs call on the main thread (Picture in Picture, the Apple TV player, the Cast SDK's listeners) are plain
  main-actor classes. `nonisolated` marks a conformance that must not be isolated (`CKSyncEngineDelegate`, which is
  `Sendable`).
- **`ExistentialAny`** (`any` is written out) and **`MemberImportVisibility`** (each file imports the modules whose
  members it uses).

Deliberately not adopted:

- **Default actor isolation stays `nonisolated`** (not `MainActor`). Much of the app runs off the main actor on
  purpose (the playlist and guide imports, the search index, downloads, the image loader, sync, the engine's threads),
  and its UI types and view models are already explicitly `@MainActor`. Main-actor by default would move every
  unannotated type to the main actor and need `nonisolated` on hundreds of declarations, for no safety gain.
- **`InternalImportsByDefault`**: the app module has no public API, so it would change nothing.
- **`StrictMemorySafety`** (opt-in, not part of a language mode): it would flag every call into the C engine and
  FFmpeg, which are unsafe pointer code by nature, without making them safer.
- Xcode's **Approachable Concurrency** setting is not set: in the Swift 6 mode it only turns on the two concurrency
  features above, which are set explicitly instead.

Rules that keep it correct:

- **Callbacks from Objective-C or C code** (`MPRemoteCommand` handlers, Core Spotlight queries, notifications a
  framework may post on another queue, the remux engine's callback) are `@Sendable` closures, or `@convention(c)`
  functions, that move to the main actor themselves. A closure written in main-actor code is isolated to the main
  actor, and when a framework that does not mark the closure `Sendable` calls it on another queue, Swift 6 stops the
  app at its actor check (`dispatch_assert_queue`). `.receive(on: DispatchQueue.main)` before `.sink` keeps a Combine
  subscriber on the main queue.
- **`async` delegate methods that Objective-C calls with a completion handler** run where their isolation says, and
  Swift calls the system's completion handler from there when the method returns. `@concurrent` or `nonisolated`
  means a thread of the cooperative pool: wrong for a handler the SDK requires on the main thread. Opening a
  notification (`userNotificationCenter(_:didReceive:)`) is one: UIKit updates the app's snapshot in its completion
  handler and aborts the app off the main thread (it crashed Fluxo on every opened reminder, launched from it or not).
  So `ReminderNotificationDelegate` is a main-actor class, and only its `willPresent` answer, which may run anywhere,
  is `@concurrent`. `Tools/Simulator/notification-tests.sh` opens real notifications to check it.
- **`@unchecked Sendable`** only with a comment that says what makes the type safe (a lock, a single owning queue, a
  thread-safe class the SDK does not mark `Sendable`); `nonisolated(unsafe)` and `@preconcurrency` likewise. The app
  has no `@preconcurrency` import.
- The tools that compile app sources with `swiftc` (`Tools/*Check`, the benchmarks, `VODCheck`) use the same language
  settings: `Tools/swift-language.sh`, which follows these build settings.

## FFmpeg

`Vendor/FFmpeg/FFmpeg.xcframework` is a minimal FFmpeg 9.0.2 built from the official release
tarball by `Tools/FFmpeg/build-xcframework.sh` (pinned version and SHA-256, plus the release
signature when `gpg` is installed). It contains one dynamic framework, `FFmpeg.framework`,
with libavformat, libavcodec, libswscale, libswresample and libavutil linked into a single library that exports
only the public API (`av_*`, `avio_*`, `avcodec_*`, `avformat_*`, `avutil_*`, `avsubtitle_*`, `swr_*`, `sws_*`; no
internal `avpriv_*` / `ff_*` symbols), for iOS (arm64), the iOS Simulator (arm64, x86_64), macOS
(arm64, x86_64: macOS 26 still runs on Intel Macs, and Xcode builds universal Release apps), tvOS (arm64) and the
tvOS Simulator (arm64, x86_64), with the same components and configure flags on every platform.
The public headers are in `Vendor/FFmpeg/include`, and `Vendor/FFmpeg/BUILD_INFO.txt` lists the
exact configuration. The iOS slice is about 8 MB. The slices are built for iOS 27.0, macOS 26.0 and tvOS 26.0
(`IOS_MIN`, `MACOS_MIN`, `TVOS_MIN` in the script, the app's deployment targets). Every framework carries a privacy
manifest (`PrivacyInfo.xcprivacy`: FFmpeg reads file metadata with `fstat` / `lstat`, declared as `C617.1`, files in
the app's container), which the script writes, and the LGPL text (`LICENSE`).

**Debug symbols.** The libraries are compiled with `-g` (`--enable-debug`, which leaves the generated code unchanged),
and the script makes the dSYM of each platform's framework (`dsymutil`, every architecture, the UUIDs checked against
the binary), then strips the debug information from the binary. `xcodebuild -create-xcframework -debug-symbols` puts
each dSYM next to its library (`FFmpeg.xcframework/<library>/dSYMs/FFmpeg.framework.dSYM`, 30 to 40 MB per
platform), so an archive of the app includes it and the FFmpeg frames of crash reports (Xcode's Organizer, the
diagnostic reports of [Diagnostics](diagnostics.md)) are symbolicated. The objects are linked from uniquely named
copies of the static libraries' members (several share a base name, such as `parser.o`, which leaves dsymutil
unable to tell them apart), and the build paths in the debug information are mapped to fixed ones
(`/ffmpeg-<version>`, `/ffmpeg-build`). A platform kept from an earlier build keeps the dSYM it had; one built before
the dSYMs has none, and `BUILD_INFO.txt` says so: rebuild every slice once (`Tools/FFmpeg/build-xcframework.sh`) to
get them all.

- **What is in it**: everything is disabled except what the engine reaches:
  - demuxers: MPEG-TS (and M2TS), HLS, MP4 / MOV / 3GP, FLV, Matroska / WebM, AVI, ASF (WMV), Ogg, MPEG-PS (VOB),
    WAV, RTSP/RTP and elementary audio/video, and WebVTT (the HLS demuxer probes the subtitle renditions of a master
    playlist and fails without it);
  - the MPEG-TS and MP4 muxers; the file, HTTP(S), TCP, TLS, UDP, RTP, RTMP(S/T) and AES (`crypto`) protocols;
  - parsers and the bitstream filters the muxers insert (`aac_adtstoasc`, `h264_mp4toannexb`, `hevc_mp4toannexb`,
    `extract_extradata`);
  - decoders: the ones `avformat_find_stream_info` uses to read stream parameters (H.264, HEVC, AAC, AC-3, E-AC-3,
    MP3, and the MP2 audio and MPEG-2 video of DVB-derived channels; without a decoder a live input waits out the
    whole 3 s probe), and the ones the converter decodes (see [Formats](player.md#formats)): MPEG-1 / MPEG-2, MPEG-4 Part 2 and
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
  library; the license text is in `Vendor/FFmpeg/LICENSE` and inside the framework, FFmpeg's license overview in
  `Vendor/FFmpeg/LICENSE.md`. **Source offer**: the exact release tarball the frameworks are built from is in the
  repository (`Vendor/FFmpeg/source/ffmpeg-9.0.2.tar.xz`; the script uses it instead of downloading, and checks
  its SHA-256), next to this build script; Settings › About › Acknowledgements shows the LGPL notice and text and
  links to both (see [License](license-and-privacy.md)). Keep each tarball that shipped available for at least three years.
- **Rebuild** (about 10 minutes; Xcode only, no Homebrew packages): `Tools/FFmpeg/build-xcframework.sh`.
  `SLICES` builds a subset, e.g. `SLICES="tvos-arm64 tvossim-arm64 tvossim-x86_64"` (a platform is always built
  with all its architectures): the platforms left out are copied unchanged from the current xcframework, so their
  binaries stay byte for byte the same (`BUILD_INFO.txt` lists them). The tvOS slices were added that way.
  `OUT=<a copy of Vendor/FFmpeg>` writes the result there instead, to try a build without touching the repository.
  To add a component, add it to the lists at the top of the script, rebuild and run
  `Tools/FFmpeg/check.sh`, which checks the version, the license and the components, and opens
  any URLs passed to it (`Tools/FFmpeg/check.sh https://…` checks HTTPS).
