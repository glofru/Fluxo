# iCloud sync

Playlists, the TV guides the user added, favorites, watch history and resume positions, and the player's main
settings follow the user to every device signed in to the same Apple Account (iPhone, iPad, Mac and Apple TV). The main
reason is the Apple TV: typing an M3U address with the Siri Remote is slow, so a new Apple TV offers the playlists of the
user's other devices as soon as it finds them ("Your Playlists from iCloud").

## What syncs

| Synced | Not synced |
|---|---|
| Playlists: name, address, date added (only `http(s)` playlists: one imported from a file lives in the device's container) | Channels, groups, series, artwork: each device downloads the playlist itself |
| TV guides added by the user, and whether they are on (guides of a playlist header follow the playlist) | The programmes of the guide, manual guide matches |
| Favorites of channels, movies and series, in the user's order | Offline downloads, recordings |
| Watch history, resume positions, watched episodes of a series | Device settings: downloads, Picture in Picture, foldable layouts, the Home selection |
| Time-shift length, skip intervals, audio and subtitle languages (and audio description / SDH), reminder lead time, Apple Intelligence on or off, hiding adult content from recommendations | |

## How it works

- **Transport: CloudKit** (`App/Sync/CloudKitSyncTransport.swift`), the user's private database, one zone ("Fluxo"),
  driven by `CKSyncEngine` (batching, retries, the silent push that announces changes, account changes). The key-value
  store (`NSUbiquitousKeyValueStore`) was the other option: smaller (1 MB) and simpler, but Apple's documentation says
  not to put sensitive information in it, as it is stored unencrypted on disk, and its values are not covered by
  Advanced Data Protection. Stream addresses usually embed the provider account (`username=…&password=…`, or
  `/user/pass/` in Xtream paths), so CloudKit's encrypted fields were chosen.
- **No SwiftData-CloudKit**: the store has `@Attribute(.unique)` keys, non-optional attributes and relationships that
  CloudKit mirroring does not allow, and mirroring would sync the 100,000-row channel tables that each device downloads
  anyway. The schema and its migrations are unchanged: sync is a separate layer that reads and writes the library
  through the objects the screens use (`LibrarySyncStore`), so a synced change behaves exactly like a local one (a
  deleted playlist goes through `PlaylistImportCenter.delete`, a new one through the import pipeline, a guide through
  `EPGStore`).
- **Records** (`App/Sync/CloudSyncRecords.swift`): one per playlist, guide, favorite, progress and setting. Favorites
  and progress are separate records, so a favorite added on the iPhone and a movie watched on the Apple TV at the same
  time both survive. Record names never contain an address: playlists and guides are named after a hash of their
  address the first time they sync (so the same playlist added on two devices before sync was on becomes one, and the
  name stays when the address is edited later), favorites and progress after a hash of their playlist and stream
  address.
- **Conflicts** (`App/Sync/CloudSyncReconciler.swift`): last writer wins, per record, by the time of the change (then
  the device ID, so every device picks the same winner). A change made after the device received another device's
  change always wins over it, whatever the clocks say. An item a device never compared before (there before sync was
  on) carries its own date (when it was favorited or last watched), so turning sync on does not let last week's
  position on one device override yesterday's on another. When CloudKit refuses a save because another device saved
  first (`serverRecordChanged`), the server's copy is merged and the newer one is sent again.
- **Deletions** are records without a value (a tombstone): a playlist deleted on one device is deleted on the others,
  with its favorites and history, and a device that was offline cannot bring it back. Deleting a playlist writes one
  record, not one per favorite (they go with their playlist). The Delete Playlist alert says when the playlist will be
  removed from the user's other devices too. Removing a favorite or clearing the history syncs the same way.
- **The ledger** (`Application Support/CloudSync/ledger.json`, complete file protection until first unlock): the newest
  record of every item and the device's own value at the last comparison. A difference between the library and the
  ledger is a change made on this device; a record the device does not match yet (a favorite whose playlist is still
  importing) is applied at the next pass. Library saves (`ModelContext.didSave` of playlists, guides and bookmarks) and
  changes of a synced setting start a pass 2–3 s later, so an import or a burst of favorites is compared once; the app
  also syncs when it comes to the foreground and before it is suspended. A pass that changes nothing does not write
  the ledger.
- **Battery during playback**: the resume position playback saves every 10 s (`WatchProgressRecorder`) is not
  published at once (`ChannelLibrary.isSavingPeriodicProgress`): those saves start at most one pass every 5 minutes
  (`CloudSync.progressPublishDelay`), which later saves do not postpone. Pausing, the end of an item, another item,
  stopping and the app going to the background save it as usual and publish it within seconds, so a movie paused on
  the iPhone resumes at the right place on the Apple TV, without an upload every 10 s of the movie.
- **Delivery**: the ledger keeps the records of this device the cloud has not confirmed (`unsent`), written together
  with the change. `CKSyncEngine` retries only transient errors (network, throttling, account temporarily unavailable,
  `CKSyncEngine.h` "Error Handling") and drops the others; a save refused for good (`quotaExceeded`: iCloud storage
  full; Settings › iCloud says so), cancelled, or queued just before the app was quit is queued again at the next sync
  (foreground, Sync Now, sign-in) until the cloud confirms it, unless another device's newer change replaced it. A
  `batchRequestFailed` record (refused only because another one of its batch was) is sent again at once.
- **First run** (`CloudPlaylistImportView`): a device that had playlists when sync started shares them and takes the
  others. A device without playlists (a new Apple TV) asks first, once: the sheet (full screen on Apple TV, with the system
  card buttons and focus) lists the playlists of iCloud by name and server, all checked; Add imports them through the
  normal pipeline with the progress of each, and their favorites, history and guides follow. A playlist left out stays
  in iCloud (Settings › iCloud › Playlists in iCloud). An import that fails here keeps the playlist (it exists on the
  other devices), with no channels until a refresh works. The offer opens on its own only while the device has no
  playlist, never over the player or the Add Playlist sheet, and closing it any way without Add (Not Now, Menu on the
  Siri Remote, a swipe down, Escape) is final: it then opens only from the empty Home ("Add N Playlists from iCloud",
  next to Add Playlist on the Apple TV welcome screen, where it has the focus) and from Settings › iCloud. The empty
  Home says "Looking for your playlists in iCloud…" meanwhile. Typing an address remains possible: on Apple TV the URL field uses the URL keyboard, so the Continuity
  Keyboard on a nearby iPhone or iPad gets it too, and Add Playlist explains both ways. No local web server or QR-code
  form is used: nothing listens on the network for this.
- **Data safety** (`CloudSyncReconciler`): sync never lets an empty, recreated or stale library empty the other
  devices.
  - **Baseline first**: a device publishes and applies nothing before it has read the whole cloud once
    (`SyncLedger.hasBaseline`): a new device, a ledger that was lost or could not be read, another account. The first
    fetch reads the zone from the start (`CloudSyncTransport.forgetFetchPosition`, an engine without a saved state),
    as the engine state may have outlived the ledger; only a fetch that `CKSyncEngine.fetchChanges()` reports as
    finished without an error, and whose zone read did not fail, counts. Then the baseline pass matches the library
    with iCloud (same address = same playlist; `SyncLedger.hasMatchedBaseline`), item by item:
    - favorites and watch progress both sides have are decided by their own date (when it was favorited, last
      watched), whichever device turned sync on first: a movie watched yesterday on the iPad keeps its position over
      the same movie watched a week ago on the iPhone;
    - playlists, guides and settings both sides have take iCloud's value, so a stale copy cannot override a rename
      made elsewhere. The trade-off: a rename made on this device while it was offline and that never reached
      iCloud is lost when its ledger is lost too (the playlist takes iCloud's name);
    - a playlist or guide deleted on another device that this device still has stays here, as a row of this device
      only (`SyncLedger.keptDespiteDeletion`): it is not deleted here (this device may never have synced it) and not
      brought back on the others. Editing or deleting it here ends that (an edit publishes it again, as the newer
      action). One added here after the deletion (`createdOn` later than the deletion) is the newer action and
      syncs. Settings › iCloud shows such items ("Deleted on Other Devices", "N kept on this device"): Sync Again
      (`CloudSync.syncKeptAgain`) publishes them again, as the newer action, with the favorites and history added
      to them here meanwhile;
    - what only this device has is published.
  - **Deletions by intent only**: a playlist or guide source is deleted on the other devices only when the user
    deleted it here: `PlaylistImportCenter.delete` and `EPGStore.deleteSource` write it to `SyncDeletionJournal` (in
    the defaults, before the row goes, so a playlist or guide deleted while sync is off or just before a quit is still
    deleted elsewhere), and the reconciler folds the journal. A deletion that fails withdraws its entry
    (`SyncDeletionJournal.withdraw`), so the row it left is never deleted elsewhere if the store is lost later; the
    journal keeps the newest 200 entries (a device with sync off never folds it), and one dropped is the safe way: the
    item is merely gone for sync. Clear History counts for a day (`historyIntentLifetime`): a history cleared longer
    before sync runs (sync off, turned on later) is a held mass removal, and the user is asked. Watched items the
    user removes from the history are journaled the same way, one entry each (`SyncDeletionJournal.noteHistoryRemoved`,
    a hash of the local playlist and the stream address or series, `SyncIdentity.localHistoryKey`, so the defaults
    hold no address): Remove from History on a Continue Watching card (a series: every episode watched, one record
    each, and the series), a swipe or Edit in Recently Watched, episodes marked unwatched or watched (when that leaves
    no progress), and the app's own trim of the history to its 200 newest items. Their removals are published at once,
    however many there are, and do not count towards a mass removal; each entry counts for a day too, is withdrawn
    when the item is watched again first, and goes in the pass that folds it. One that is merely gone (a library started over after it
    could not be opened, see [Library store](library-store.md), a migration that lost rows, a purge) stays in iCloud and on the other devices and waits for
    the user (`SyncLedger.awaitingRestore`); its favorites and history are never published as removals. The same
    playlist added again by hand takes its old record back (no duplicate), and its favorites return.
  - **Mass removals are held**: when favorites, or the watch history, of playlists still on the device vanish in
    large numbers in one pass (3 or more and at least half of what the device had, `SyncMassDeletionPolicy`), the
    removals are not published (`SyncLedger.heldDeletions`) until the user answers. Clear History is the user saying
    so (`SyncDeletionJournal.noteHistoryCleared`), as are the watched items removed from the history (above: a series
    with 4 episodes that make up most of the history leaves the other devices at once, the rest stays), and removing
    one or two favorites in a row syncs at once. History that vanishes unexplained in the same pass is still held,
    measured against the history that remains.
  - **Only known records**: a deletion is published only for an item this device compared before (`lastSeenLocal`),
    never for one it never had.
  - **Questions** (`CloudSync.Prompt`, system alerts presented by `cloudPlaylistImport()`, never over the player or a
    sheet in use, and asked as soon as it closes; the root of the window cannot present an alert over another sheet
    or popover, e.g. Settings on iPhone, so while the key window shows one the question waits and is checked again
    every 2 s, `CloudSync.windowIsCovered`): "Restore Your Playlists from iCloud?" when playlists are awaiting
    a restore (Restore adds them back through the import pipeline, with the progress sheet, their favorites, history
    and guides; Not Now is final for those playlists, which stay in Settings › iCloud › Playlists in iCloud, until
    they are restored: lost again, they are asked about again); "Remove Favorites (Watch History)
    from All Your Devices?" for held removals (Restore Them; Remove Everywhere, destructive; Not Now, the preferred
    button, as it changes nothing anywhere: a click neither undoes a removal the user meant nor removes anything
    elsewhere. A tvOS alert focuses its first button and puts the cancel button last, so on Apple TV the question is
    a full-screen page of its own, focused on Not Now, where Menu is Not Now too: `HeldRemovalsQuestion`). Not Now asks again a day later, not at every launch, or sooner when more removals are
    held than when it was put off (`SyncHeldRemovalsReminder`); nothing is removed elsewhere meanwhile, and Settings ›
    iCloud › Restore from iCloud offers them all along.
  - **One engine at a time**: CloudKit forbids two `CKSyncEngine`s on the same database in production
    (`CKSyncEngine.Configuration.database`). `CloudKitSyncTransport` runs every change of its engine on a
    `SerialTaskQueue` (start, stop, `forgetFetchPosition`, Delete iCloud Data), in the order asked for: the running
    engine is detached and `cancelOperations()` is awaited before the next one is created, and sends and fetches wait
    for the queue. Events of an engine that is no longer current are ignored, except the change tags of a send that
    completed after its cancellation (cancellation is asynchronous), which stay true for the server.
  - **Restore from iCloud** (Settings › iCloud): folds the user's own changes, then reads the whole cloud again,
    brings back the favorites, history and settings missing here (held removals included), and opens the iCloud
    playlists sheet, all checked, for the playlists of iCloud this device does not have. It deletes nothing and
    overwrites nothing that is on the device. The row says how many items wait ("3 to restore"), and "Everything in
    iCloud is on this device" when nothing was missing.
- **Sync off**: turning it off on a device stops sending and receiving there; the ledger stays, so when it is turned
  on again the changes made meanwhile on both sides are merged (a playlist deleted meanwhile is deleted on the other
  devices then).
- **Accounts**: signing out stops syncing and keeps the library and the ledger, so signing in again to the same
  account goes on from there (nothing is republished as new, which would override renames and deletions made
  meanwhile on the other devices); the transport remembers the iCloud user record, and another Apple Account (signed in
  directly, or after a sign-out) gets this device's library as new. When the user deletes the data from iCloud's
  storage settings, sync turns off. Settings › iCloud has the switch
  (per device; shown off, and disabled, in a build that cannot sync), the status (synced when, Syncing…, Sign in to iCloud, not available in this build), Sync
  Now, Playlists in iCloud, Restore from iCloud, and What's Synced and Privacy, which has Delete iCloud Data (deletes the zone; every device's
  library stays). Delete iCloud Data reports success only when CloudKit confirms the zone deletion
  (`sentDatabaseChanges.deletedZoneIDs`); otherwise it says so, leaves sync as it was and withdraws the pending
  deletion, so it cannot run later over data uploaded again. With sync off it uses an engine that only sends (it never
  fetches, so nothing of iCloud is applied on the way). Release builds without the iCloud capability (the ad hoc signed
  Mac build) do not show the iCloud section.

