# App Privacy (App Store Connect answers)

The answers for App Store Connect › App Privacy, with the reasons. They match the privacy manifests in the build
(`Fluxo/PrivacyInfo.xcprivacy`, `FluxoTopShelf/PrivacyInfo.xcprivacy`, each `FFmpeg.framework` slice, and the
manifests Google ships in `GoogleCast.framework` and the GTMSessionFetcher bundles) and the privacy policy
(`docs/privacy.md`).

**Privacy Policy URL:** `https://glofru.github.io/Fluxo/privacy.html` once GitHub Pages publishes the `docs/` folder
of `main` (Settings › Pages › Deploy from a branch › `main` / `docs`); until then
`https://github.com/glofru/Fluxo/blob/main/docs/privacy.md`, which the app links to in Settings › About.

## Data collection

**Do you or your third-party partners collect data from this app?** Yes: only the Google Cast SDK (iPhone and iPad).
Fluxo's own code collects nothing; the developer has no server.

Declare these three types. For each: **Not linked to the user**, **Not used for tracking**, purposes **Analytics**
and **App Functionality** (as in Google's manifest):

| Data type (App Store Connect) | Why |
|---|---|
| Identifiers › **Device ID** | `NSPrivacyCollectedDataTypeDeviceID` in GoogleCast.framework/PrivacyInfo.xcprivacy |
| Diagnostics › **Other Diagnostic Data** | `NSPrivacyCollectedDataTypeOtherDiagnosticData` in the same manifest |
| Usage Data › **Product Interaction** | `NSPrivacyCollectedDataTypeProductInteraction` in the same manifest |

Fluxo sets `disableAnalyticsLogging = true` (`GoogleCastBackend.swift`) and starts discovery only when the user
opens the Cast picker, but App Store Connect asks what *may* be collected, and Google declares these types
regardless, so they are declared.

Not collected (do not declare):

- **Contact info, health, financial info, location, sensitive info, contacts, user content, browsing history,
  search history, purchases**: nothing leaves the device for the developer or a partner.
- **Playlists, stream addresses and credentials**: they go only to the user's own providers, to the user's private
  iCloud database (iCloud sync, end-to-end encrypted with Advanced Data Protection), and to the user's Chromecast
  when casting. Apple's definition of "collect" is transmitting data off the device in a way that the developer or
  a third-party partner can access for longer than needed to service the request; the user's providers are not
  partners of the app, the private CloudKit database is not readable by the developer, and the Chromecast receiver
  only plays what it is given.
- **Recommendations, smart search, programme summaries**: computed on the device.

Fluxo is one App Store record for iPhone, iPad, Mac and Apple TV (one bundle ID, universal purchase), and App Privacy
answers belong to the record: they must cover the iPhone and iPad build, the only one with the Cast SDK. The Mac and
Apple TV builds collect nothing.

## Tracking

**Does this app track?** No. `NSPrivacyTracking = false` in every manifest, no tracking domains, no IDFA, no App
Tracking Transparency prompt.

## Required-reason APIs (privacy manifests)

| API category | Reason | Where |
|---|---|---|
| User defaults | `CA92.1` (the app's own settings) | `@AppStorage` and `UserDefaults` throughout the app |
| File timestamp | `C617.1` (files in the app's container) | `RecordingStore` (creation dates of recordings), `ExternalSubtitles` (the subtitle cache), `SimulatedCloud` (Debug); FFmpeg's `fstat` / `lstat` on segments, recordings and downloads |
| Disk space | `E174.1` (check before writing), `85F4.1` (shown to the user) | `PlatformStorage.availableCapacity`: before a recording, a download and the time-shift buffer, and "41 GB free" in Downloads |

The Top Shelf extension calls none of these APIs; its manifest declares nothing. `ITSAppUsesNonExemptEncryption`
is in `export-compliance.md`.

## Checking the archive

1. Product › Archive (scheme Fluxo, any iOS device; then again for tvOS and macOS).
2. Organizer › select the archive › **Generate Privacy Report** (right click). The PDF must list Fluxo, FFmpeg,
   GoogleCast and GTMSessionFetcher (iOS), Fluxo, FluxoTopShelf and FFmpeg (tvOS), Fluxo and FFmpeg (macOS), with the
   reasons above and no missing-manifest warnings.
3. Without an archive, the manifests of a build can be listed with
   `find <Fluxo.app> -name PrivacyInfo.xcprivacy -exec plutil -p {} \;`.
