# Testing

Three layers, from fastest to slowest: the unit tests, the checks under `Tools/`, and the simulator harness.
CI runs the first two on every push and pull request ([CI](ci.md)).

## Unit tests (`FluxoTests`)

A unit-test bundle written with **Swift Testing** (`import Testing`, `@Test`, `#expect`), hosted in the Debug app
(`@testable import Fluxo`), in the Swift 6 language mode like every target. The scheme's Test action runs it through
the test plan **`Fluxo.xctestplan`** (repository root): ⌘U in Xcode, or

```sh
Tools/CI/test.sh            # iOS: an iPhone simulator of the newest iOS runtime, cloned, then deleted
Tools/CI/test.sh mac        # on this Mac
FLUXO_TEST_DEVICE="iPhone 17e" Tools/CI/test.sh
xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -destination 'platform=iOS Simulator,name=iPhone 17e' test CODE_SIGNING_ALLOWED=NO
```

The test plan launches the host app with the debug harness's isolated library (`-FluxoDebugStore memory`: an
in-memory store, separate settings; see `Tools/Simulator/README.md`) and with Apple Intelligence reported as
unavailable (`-FluxoDebugIntelligence unavailable`), so a test run never touches a real library and the on-device
model does not run behind the tests. Tests that need a store make their own: an in-memory container
(`LibraryStore.makeInMemoryContainer()`) or a library in a temporary folder (`LibraryStoreLocation.isolated(in:)`).

| Suite (file) | What it checks |
|---|---|
| M3U parsing (`M3UParserTests`) | The EXTINF grammar (quoted attributes, titles with commas, EXTGRP, options), LF / CRLF / CR files, a byte order mark, Latin-1 titles, logos, bare URLs, the header's guide URLs; every input also fed one byte at a time, and a large playlist in chunks of 1 B to 64 KB |
| Series and episode parsing (`EpisodeParserTests`) | `EpisodeParser` on 107 real-world names (SxxEyy spellings, NxNN, words in several languages, scene releases, the category as the title, movies and channels that are not episodes); one key per series; the import's classification against `ChannelContentKind.classify` |
| Search ranking (`SearchRankingTests`) | Folding (case, accents, width, punctuation), exact before prefix before longer names, words in any order, prefixes, words inside words and across breaks, typos (never for digits), ties in playlist order, the kind filter, the limit |
| TV guide matching (`EPGMatchingTests`) | Name keys of decorated IPTV names, loose and id keys, the matcher's order (tvg-id, strict name, id read as a name, loose key; the playlist's own guide first), manual choices, the wanted channels of a refresh; XMLTV dates and `xmltv_ns` episode numbers; a whole guide through the streaming parser |
| Playback route (`PlaybackRouteTests`) | Which URLs AVPlayer plays and which go through the engine, live or on demand, by scheme, extension and the playlist's kind; local files; the fallback of a movie AVPlayer failed; when the tracks of an opened movie send it to the engine |
| Featured billboard and adult content (`FeaturedTests`) | The adult-content classifier (adult names in many languages and scripts, look-alikes left alone), the title and franchise keys, the picker's diversity over 200 seeds (one page per category, title and franchise, every kind, both playlists, kinds alternating), adult content left out unless it is all there is, the rotation, the taste, the slots, artwork, and the loader on a store |
| Library store and schema migration (`SchemaMigrationTests`) | A store of the first builds (schema 1.0.0, one file) opens with every row kept, split into the library and the cache, at 2.0.0; a store of a newer build and a damaged file are reported and left as they are; a damaged cache is recreated; the plan's versions |
| Downloads list (`DownloadManifestTests`) | Records of earlier and later builds read with defaults, unreadable ones kept and written back unchanged, a file that is not a list |
| Download failures (`DownloadFailureTests`) | A system error of no known kind keeps its domain, code and the language of its description, shown only in that language; uninformative errors; the stored form and the texts of earlier builds |
| Smart Search chips (`SmartSearchChipsTests`) | The chips show the viewer's own words, not the synonyms and translations searched with them, also for Japanese and Chinese queries written without spaces |
| Diagnostic reports (`DiagnosticReportStoreTests`) | The on-device ring buffer of MetricKit reports: order, kinds, the count, size and age limits, the export ([Diagnostics](diagnostics.md)) |
| Harness playback probe (`HarnessProbeTests`) | Where the simulator harness counts a seek as landed (`DebugPlaybackProbe.isAtTarget`) |

