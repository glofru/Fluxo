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
  Reports…** (one JSON file, `Fluxo Diagnostics <date>.json`, its name translated: the app version and every report unchanged, through
  the share sheet to wherever the user picks), **Delete All Reports**, and the **Keep Diagnostic Reports** switch
  (on by default; turned off, collecting stops and the kept reports are deleted).

Privacy: the system creates these reports only for people who share analytics with app developers (Settings ›
Privacy & Security › Analytics & Improvements; on the Mac, System Settings, which the footer of the switch names
there), and delivers them on its own schedule (diagnostics at the next
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
  xcframework (`FFmpeg.xcframework/<library>/dSYMs/FFmpeg.framework.dSYM`, every slice), so Xcode copies it into each
  archive (see "Debug symbols" under [FFmpeg](building.md#ffmpeg) for how). The binaries are stripped of their debug
  information, so the app is no larger. The dSYMs are committed with the xcframework (no Git LFS), so an archive made
  from any clone is symbolicated. FFmpeg keeps its frame records (`-fno-omit-frame-pointer`, see "Frame records"
  there), so the call stack of a crash in FFmpeg goes on through the engine function that called it.

To symbolicate an FFmpeg frame by hand, use the dSYM of the slice the app ran (`ios-arm64` on an iPhone or iPad,
`tvos-arm64` on an Apple TV, `macos-arm64_x86_64` on a Mac) and check its UUID first:

```sh
dwarfdump --uuid Vendor/FFmpeg/FFmpeg.xcframework/ios-arm64/dSYMs/FFmpeg.framework.dSYM
atos -arch arm64 -i -o Vendor/FFmpeg/FFmpeg.xcframework/ios-arm64/dSYMs/FFmpeg.framework.dSYM/Contents/Resources/DWARF/FFmpeg \
    -l <FFmpeg load address> <frame address>
```

`-i` also prints the inlined functions of the frame (for example `read_packet_wrapper` inlined into `fill_buffer`,
`aviobuf.c:551`). Without the dSYM, a frame in one of FFmpeg's internal functions shows the nearest exported function
instead (the same frame reads `avio_seek + 1240`).