## How stream addresses are protected

Everything that can carry credentials (playlist and guide addresses, channel and stream URLs, names, logos) is one JSON
blob per record in `CKRecord.encryptedValues`: CloudKit encrypts it on the device before it is sent and decrypts it
after it is fetched. Only the time of the change, a random device ID and a deletion flag are plain fields. The data is
in the user's private database, which only their Apple Account can read, and it is encrypted in transit and on Apple's
servers. With **Advanced Data Protection** turned on, CloudKit encrypted fields are end-to-end encrypted: the keys are
only on the user's trusted devices, and Apple cannot read them (Apple: "iCloud data security overview", and the
`encryptedValues` documentation). Without it, Apple holds the keys (standard data protection), which allows account
recovery. Settings › iCloud › What's Synced and Privacy says the same to the user, with where to turn Advanced Data
Protection on. The local ledger and engine state are in Application Support, like the library store.

Record names are not encrypted (CloudKit never encrypts them): playlist and guide records are named after a SHA-256
of their normalized address, favorites and progress after a SHA-256 of their playlist record and stream address.
Without Advanced Data Protection, someone who can read the record names of the user's private database (Apple) and
who guesses a provider's host and an account's user name and password could test that guess against a name offline.
A keyed hash (HMAC with a random per-account key kept in an encrypted field) would remove that; it needs a key
agreed by every device before the first record is named, and is left for a later version (see `SyncIdentity`).

