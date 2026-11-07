# Diagnostics

How crashes, hangs and performance problems of a shipped build can be looked into without any analytics: the
reports MetricKit gives the app, kept on the device until the user shares them, and debug symbols for every binary,
FFmpeg included.

## Diagnostic reports on the device

`Fluxo/App/Diagnostics` (iPhone, iPad and Mac; Apple TV has no MetricKit):

- **`DiagnosticsCollector`** receives what MetricKit delivers: the diagnostic reports (crashes, hangs, CPU, disk-write
  and memory exceptions, slow launches) and the daily metric reports. iOS 27 and macOS 27 use the Swift
  `MetricManager` (`diagnosticReports`, `metricReports`; the reports are `Codable` and stored as MetricKit encodes
  them); macOS 26 uses `MXMetricManager` and the payloads' `jsonRepresentation()`. It starts at launch
  (`FluxoApp.init`) while the setting is on.
- **`DiagnosticReportStore`** keeps them in `Application Support/Diagnostics` (excluded from backups, file protection
  until the first unlock), one file per report named `<received, Unix ms>-<kind>-<id>.json`, as a ring buffer: at
  most 40 reports and 8 MB, none older than 90 days, the oldest dropped first. It reads no file timestamps (the
  order is in the names), so it needs no privacy-manifest reason.
- **Settings › About › Diagnostic Reports** (`DiagnosticReportsView`) lists them (kind and date), with **Share
  Reports…** (one JSON file, `Fluxo Diagnostics <date>.json`: the app version and every report unchanged, through
  the share sheet to wherever the user picks), **Delete All Reports**, and the **Keep Diagnostic Reports** switch
  (on by default; turned off, collecting stops and the kept reports are deleted).

Privacy: the system creates these reports only for people who share analytics with app developers (Settings ›
Privacy & Security › Analytics & Improvements), and delivers them on its own schedule (diagnostics at the next
launch, metrics about once a day). They hold the app and system versions, the device model, the region format and
call stacks (code addresses and binary names); Fluxo adds nothing to them, and the app has no signposts that could
carry a channel or playlist name. The app never sends them anywhere: no network code touches them, there is no crash
or analytics service. They leave the device only when the user shares the file. That is why the App Privacy answers
(`docs/AppStore/app-privacy.md`) declare no data collected for them, and why the privacy policy describes them under
"What stays on your device".

Reading a shared file: each element of `reports` has the `kind`, `receivedOn` and the `report` as MetricKit wrote it.
The call stack frames give a binary UUID and an offset into its text segment; symbolicate them with the dSYM of that
build (`atos -o <dSYM>/Contents/Resources/DWARF/<binary> -l <load address> <address>`, or the frames' offsets with
`atos -o … -offset`), from the archive (Organizer › Show in Finder › `dSYMs`).

The debug harness has a route for the screen: `diagnostics:sample` keeps one invented report of each kind (marked as
invented) and opens it, `diagnostics:clear` deletes them (see `Tools/Simulator/README.md`). The store's logic is
covered by `FluxoTests/DiagnosticReportStoreTests.swift`. MetricKit itself cannot be driven from a simulator: Xcode's
Debug › Simulate MetricKit Payloads on a device delivers sample reports to a running build.

## Debug symbols

- **The app and the Top Shelf extension**: Release builds `dwarf-with-dsym`; the archive keeps the dSYMs.
- **FFmpeg**: `Tools/FFmpeg/build-xcframework.sh` makes a dSYM for each platform's framework and puts it in the
  xcframework (`FFmpeg.xcframework/<library>/dSYMs/FFmpeg.framework.dSYM`), so Xcode copies it into each archive
  (see "Debug symbols" under [FFmpeg](building.md#ffmpeg) for how). The binaries are stripped of their debug
  information, so the app is no larger.

The xcframework in the repository was built before the script made dSYMs: its `BUILD_INFO.txt` lists no debug
symbols. The next full rebuild (`Tools/FFmpeg/build-xcframework.sh`, about 10 minutes, every slice) adds them, about
30 to 40 MB per platform (150 to 200 MB for the five). Before committing that, decide where they live: in the
repository as they are (simplest; every archive is then symbolicated wherever it is made), or with Git LFS for
`Vendor/FFmpeg/FFmpeg.xcframework/*/dSYMs/**` (keeps clones small). A platform left out of a partial rebuild
(`SLICES=…`) keeps the dSYM it had.
