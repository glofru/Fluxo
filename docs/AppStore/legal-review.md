# Legal review before a paid or public release

Decisions taken in the code, and the questions left for a lawyer. Nothing here is legal advice.

## 1. FFmpeg and the LGPL v2.1 on the App Store

What Fluxo does to meet the LGPL (section 6):

- FFmpeg 9.0.2 is built **without** any GPL, version-3 or non-free component (`Tools/FFmpeg/check.sh` checks the
  license string of the binary: "LGPL version 2.1 or later").
- It is linked **dynamically**, as a separate framework (`Fluxo.app/Frameworks/FFmpeg.framework`), with only the
  public API exported, so it can be replaced by a modified build of the same library.
- **Notice and license text**: Settings › About › Acknowledgements, on every platform, shows the LGPL notice and its
  full text, FFmpeg's own license overview (`LICENSE.md`) and the credit of the Independent JPEG Group, whose DCT
  code (`libavcodec/jrevdct.c`, `jfdctfst.c`, `jfdctint_template.c`) this build contains (its license asks binaries
  to say "this software is based in part on the work of the Independent JPEG Group"); the LGPL text is also inside
  every `FFmpeg.framework` (`LICENSE`).
- **Google Cast SDK** (iPhone and iPad): the SDK and its Google Sans fonts are under the Google Cast SDK terms; the
  open-source software inside it (Abseil, gRPC, Protocol Buffers, Eigen, Material Components for iOS, Kiss FFT,
  SimplePing, the tz database and others: Apache 2.0, BSD, MPL 1.1 and 2.0, Apple's sample code license, public
  domain) is listed on its Acknowledgements page with Google's notice of each part, copied from the SDK's
  `OpenSourceLicenses` folder by `Tools/Legal/extract-googlecast-licenses.sh`. **Open question:** the MPL parts (Eigen
  and parts of gRPC under MPL 2.0, parts of `proto` under MPL 1.1) ask whoever distributes them in executable form to
  tell recipients where their source code is. Eigen's notice gives its address (eigen.googlesource.com); the others
  are public (github.com/grpc/grpc, chromium.googlesource.com) but Google's notices don't say so. Ask whether
  Google's notices are enough or whether the app should add those addresses.
- **Source offer**: the exact release tarball (`Vendor/FFmpeg/source/ffmpeg-9.0.2.tar.xz`, SHA-256 in
  `Vendor/FFmpeg/BUILD_INFO.txt`), the build script (`Tools/FFmpeg/build-xcframework.sh`) and the configure flags are
  in the public repository, which Acknowledgements links to (on Apple TV with a QR code). Keep every tarball that
  shipped in a release in the repository (or on another host you control) for **at least three years** after the
  last release that includes it, and tag each release (`git tag v1.0`) so the matching script can be found.
- **EULA**: the custom EULA (`eula.md`) excludes the LGPL parts and allows modification and reverse engineering
  for debugging them; Apple's standard EULA would not.

**Open question:** an App Store app can only be re-signed by its developer, so an end user cannot actually run the
app with a replaced `FFmpeg.framework` on an iPhone, iPad or Apple TV (they can on a Mac, after re-signing). Some
companies ship LGPL libraries on the App Store with exactly this setup plus the full source of the app (Fluxo's code
is public under MIT, so a user can rebuild the whole app with a modified FFmpeg); others consider it insufficient.
Get a lawyer's sign-off.

## 2. Patent licensing of codecs (report item L10)

Fluxo decodes most mainstream formats through Apple's frameworks (H.264, HEVC, AAC, AC-3, E-AC-3 and MP3 playback
by AVFoundation and VideoToolbox, which Apple licenses). Its own FFmpeg build adds **software** decoders and one
encoder that the operating system does not license for the app:

| Codec | In FFmpeg | Used for | Patent status (to confirm) |
|---|---|---|---|
| AAC encoder | `aac` | Converting audio AVPlayer cannot decode (DTS, TrueHD, FLAC, Opus…) to AAC | AAC is a Via LA pool; encoders in consumer products are usually licensable |
| MPEG-2 video | `mpeg2video`, `mpeg1video` | Stream probing; converting DVB channels | Most MPEG-2 patents have expired worldwide (last ones in 2020) |
| MPEG-4 Part 2 (Xvid, DivX) | `mpeg4`, `msmpeg4v1/2/3`, `h263`, `h263p`, `flv` | Converting old movie files | Via LA (MPEG-4 Visual) pool; some patents may still be in force in some countries |
| VC-1 / WMV 7-9 | `vc1`, `wmv1/2/3` | Converting Windows Media files | Via LA (VC-1) pool |
| E-AC-3, AC-3 | `eac3`, `ac3` | Stream probing (decoding to read parameters); playback is by the OS | AC-3 patents expired; E-AC-3 (Dolby) may need a license for decoding |
| Dolby TrueHD / MLP | `truehd`, `mlp` | Converting to AAC | Dolby |
| DTS | `dca` | Converting to AAC | DTS / Xperi |
| H.264, HEVC | `h264`, `hevc` | Stream probing; H.264 profiles the hardware cannot decode | Via LA / Access Advance pools |

Options, from least to most change:

1. Keep everything, after a lawyer confirms the risk is acceptable for a free (or paid) app in the target
   countries. Many open-source players ship the same decoders.
2. Drop the decoders that are rarely needed in IPTV (VC-1 / WMV, MPEG-4 Part 2, TrueHD, DTS): remove them from
   `DECODERS` in `Tools/FFmpeg/build-xcframework.sh`, rebuild, and accept that those files show "Unsupported video
   format" / "Unsupported audio format". The probing decoders (H.264, HEVC, AAC, AC-3, E-AC-3, MPEG-2) are needed by
   live IPTV.
3. Replace the AAC encoder by Apple's (AudioToolbox `AudioConverter`), which Apple licenses.

Nothing was removed in this release: the formats are documented features (README › Formats), and dropping them is a
product decision that should follow the legal answer.

## 3. Built-in TV guide (report item M5): removed

Add Guide Source used to offer "Use Free Guide for <country>", pointing at epgshare01's `epg_ripper_<XX>.xml.gz`
files: TV listings scraped from broadcasters' sites (made with WebGrab+Plus) for 66 countries, published without a
license that allows redistribution or use in an app. Shipping those URLs in the app would make the developer the
one pointing users at them, send every user's IP address to a third party, and leave no way to change them without an
update. **Decision: removed.** Guides now come only from the user's playlists (`url-tvg`, `x-tvg-url`) and from
addresses the user types (Settings › TV Guide › Add Guide Source). Sources a user added earlier, epgshare01 included,
stay: they are the user's choice. (`Tools/GuideCheck` still downloads two epgshare01 files as test samples on the
developer's Mac; nothing of it ships.)

## 4. Content and App Review guideline 5.2

See `review-notes.md`: no content in the app, the "Fluxo provides no content" notice, a demo playlist of
Creative Commons and public test streams only, and recordings and downloads that cannot leave the app.

## 5. Trademarks in the app and the screenshots

- App Store screenshots must use the `store` seed of the Debug harness (`-FluxoDebugSeed store`,
  `Tools/Simulator/run.sh --seed store`): invented channel names and logos, invented film and series titles. The
  `sample` seed keeps real broadcaster names for the harness's checks (name matching, Siri phrases) and must not
  appear in marketing material.
- The Siri phrase examples in Settings name real channels ("Play Rai 1 in Fluxo", localized per language) as an
  example of what to say. This is a descriptive (nominative) use; replace them with a generic example if a lawyer
  prefers.
- "Chromecast" and "Google Cast" are Google trademarks, used to describe compatibility, as Google's Cast branding
  guidelines allow.