**Not done yet** (backlog): tombstones (deletion records) are never removed from iCloud, so the zone keeps one small
record per deleted playlist, guide, favorite or watched item; removing them safely needs every device to have seen
them (a device away longer would otherwise publish its copy as new). Record names are the unsalted SHA-256 above.
The footer of Settings › iCloud names "iPhone, iPad, Mac and Apple TV" on every platform, and the Mac cannot sync in
the ad hoc build: to reword in the next translation sweep, with the new sync strings (English only for now).

**The default.** A new install syncs (`sync.enabled` is set on at the first launch of a build that can sync): a new
Apple TV then offers the playlists of the user's iPhone. A user who updates with a library already on the device
(playlists, guides they added, favorites or history) is asked once, after the iCloud account is known to be
available and never over the player: "Sync Your Library with iCloud?" (in three short sentences, readable from the
couch: what syncs, that addresses are encrypted first, and that Settings can change it; why addresses are sensitive
is left to What's Synced and Privacy), Turn On iCloud Sync or Not Now. Until
the answer nothing is uploaded; Not Now (also Menu on the Siri Remote) keeps sync off for good, and the switch in
Settings › iCloud answers the question too. A build that cannot sync (unsigned, the ad hoc Mac build) asks nothing and
shows the switch off. Release notes (they do not name the Mac: its ad hoc signed build cannot sync yet, see
[Capabilities and signing](#capabilities-and-signing)): "iCloud sync keeps your playlists, TV guides, favorites and progress the same on
iPhone, iPad and Apple TV. If you already have playlists, Fluxo asks before syncing them; addresses are encrypted
before they leave your device."

## Capabilities and signing

The app needs the **iCloud (CloudKit)** capability with the container `iCloud.dev.watermelon.Fluxo`, and **Push
Notifications** plus the **Remote notifications** background mode (`UIBackgroundModes`: `remote-notification`) so
that `CKSyncEngine` learns of changes at once. `Fluxo/Fluxo.entitlements` (iOS and iPadOS) lists
`com.apple.developer.icloud-services` (`CloudKit`), `com.apple.developer.icloud-container-identifiers` and
`aps-environment`; the Apple TV app's `Fluxo/Fluxo-tvOS.entitlements` lists the same three keys (plus the Top
Shelf App Group). With automatic signing and the team (4MJXMYZ3D9), Xcode registers the container and the
capabilities of the App ID the first time it signs; the container appears in the CloudKit Console, where the
development schema is created by the first records and must be deployed to production before a TestFlight or App
Store build syncs (record types `Playlist`, `GuideSource`, `ChannelFavorite`, `ChannelProgress`, `SeriesFavorite`,
`SeriesProgress`, `Preference`; fields `payload` (encrypted bytes), `modifiedAt`, `deviceID`, `deleted`).

`CKContainer` stops the app when it is not signed with the entitlement, so the container comes from Info.plist
(`FluxoCloudKitContainer` = `$(FLUXO_CLOUDKIT_CONTAINER)`), and the build setting is empty when
`CODE_SIGNING_ALLOWED=NO` (`FLUXO_CLOUDKIT_CONTAINER_$(CODE_SIGNING_ALLOWED)`): unsigned command-line builds and the
simulator harness run without sync and say "Not available in this build". The Mac has no iCloud yet:
`FLUXO_CLOUDKIT_CONTAINER[sdk=macosx*]` is empty, because its Debug build is signed ad hoc (which cannot carry iCloud
entitlements) and its team-signed Release build does not list them yet. To sync on the Mac, add the same three keys
to `Fluxo/Fluxo-macOS.entitlements` (`aps-environment` is `com.apple.developer.aps-environment` there), sign Debug
with the team too (or keep the override for Debug only) and remove the `[sdk=macosx*]` override for Release. The
Apple TV build reads `Fluxo/Info-tvOS.plist`, which has the `FluxoCloudKitContainer` key and the
`remote-notification` background mode too, and uses `Fluxo/Fluxo-tvOS.entitlements` (the iCloud keys of
`Fluxo/Fluxo.entitlements` plus the App Group): the same capabilities apply to the tvOS App ID (the iCloud container is shared by the four platforms).
The SwiftData store opts out of SwiftData's own CloudKit mirroring (`cloudKitDatabase: .none` and
`groupContainer: .none` in `ModelContainerFactory` and the debug stores): with the iCloud entitlement the default
(`.automatic`) mirrors the store to the container, which a schema with unique constraints and non-optional attributes
cannot do, so the store would not open in a signed build; and the Apple TV store stays in the app's container rather
than the Top Shelf App Group.

## Checking it

```sh
Tools/SyncCheck/run.sh     # the reconciler on simulated devices that share a simulated cloud
```

`SyncCheck` compiles the sync sources with an in-memory library per device and a cloud that refuses stale saves like
CloudKit (`App/Sync/SimulatedCloud.swift`), and checks: a new Apple TV waiting for the user, then getting the playlist
with its favorite and resume position; renames and address changes from either side (no duplicate); the same playlist
added on two devices; a favorite and a watch at the same time; concurrent offline renames; a device clock an hour
behind; deletion with its bookmarks and no resurrection by a returning device; removed favorites; guides; turning sync
on with history on both devices; a relaunch that sends nothing; another account; and 200 random edits on three devices
that must converge; a save refused for good (iCloud storage full) that arrives once there is space; a change queued
just before the app was quit, sent at the next launch; a refused change that another device overrode, not sent again;
and idle passes that do not write the ledger. Data safety: a recreated (empty) store that deletes nothing anywhere and
is restored on request; a store recreated with an unsent rename (the rename is still sent); a lost ledger whose stale
copy overrides and deletes nothing; turning sync on with history on both devices, in both orders (the older device
first too); a playlist deleted elsewhere while the device's ledger was lost (kept here, not brought back there); a
device that never synced and sends nothing; favorites and history vanishing in
large numbers (held, then restored or removed once confirmed), while a few removals, Clear History and playlists
deleted one by one sync at once; a series removed from Continue Watching with its 4 episodes, most of the history
(nothing held, the other device loses that series and keeps the rest); several swipes in the history in one pass and
more between passes, with a movie watched again right after its swipe (kept); a removal from the history with an
unexplained loss in the same pass (the loss is still held) and one made two days before sync runs (held); the
held-removals question after Not Now (a day later, sooner with more held); a rename against a deletion on two offline devices (the later wins, nothing else is
lost); the same playlist added again by hand after the store was lost (no duplicate, its favorites return); a guide
gone without a deletion; Restore from iCloud; a playlist kept despite its deletion elsewhere, listed and synced again
with its favorites; a deletion that failed (withdrawn from the journal, so a later lost store deletes nothing); the
journal's capacity (an entry dropped deletes nothing); Clear History made days before sync runs (held); and the
engine life of `CloudKitSyncTransport` on its `SerialTaskQueue` (start, stop and Restore in quick succession never run
two engines). Each guard is checked: with it disabled, these scenarios fail. In the app, `-FluxoDebugCloud memory|<folder>` replaces CloudKit with the simulated cloud (a folder
that two simulator clones share lets them sync with each other), see "iCloud sync" in `Tools/Simulator/README.md`.
