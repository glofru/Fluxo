# License, privacy and the App Store

**License.** Fluxo's own code is released under the [MIT License](../LICENSE), copyright Gianluca Lofrumento. The
software it includes keeps its own license:

| Component | License | Where |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) 9.0.2 (libavformat, libavcodec, libavutil, libswscale, libswresample) | LGPL v2.1 or later; its libjpeg DCT code is credited to the Independent JPEG Group as its license asks | `Vendor/FFmpeg` (source tarball in `Vendor/FFmpeg/source`, built by `Tools/FFmpeg/build-xcframework.sh`) |
| [FlyingFox](https://github.com/swhitty/FlyingFox) 0.24.1 | MIT | Swift package |
| [Google Cast SDK](https://developers.google.com/cast) 4.8.6 (iOS), including its Google Sans fonts | [Google Cast SDK terms](https://developers.google.com/cast/docs/terms) | `Vendor/GoogleCast`, a local Swift package of Google's `GoogleCast.xcframework` |
| The open-source software inside the Cast SDK: Abseil, gRPC, TCMalloc, Material Components for iOS and MDF*, Google Toolbox for Mac, Protocol Buffers, Kiss FFT, Eigen 3, SimplePing, the tz database and others (20 in Google's list) | Apache 2.0, BSD 3-Clause, MPL 2.0 and 1.1, Apple sample code license, public domain (each in `Fluxo/App/Legal/Licenses/GoogleCast-OSS.json`) | inside the Cast SDK |
| [GTMSessionFetcher](https://github.com/google/gtm-session-fetcher) (iOS, used by the Cast SDK) | Apache 2.0 | inside the Cast SDK (`GoogleCast.framework` has its own copy; the app links no other) |

Settings › About › Acknowledgements (`Fluxo/App/Legal`, every platform; focusable lines and QR codes on Apple TV)
lists them with their full license texts (bundled from `Fluxo/App/Legal/Licenses`, laid out to flow at any width by
`LicenseText`), the FFmpeg source offer of the LGPL (the SHA-256 of the tarball, links to it and to the build script)
and the note that FFmpeg is a replaceable library that the app's EULA does not cover. The Google Cast SDK's page
(iPhone and iPad) lists the open-source software inside the SDK, each with the notice Google ships in the SDK's
`OpenSourceLicenses` folder: `Tools/Legal/extract-googlecast-licenses.sh <derivedDataPath>/SourcePackages` copies
them to `GoogleCast-OSS.json` (bundled on iOS only, like the Apache text). `Tools/Legal/check-acknowledgements.sh
[<derivedDataPath>/SourcePackages]` checks that the versions there match `Package.resolved`, `Vendor/GoogleCast/Package.swift`
and `BUILD_INFO.txt`, that the bundled texts match their sources, and that `GoogleCast-OSS.json` is what that Cast SDK
ships.

**No content.** Fluxo provides no channels or content: the first-run screen, Add Playlist and Settings › About say
so (`ContentNotice`), and the built-in guide shortcut was removed. "Try the Demo Playlist" fills in
`docs/demo/fluxo-demo.m3u` (a live test stream, Apple's HLS example and three Creative Commons films of the
Blender Foundation; licenses in `docs/demo/README.md`).

**Privacy.** No account, server, analytics, ads or tracking. The crash and performance reports MetricKit gives the app
stay on the device (Settings › About › Diagnostic Reports, see [docs/diagnostics.md](diagnostics.md)). The privacy policy is `docs/privacy.md` (linked in
Settings › About). The privacy manifests: `Fluxo/PrivacyInfo.xcprivacy` (UserDefaults `CA92.1`, file timestamps
`C617.1`, disk space `E174.1` and `85F4.1`), `FluxoTopShelf/PrivacyInfo.xcprivacy` (nothing to declare) and one in
each `FFmpeg.framework`; the Cast SDK ships its own (in `GoogleCast.framework`, GTMSessionFetcher included). Add Playlist warns when an `http://`
address carries a user name or password. Multicast addresses (`udp://@239…`) fail at once on iPhone and iPad, which
need a multicast entitlement the app does not have.

**App Store.** `docs/AppStore/` has the App Review notes (content, ATS, how to test), the App Privacy answers, the
custom EULA, the export-compliance reasoning (`ITSAppUsesNonExemptEncryption = NO`), the legal review (LGPL on the
App Store, codec patents, trademarks) and the checklist before each upload. App Store screenshots use the Debug
harness's `store` seed (`Tools/Simulator/run.sh --seed store`), which has only invented channel names and titles.
