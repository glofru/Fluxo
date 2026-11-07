# Library store

The library is two SwiftData stores in one `ModelContainer` (`LibraryStore`, `ModelContainerFactory`), so a
`ModelContext` reads and writes both without knowing:

| Store | File | Holds | When it cannot be opened |
|---|---|---|---|
| Library | `Application Support/default.store` (backed up) | `ModelRegistry.user`: playlists (addresses, credentials), guide sources and matches chosen by hand, favorites, history and progress, series progress, reminders | Never moved, emptied or recreated on its own: the app shows `LibraryRecoveryView` |
| Cache | `Caches/Fluxo/Cache.store` (never backed up; iOS and tvOS may purge it) | `ModelRegistry.cache`: the channels, categories and series of the playlists, the channels and programmes of the guides | Recreated empty; the next refresh fills it |

- **Versions** (`FluxoSchema.swift`): `FluxoSchemaV1` (1.0.0) is the frozen schema of the first builds, in one store
  (SwiftData records 1.0.0 for a store written without a versioned schema); `FluxoSchemaV2` (2.0.0) is the current one,
  and `FluxoMigrationPlan` goes from one to the other (lightweight: a relationship cannot span two stores, so
  `Playlist.groups` and its inverse went, groups were always deleted by `playlistID`; and the guide's redundant
  `[importID]` programme index went). A store at a higher version than the build knows was written by a newer build
  (TestFlight, then the App Store): it is never opened, as an inferred migration back would drop what that build
  added. A 1.0.0 store whose hashes the plan does not know (a development build before the versioning) opens with an
  inferred migration, as every build did before. The steps to change a model are at the top of `FluxoSchema.swift`.
- **The split of a 1.0.0 store**, once, without copying a row: the file is cloned (APFS: instant, no extra space) to
  become the cache store, with a new store UUID (Core Data loads only one of two stores with the same UUID); each file
  then drops the other side's rows, and the library file is compacted (`VACUUM`) at the next launch, before anything
  opens it (SwiftData cannot close a store, and SQLite cannot shrink a file another connection still has open). Each
  step is noted first in `.default.store.maintenance.json`, so a kill at any point finishes at the next launch. A large
  library (100,000 channels, 522,000 programmes, 178 MB) splits in 4.7 s on a Mac, so when a split is pending the
  library opens off the main thread behind "Updating Your Library…" (`LibrarySession.State.upgrading`; intents wait
  for it), and so does the launch after it, which compacts the library file, and a Try Again that runs the split. The
  reminder notification delegate is installed before the library opens (`FluxoApp.init`): a notification tapped to
  launch the app meanwhile waits for the guide to start.
- **A lost cache** (purged, a device restored from a backup, recreated after an error): at launch, a playlist whose
  visible import has no rows is imported again once the device is online (`PlaylistImporter.playlistsMissingContent`),
  and a guide in the same case loses its HTTP validators and content hash and loads with the stale guides
  (`EPGImporter.resetSourcesMissingContent`). Favorites, history and progress are untouched: they are in the library.
- **When the library cannot be opened** (`LibraryOpenFailure`, read from the file and its metadata, as SwiftData's own
  error says nothing): written by a newer version, cannot be read right now (locked before the first unlock, an I/O
  error; tried again by itself when the device unlocks), not enough space to migrate it, damaged, or another reason.
  Nothing of the app runs then (no sync, import, download or guide refresh that could act on an empty library); every
  window shows why, with Try Again, Export a Copy (a ZIP of the store files, iPhone, iPad and Mac) and Start with an
  Empty Library (asks first; the store goes to `Application Support/Library Backups/`, the newest two are kept, never
  deleted on its own). iCloud sync then sees a lost library and offers to restore it (see "Data safety"). App Intents
  run meanwhile say that the library cannot be opened. There is no `fatalError` left on these paths.
- **Persistent history**: SwiftData records every insert and delete in the stores' history and never removes it: a
  guide refresh of 260,000 programmes left about 35 MB of it, twice a day, without bound. Fluxo reads no history, and
  SwiftData only reads what other contexts of the same process saved meanwhile, so the history of earlier launches is
  deleted once the library is open, off the main thread (`StoreHistory.pruneEarlierLaunches`: 150 ms on a Mac after a
  guide of 262,000 programmes), and what is older than an hour after each playlist import and guide refresh.
- **Checking it**: `Tools/LibraryCheck/run.sh` builds the previous version's sources (`OLD_REV`, `12dd923` by default)
  to write a library as that version did (a playlist and a guide through their importers, favorites, history with resume
  positions, a watched series, a guide match chosen by hand, a reminder, a guide the user added), then opens it with
  this version: every attribute of every user row unchanged, the cache kept, each file purged, both at 2.0.0, no
  history left, the file compacted at the next launch (a new process); and a second launch, a lost cache, a damaged
  cache, a damaged library (reported, untouched, exported, Start Over keeps it), a newer library (reported, untouched),
  a split interrupted by a kill, a new installation. `LIVE=100000 GUIDE_CHANNELS=1500 DAYS=7` times a large one. In the
  simulator, the debug libraries on disk (`-FluxoDebugStore temp|scratch`) go through the same code: install the
  previous version's build, seed a scratch library, install this build over it and run `library-log` (see
  Tools/Simulator/README.md). `-FluxoDebugLibraryFailure <kind>` shows the recovery screen.
