# App Store submission

Everything App Store Connect asks for, and the checks to run before each upload. Fluxo is one App Store record for
iPhone, iPad, Mac and Apple TV (bundle ID `dev.watermelon.Fluxo`, universal purchase).

| File | For |
|---|---|
| [`review-notes.md`](review-notes.md) | App Review Information › Notes, the demo playlist, ATS and guideline 5.2 |
| [`app-privacy.md`](app-privacy.md) | App Privacy answers, privacy manifests, Privacy Policy URL |
| [`eula.md`](eula.md) | The custom License Agreement that excludes the LGPL parts |
| [`export-compliance.md`](export-compliance.md) | Why `ITSAppUsesNonExemptEncryption` is NO |
| [`legal-review.md`](legal-review.md) | LGPL on the App Store, codec patents, the removed built-in guide, trademarks |
| [`../privacy.md`](../privacy.md) | The privacy policy (GitHub Pages) |
| [`../demo/`](../demo/) | The demo playlist and the licenses of its content |

## Before each upload

1. **Build number**: `Tools/Release/set-build-number.sh` (the commit count) or `Tools/Release/set-build-number.sh
   <n>`, or `CURRENT_PROJECT_VERSION=<n>` on the CI's `xcodebuild archive`. The app and the Top Shelf extension take
   it from the project, so they always match (App Store Connect requires it).
2. **Acknowledgements**: `Tools/Legal/check-acknowledgements.sh <derivedDataPath>/SourcePackages` (versions of the
   packages and of FFmpeg, the source tarball, the license texts, and the notices of the open-source software inside
   the Google Cast SDK). After a Cast SDK update, build the iOS app once and run
   `Tools/Legal/extract-googlecast-licenses.sh <derivedDataPath>/SourcePackages` first.
3. **Demo playlist**: every stream of `docs/demo/fluxo-demo.m3u` still plays (`docs/demo/README.md`).
4. **Archive** each platform (scheme Fluxo, Archive uses Release) and **Generate Privacy Report** in the Organizer
   (`app-privacy.md`). It has not been generated yet: do it on the first archive, and check that it lists the
   manifests of the app, the Top Shelf extension, every `FFmpeg.framework`, GoogleCast and GTMSessionFetcher (iOS),
   with the reasons of `Fluxo/PrivacyInfo.xcprivacy`.
5. **macOS**: Release is signed automatically by team `4MJXMYZ3D9` with the hardened runtime and library validation
   on (`Fluxo/Fluxo-macOS.entitlements`; the ad hoc Debug build uses `Fluxo-macOS-Debug.entitlements`). After
   exporting: `codesign --verify --strict --deep --verbose=2 Fluxo.app` and, for Developer ID, `spctl -a -vv Fluxo.app`.
   The Mac build has no iCloud container yet (`FLUXO_CLOUDKIT_CONTAINER[sdk=macosx*]` is empty): add the iCloud
   capability to the macOS entitlements before turning sync on there.
6. **Tag the release** (`git tag v1.0 && git push --tags`): the LGPL source offer points at the repository, and the
   tag keeps the exact FFmpeg tarball and build script of each version findable.

## App Store Connect fields

- **Category**: Entertainment (`LSApplicationCategoryType = public.app-category.entertainment`, needed by the Mac
  App Store).
- **Age rating**: the app shows only what the user adds; answer the content questions with "None" and set
  "Unrestricted Web Access" to No (there is no browser). Apple may still rate a user-supplied-content player 17+.
- **Privacy Policy URL**, **App Privacy**: `app-privacy.md`.
- **License Agreement**: Custom, `eula.md`.
- **Support URL**: `https://github.com/glofru/Fluxo/issues`.
- **Screenshots**: Debug harness with `--seed store` only (invented channels and titles; `legal-review.md` §5).
