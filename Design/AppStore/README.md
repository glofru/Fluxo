# App Store screenshots

The screenshots of Fluxo's App Store page, for iPhone, iPad, Mac and Apple TV, in English (`en-US`) and Italian (`it`).
Every screenshot is a real screen of the app, captured in a simulator (the Mac app on the Mac) with the Debug harness,
then laid out with FigCraft: a headline, the device and a few glass labels on the brand's night gradient, with the
icon's three streams flowing from one screenshot into the next.

| Folder | Size (App Store Connect) | Screenshots |
|---|---|---|
| `iPhone/<locale>/` | 1320 × 2868 (6.9" display; scaled down for the smaller iPhones) | 10 |
| `iPad/<locale>/` | 2064 × 2752 (13" display; scaled down for the smaller iPads) | 9 |
| `Mac/<locale>/` | 2880 × 1800 (16:10) | 9 |
| `AppleTV/<locale>/` | 3840 × 2160 | 8 |

Sizes as App Store Connect's "Screenshot specifications" listed them in November 2026: iPhone 6.9" 1320 × 2868 (also
1290 × 2796 and 1260 × 2736), iPad 13" 2064 × 2752 (or 2048 × 2732), Mac 2880 × 1800 (or 2560 × 1600, 1440 × 900,
1280 × 800), Apple TV 3840 × 2160 (or 1920 × 1080); up to 10 per display size, PNG or JPEG, no transparency. The exports
are opaque PNGs (`compose.py` checks their size and removes any transparency chunk); upload them in their numeric order.
Each folder also has the design source, `Fluxo-<platform>-<language>.figcraft`: one frame per screenshot, the captures
embedded at the size the screenshots show them.

## The story

| # | iPhone | iPad | Mac | Apple TV |
|---|---|---|---|---|
| 1 | All your TV. One beautiful app. (Home) | the same | the same | the same (made for the Siri Remote) |
| 2 | Live TV with a real TV guide (Guide, For You Tonight) | the same | the same | the same |
| 3 | Pick up right where you left off (a series, Resume) | the same | the same | the same |
| 4 | Record live TV. Watch offline. (Library: downloading, downloads, recordings) | the same | Recordings, with the Downloads page on a callout over the room the page leaves (two pages of the Mac's sidebar) | Everything you watch, front and center (Home rows, Top Shelf) |
| 5 | Fluxo Intelligence: Just say what you feel like watching (Smart Results of "sports tonight") | the same | the same | Smart search (built-in rules; Apple TV has no Apple Intelligence) |
| 6 | Every stream, beautifully played (the player, landscape; the formats) | The big picture, with the guide beside it | the player | the player's info panel |
| 7 | Just ask Siri (What's On, run from Fluxo's App Shortcuts; in English with more phrases to say) | — | Just ask Siri (Settings › Siri & Shortcuts) | Siri and voice search |
| 8 | From your hand to the big screen: Chromecast · AirPlay (the Cast sheet, casting to a TV) | the same (the device picker) | Privacy first: Everything stays on your Mac (Settings › About: Diagnostic Reports, Privacy Policy) | Private. Open source. (Acknowledgements: MIT, the source code, no content provided) |
| 9 | Privacy first: Everything stays on your device (What's Synced and Privacy) | the same | Open source. MIT licensed. (Acknowledgements) | |
| 10 | Open source. MIT licensed. (Acknowledgements) | the same | | |

The Mac has no Cast (8 on iPhone and iPad), so its set has 9. The iPad has no Siri screenshot (its Shortcuts app has
another layout); Apple TV tells privacy and open source on one screenshot, as its 8.

The words are in `copy.json` (per platform; iPad and Mac derive from iPhone with overrides). Rules they follow:

- Only what the app does on that platform: no Apple Intelligence claim on Apple TV, no Cast on the Mac, and no iCloud
  sync on the Mac (its build has no iCloud container yet, `docs/AppStore/README.md`), so the Mac's privacy slide
  shows Settings › About (Diagnostic Reports, which stay on the Mac, and the Privacy Policy) instead of the iCloud
  sheet, and its words are about the account, tracking and on-device intelligence.
- "No account, no tracking, no ads" as the privacy policy (`docs/privacy.md`) states it.
- No third-party brand in a label, a capture or a keyword (Chromecast and AirPlay only as compatibility, as the legal
  review allows; `docs/AppStore/legal-review.md` §5).

## What is in the pictures

Only invented content: the harness's `store` seed (`Tools/Simulator/run.sh --seed store`: invented channels, logos,
films and series) with the sample TV guide. Its posters are original scenes drawn in code for each genre
(`DebugArtwork.scenePoster`), and the video in the player is "Dusk", an original vector landscape drawn with FigCraft
(`Scripts/dusk_footage.py`). Every capture was looked at for real channel names, brands and artwork; the Apple TV Siri
screen is captured scrolled to its generic phrases, because its first example names a real channel ("Play Rai 1 in
Fluxo"). The Cast screens use the harness's simulated receivers, with generic models (Smart TV, Streaming Stick, Smart
Speaker) instead of product names. Status bars show 9:41 with full signal and battery (`simctl status_bar`; the iPad
also shows a date). The Siri screenshot is the system's Shortcuts app running Fluxo's What's On.

Text is set in Inter (built into FigCraft, SIL Open Font License 1.1; the exports contain the rendered text only). The
Mac's menu bar (Fluxo's menus and a clock) is drawn by `mac_desktop.swift` with the system font.