The name tables are shared with the `Tools/` checks: `FluxoTests/Fixtures/EpisodeParserCases.swift` (also compiled by
`Tools/SeriesCheck`) and `FluxoTests/Fixtures/MatureContentCases.swift` (also by `Tools/FeaturedCheck`, which has no
`Fluxo` module to import, hence the `#if canImport(Fluxo)` around its import). Add a case there and both run it.

Adding tests: a new file in `FluxoTests/` joins the target by itself (a synchronized folder). Keep tests independent
(Swift Testing runs them in parallel; mark a suite `.serialized` when its tests share files) and away from the network.
A key path to a static member of an existential metatype (`schemas.map(\.versionIdentifier)` on
`[any VersionedSchema.Type]`) crashes the Swift 6.4 compiler: use a closure.

## Checks under `Tools/`

Each compiles the app's own sources (with the language settings of `Tools/swift-language.sh`) or the C engine, and
exercises them at a scale unit tests do not: large synthetic playlists, libraries and guides on disk, migrations from
the sources of older commits, timings and peak memory. `Tools/CI/checks.sh` runs them all with CI-sized inputs, one
at a time; `Tools/CI/checks.sh guide series` runs some. Each script also runs on its own, with larger defaults
(see its header).

| Check | Script |
|---|---|
| `legal` | `Tools/Legal/check-acknowledgements.sh`: the acknowledgements against what ships |
| `ffmpeg-framework` | `Tools/FFmpeg/check.sh`: the version, license and components of the FFmpeg build |
| `sync` | `Tools/SyncCheck`: iCloud sync between simulated devices |
| `series` | `Tools/SeriesCheck`: the episode parser, a large import with series, the migration from an older commit |
| `featured` | `Tools/FeaturedCheck`: the featured picks and the adult-content filter on a store |
| `home-queries` | `Tools/HomeQueriesCheck`: every Home / Search query on a large store |
| `guide` | `Tools/GuideCheck` (offline): the XMLTV pipeline, refreshes, deleting a source while it is imported |
| `library` | `Tools/LibraryCheck`: the library store's split and migration from an older commit, recovery, the downloads list |
| `playlist` | `Tools/PlaylistBenchmark`: the streaming M3U import against the former one |
| `image-loader` | `Tools/ImageLoaderBenchmark`: the logo loader against the former path (needs `ffmpeg`) |
| `engine` | `Tools/EngineSmokeTest/run.sh`: the remux engine on a local live stream with a reconnection (needs `ffmpeg`) |
| `test-streams` | The harness's test server (`Tools/Simulator/test_stream_server.py`) starts and serves every file it advertises (needs `ffmpeg`) |

`ffmpeg` here is the command line program (`brew install ffmpeg`), a test tool that generates and inspects test
streams; nothing links it. Every server the checks start is bound to 127.0.0.1.

`Tools/EngineSmokeTest` has more engine scripts (formats, seeking, tracks, VOD, leaks) that take longer; run them
when changing the engine.

## Simulator harness and UI tests

`Tools/Simulator` builds the Debug app, launches it on simulator clones with a seeded isolated library and a list of
routes, takes screenshots, and has XCUITest bundles that drive the installed app (gestures, accessibility audit,
notifications, Siri, Apple TV remote and Top Shelf). They need a booted clone, the test streams and, for some, an iPad
or an Apple TV simulator, so they are not part of the test plan or CI: run them by hand when a change touches what
they cover. See [Tools/Simulator/README.md](../Tools/Simulator/README.md).
