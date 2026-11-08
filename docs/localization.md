# Localization

English is the development language. The project lists Spanish, French, German, Italian, Portuguese
(Brazil), Dutch, Polish, Russian, Turkish, Arabic, Hindi, Indonesian, Japanese, Korean and Chinese
(Simplified, Traditional) in its known regions. The app's text is in three String Catalogs in `Fluxo/`, and the
Top Shelf extension has its own (`FluxoTopShelf/Localizable.xcstrings`: the titles of its rows):

- `Localizable.xcstrings`: the interface on iOS and macOS, menu commands, VoiceOver text, errors, the
  notifications of reminders, and the App Intents strings (action names and descriptions, parameters,
  dialogs, entity and enum names, Siri synonyms of the screens).
- `AppShortcuts.xcstrings`: the Siri phrases of the App Shortcuts (`FluxoShortcuts.swift`). Every phrase
  keeps `${applicationName}`.
- `InfoPlist.xcstrings`: the Local Network permission prompt, and the names of the M3U Playlist document
  type and of the Fluxo Channel file type (the two last are manual entries: Xcode does not extract them).

Rules the code follows:

- SwiftUI literals (`Text`, `Button`, `Label`, `.navigationTitle`, `.accessibilityLabel`, …) are localized
  keys. Text built outside a view uses `String(localized:comment:)`, App Intents use
  `LocalizedStringResource`. A view that stores a title as `String` (`PlayerBadge`, `HomeSectionHeader`,
  `largeContentControl`, …) gets a `String(localized:)`, because a literal given to a `String` parameter is
  not extracted. Text that is not for people (identifiers, URLs, the prompts of the on-device model,
  debug-only text, previews) uses `Text(verbatim:)` or a plain `String`.
- Counts are interpolated as integers (`"\(count) channels"`), not as `count.formatted()`: the catalog then
  has plural variations for them, and the number still gets the grouping of the locale. Channel numbers use
  `.number.grouping(.never)`, and so do season and episode numbers (`EpisodeFormat.number`: "S2023 E5").
- Dates, times, durations, sizes and time codes use format styles (`.dateTime`, `.interval`,
  `Duration.formatted`, `.byteCount`), never fixed formats or `String(format:)`.
- Whole sentences are keys; a sentence is never assembled from translated pieces. The parts of a subtitle
  line (a kind, a group, a playlist name) are joined with `TextParts.line`, which puts each part in a bidi
  isolate and uses the separator of the language (in Arabic it carries a letter mark, so the line reads
  right to left); VoiceOver labels use `TextParts.spoken` / `TextParts.sentences` (、 and 。 in Japanese and
  Chinese).
- Nothing localized is stored: the guide keeps "S1 E5" and empty titles (`GuideFormat.episode`, "Untitled"
  when shown), a failed guide refresh keeps a `GuideRefreshFailure` code, a failed download keeps a
  `DownloadFailure.Reason` (with the engine's English message; a system error of no known kind keeps its domain and
  code, and its own description only with the language it is in, shown in that language alone) and a download its
  picture height and the codes of its languages, a recording without a channel
  name keeps no title ("Recording from <date>" when shown), and the recordings folder is always
  `Recordings`. Pending reminder notifications are rewritten when the language or the time format changes.
- The iCloud status row never shows CloudKit's descriptions, which are often English developer text
  ("Server Rejected Request"): `CloudSyncErrorText` says what happened (offline, iCloud busy, storage full, signed
  out, or "Couldn't sync"), and the raw error goes to the log. A failed Delete iCloud Data only says that iCloud did
  not confirm it.
- File names the user sees are translated keys (`LibraryExport.fileName`, `DiagnosticsExport.fileName`), made safe
  for a path by `TextParts.fileName` (no "/" or ":"). Names the user never sees (`Library-<date>` backups,
  `Recordings`) stay as they are.
- Values from the provider inside a translated sentence (a programme title in Reminder Not Found, a title in Can't
  Download) go in a bidi isolate (`TextParts.isolated`), so "The 100" or "Hello!" keep their order in Arabic.
- License texts stay in English and are laid out left to right, flush left, in every language
  (`AcknowledgementsView`); the localized lines around them follow the language.
- The messages of the C remux engine are English; `EngineMessage.localized` (`StreamRemuxer.swift`)
  translates the part that says what failed and keeps FFmpeg's technical reason.
- The suggestions of Apple Intelligence are written in the language of the interface
  (`OnDeviceModel.responseLanguage`, from `Bundle.main.preferredLocalizations`, with its script or region:
  "Chinese (Traditional)", "Portuguese (Brazil)").

Xcode updates the catalogs when it builds. From the command line, `xcrun xcstringstool sync` does the same
with the `.stringsdata` files of a build (in `Objects-normal/<arch>` of the derived data); use those of an
iOS and a macOS build, as some strings exist on one platform only. Every string has a comment that says
where it is shown and what its placeholders are; add one (`comment:`) to new strings whose meaning is not
obvious from the English alone.