## Why FigCraft (and not VectorCraft)

Both are open-source Rust apps of the ArtCraft family, installed in `/Applications`, with the same automation model:
one command registry behind the UI, a headless CLI that runs command scripts, an MCP server, and a JSON-lines control
channel that binds 127.0.0.1 only (`--control <port>`).

- **VectorCraft** (0.22) is an illustration tool (Illustrator-like): pen and Bézier editing, Pathfinder, blends, gradient
  mesh, 3D revolve, artboards. It is the right tool for vector artwork, and Fluxo's icon master is made with it
  (`Design/Icon`).
- **FigCraft** (0.16) is an interface design tool (Figma-like): frames at exact pixel sizes, auto layout with wrapping,
  text styles, image fills (fill, fit, crop), drop shadows, background blur and a **glass** effect (refraction,
  dispersion, frost, light), and per-frame export at any scale. A marketing screenshot is exactly that kind of layout:
  a frame of a fixed size, text blocks, an image of the app inside a device, glass labels. The glass effect gives the
  Liquid Glass look of the app itself, and auto layout lays out the labels in either language without measuring them.

FigCraft also scripts better for this job: `figcraft-cli run` applies a whole script as one undoable, all-or-nothing
step (a failed command rolls everything back and names the step), and `figcraft-cli export` writes one PNG per frame,
so a set of screenshots is one document and one command. No control channel or MCP server is used: the CLI runs
headless, so nothing listens on any port. (To edit a document interactively with an agent instead, start the app with
`--control <port>`, which only binds 127.0.0.1, or run `figcraft-cli mcp --attach <port>`.)

`figcraft-cli` is not inside the app: it is the `figcraft-cli-<version>-macos-universal.zip` asset of the FigCraft
release (github.com/storytold/figcraft). These screenshots were made with 0.16.0, the version of the installed app; the
archive's SHA-256 matched the release's `SHA256SUMS.txt`, and the binary is notarized with the same Developer ID as
FigCraft.app.

## Making them again

Everything runs on the Mac, one step at a time (one `xcodebuild`, one booted simulator). Captures go to a folder of
your own, e.g. `/tmp/fluxo-shots/appstore`.

```sh
export FIGCRAFT_CLI=/path/to/figcraft-cli
Design/AppStore/Scripts/demo-footage.sh start          # Dusk, served on 127.0.0.1:18960 only

# iPhone (an iPhone 17 Pro Max of your own) and iPad (a clone of the iPad Pro 13-inch (M5)), dark appearance.
Tools/Simulator/build.sh
xcrun simctl create fluxo-appstore-iphone com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max \
    com.apple.CoreSimulator.SimRuntime.iOS-27-2
Design/AppStore/Scripts/capture.sh iphone fluxo-appstore-iphone en /tmp/fluxo-shots/appstore/iphone-en
Design/AppStore/Scripts/capture.sh iphone fluxo-appstore-iphone it /tmp/fluxo-shots/appstore/iphone-it
Tools/Simulator/run.sh --device "iPad Pro 13-inch (M5)" --clone fluxo-appstore-ipad --seed store --keep
Design/AppStore/Scripts/capture.sh ipad fluxo-appstore-ipad en /tmp/fluxo-shots/appstore/ipad-en
Design/AppStore/Scripts/capture.sh ipad fluxo-appstore-ipad it /tmp/fluxo-shots/appstore/ipad-it

# Apple TV.
Tools/Simulator/build.sh --platform tvos
Tools/Simulator/run.sh --device "Apple TV 4K (4th generation)" --clone fluxo-appstore-tv --seed store --keep
Design/AppStore/Scripts/capture.sh tv fluxo-appstore-tv en /tmp/fluxo-shots/appstore/tv-en
Design/AppStore/Scripts/capture.sh tv fluxo-appstore-tv it /tmp/fluxo-shots/appstore/tv-it

# Mac: the Debug app, ad hoc signed (the build command is in capture-mac.sh). Quit any other Fluxo first, unlock the
# screen and leave the Mac alone. FLUXO_MAC_TZ: a time zone where it is evening (the guide's and Search's times).
FLUXO_MAC_TZ=Etc/GMT+12 Design/AppStore/Scripts/capture-mac.sh en /tmp/fluxo-shots/appstore/mac-en
FLUXO_MAC_TZ=Etc/GMT+12 Design/AppStore/Scripts/capture-mac.sh it /tmp/fluxo-shots/appstore/mac-it

Design/AppStore/Scripts/compose-all.sh /tmp/fluxo-shots/appstore    # or: compose-all.sh <folder> iphone
Design/AppStore/Scripts/demo-footage.sh stop
Tools/Simulator/cleanup.sh fluxo-appstore-
```

Then look at every export. Details of the captures:

- **One launch per screen**, with an in-memory `store` library and the routes of `capture.sh` (seed the guide, half
  watch Orbit S01E02 and Crimson Signal, pin the featured rotation whose first page is The Lantern Protocol).
- **Library**: the two films download from the footage server, the second one through its throttle (`/slow/40000/`),
  so it can be paused at 40 % ("Downloading").
- **iPad player**: the gesture tests turn the device (`testLayoutScreenshots` with
  `TEST_RUNNER_FLUXO_LAYOUT_KEEP_ORIENTATION=1`) and turn it back.
- **Cast**: the iPhone's sheet casting to Living Room TV (`cast:Living Room`); the iPad's form sheet shows the device
  picker instead, because casting the demo footage, which is on 127.0.0.1, makes the player say (rightly) that a
  Chromecast can't reach it, and the iPad's sheet leaves that note visible. The iPad's form sheet is half empty under
  its device list, so that screenshot uses the `rise` layout too: the bottom edge cuts it under the list, before its
  footnote.
- **Siri** (iPhone): `siri-tests.sh` with `FLUXO_SEED=store` runs `testWhatsOnResultScreenshot`, which opens Fluxo's
  App Shortcuts in the Shortcuts app and runs What's On. The Shortcuts app follows the simulator's language, so set it
  first for Italian and back afterwards (then reboot the clone), and set the status bar again after the reboot:
  `xcrun simctl spawn <udid> defaults write "Apple Global Domain" AppleLanguages -array it` (and `AppleLocale it_IT`).
  An Italian system shows the status bar's 9:41 as "09:41" (the 24-hour format), and the other Italian screenshots,
  whose system stays in English, show "9:41": turn 24-hour time off as well (`defaults write "Apple Global Domain"
  AppleICUForce12HourTime -bool true`; `defaults delete` afterwards), which shows "9:41" with no AM or PM.
  On the iOS 27.2 Simulator What's On's answer stays in English (the system's Done button too) in another language, so
  the Italian screenshot shows Fluxo's App Shortcuts instead. The speech bubble's place is per language
  (`bubble_at` in `copy.json`). In English the answer fills only the top of the screen: that screenshot uses the
  `rise` layout, the iPhone larger and rising from the bottom edge, which cuts the screen just under the answer's Done
  button (above the App Shortcuts card that shows under the answer's rounded corners), with the bubble and three more
  of Fluxo's App Shortcut phrases above it. In Italian the bubble is above the device, whose screen is full. The
  iPad's Shortcuts app has another layout, and the iPad set has no Siri screenshot.
- **Apple TV**: the screenshot after the last route step (`--step-shots`): bringing the app to the front for the final
  one closes the player's panel.
- **Mac**: the windows are captured one by one (`screencapture -o -l`) and laid out by `mac_desktop.swift` on the Dusk
  wallpaper under a menu bar. Before each capture the script brings Fluxo to the front, so its windows look active
  (coloured window buttons, accent selections): run it with the screen unlocked and leave the Mac alone meanwhile.
  With the screen locked Fluxo cannot come to the front and the script stops (`FLUXO_MAC_ALLOW_INACTIVE=1` captures
  drafts anyway, with inactive windows). The main window is sized with the harness route `window-size` (1280 × 780,
  and 1280 × 620 for Search, which its results fill), which stops that window's frame from being saved (the debug
  app shares its container, and so its saved window frames, with a Fluxo you may use). The Mac shows Recordings and
  Downloads on two pages of its sidebar, so its fourth screenshot shows Recordings with the Downloads page, cropped,
  on a callout (`inset` in `copy.json`) over the empty part of the Recordings page, its label on the card. The Siri
  screenshot opens Settings scrolled to the second Siri phrase (`settings-section:siri-whats-on`): the first one's
  example names a real channel. The Settings window is then the key window, so the main window behind it looks
  inactive, as it would.

| File | Does |
|---|---|
| `copy.json` | The storyboard and the words, per platform and language |
| `Scripts/demo-footage.sh`, `dusk_footage.py` | The demo footage: live HLS and a 1 h 47 min film on 127.0.0.1 |
| `Scripts/capture.sh` | iPhone, iPad and Apple TV captures (simulators) |
| `Scripts/capture-mac.sh`, `mac_desktop.swift` | Mac captures (the Debug Mac app) |
| `Scripts/compose.py` | One FigCraft document and its exports for a platform and a language |
| `Scripts/compose-all.sh` | Every set, into the folders above |

The App Store texts (name, subtitle, promotional text, description, keywords) are in
[`docs/AppStore/listing.md`](../../docs/AppStore/listing.md).
