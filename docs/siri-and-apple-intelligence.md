# Apple Intelligence and Siri

Everything below runs on the device. The language features use the Foundation Models framework
(`SystemLanguageModel.default`) and nothing else: no Private Cloud Compute, no server, no third-party model. Each
feature has a built-in fallback, so the app works fully when Apple Intelligence is off, not supported, still
downloading or does not support the app's language (`FluxoIntelligence.status`, re-read when the app becomes
active). Settings › Apple Intelligence has a switch for the features and explains why they are unavailable.

- **For You** (Home, `Features/Intelligence/Recommendations`): candidates come from the library (channels of
  the groups the viewer watches most, channels named like the most watched ones, favorites past the first ones,
  and for a new library the first groups; never what the Continue Watching and Favorites rows next to it already
  show, a title twice (its HD / SD copies, other languages and other playlists) or adult content, see "Adult
  content"), a built-in ranking (group affinity, on-air
  programmes, at most three per group, varied reasons) is shown at once, and with Apple Intelligence the model then picks eight and writes a short reason for each
  (`ChannelPicks`, `@Generable` structured output). It may call the `searchChannels` tool (the Search token
  index) to add candidates, at most twice. Picks are numbers checked against the candidates, so nothing can be
  invented, and they go through the rules of the built-in list (each title once, at most three per group, no adult
  content). Results are cached per scope and taste fingerprint (most watched channels, favorites, a three-hour
  slot of the day; a SHA-256 digest, the same in every launch): the model runs again only when one of these
  changes, and its picks survive a relaunch. The taste part is the set of the eight channels that weigh most, the
  favorites and the three categories watched most, so watching the same channels in another order changes nothing.
  The model runs one request at a time, after a 1.5 s pause (switching playlists quickly runs it once, for the last
  one), not on its own in Low Power Mode or while the device is hot (the built-in ranking shows; New Suggestions still
  asks it), and after a failure not again for the same taste before 15 minutes, then 30, up to 6 hours
  (`ModelBackoff`, kept across launches). A run cut short is not a failure.
- **For You Tonight** (Guide; "For You Today" before the evening): programmes on now and in the next six hours on the viewer's channels and groups,
  ranked by channel affinity, timing and recurring categories (a programme on several channels once, none for
  adults), then picked and explained by the model (`ProgrammePicks`, with a `searchGuide` tool). The strip collapses
  to one line.
- **Smart search** (Search, `Features/Intelligence/Search`): queries of two or more words with a cue the name
  search cannot use ("football tonight", "italian news channels", "something like Sky Sport F1"), or that find
  nothing, become a `SmartSearchPlan` (keywords with synonyms and translations, kind, country, time window, a
  channel to find similar ones to). The model writes it as structured output; `SmartSearchRules` does the same
  for common words in English, Italian, German, French and Spanish without it, and backs up the model's plan
  (the model's fields are checked against the query). The plan runs through the regular channel, group and
  programme searches, so every result is real; "Smart Results" show the understood query as chips. The viewer's
  own words match as the regular searches do; added synonyms and translations ("serie a", "info", "tg"), and
  words under three letters, must be whole words of a programme's title, subtitle or categories (or of a
  channel or group name), so "football tonight" does not list every description that says "series". A kind
  alone is a search too: "films tomorrow" or "serie tv stasera" list the guide's programmes whose category
  names the kind (`Film`, `Movie / Drama`, `Serie TV`) and the groups and channels named for it ("Cinema",
  "Sky Cinema Uno"); competitions named with a kind word ("Serie A", "Serie B") stay keywords. A country
  filters programmes as it filters channels, and "tonight" after midnight is the rest of the night.
- **Programme summaries** (programme screen): descriptions of 280 characters or more get a one- or two-sentence
  summary, streamed as it is written and kept for the session.
- **Language**: reasons and summaries are written in the app's language; when the small model answers in another
  one (checked with `NLLanguageRecognizer`), they are translated in one more request.
- Typical timings on a Mac with Apple Intelligence: 4–7 s for a recommendation list, 1–2 s for a query plan.
  `-FluxoDebugIntelligence available|off|unavailable|notReady|unsupported` (Debug builds) forces a status to check
  the fallbacks.

**Siri, Shortcuts and Spotlight** (`App/Intents`). `FluxoApp` registers `AppServices` (player, library, guide,
navigation, intelligence) with `AppDependencyManager`; intents run in the app's process and get it with
`@Dependency`, on iOS, macOS and tvOS (see [Siri, voice search and links](apple-tv.md#siri-voice-search-and-links) under [Apple TV](apple-tv.md) for what Apple TV offers).

- Entities: `ChannelEntity` (it stands for playlist + stream URL, so it survives playlist refreshes; the system only
  sees an opaque identifier, `ChannelEntityID`: the playlist UUID and a keyed HMAC of the URL, since stream URLs
  can carry account credentials and identifiers end up in Spotlight, donations and shared shortcuts) is an
  `IndexedEntity`: favorites and recently watched channels (up to 250) are in Spotlight, and opening one plays it.
  Its synonyms are the names people say (`ChannelSpokenNames`: "IT: Sky Sport F1 FHD" is also "sky sport f1",
  "Rai 1 HD" also "rai 1" and "rai one"), and Siri's words go through `AppServices.resolveChannel` (every word of
  the name, the favorite among same-named channels, spelled-out numbers in the app's 16 languages: "Rai Uno" is
  Rai 1, a programme on air with that title, a channel number, then the closest name). A number is a position in
  the playlist only alone or with a word that says "channel" or "number" in one of the app's languages ("5",
  "channel 5", "canale 5", "5チャンネル"); "BBC 9" or "Eurosport 7" is a name, and the closest name must have the
  numbers said, so a channel the library lacks is reported as not found instead of playing another one.
  `ProgramEntity` is a guide programme (title, episode, start, end, description, categories, channel).
- Intents: Play Channel (`OpenIntent`, `PredictableIntent`), Play by Name (the system `PlayVideoIntent`),
  Continue Watching (the last unfinished movie or episode, where it stopped), Pause / Resume / Stop Playback,
  Start or Stop Recording (one intent with an action; start can play a channel first), Add to Favorites
  (idempotent), Remove from Favorites, Toggle Favorite, Get Favorites, Search in Fluxo (the system
  `ShowInAppSearchResultsIntent`), Find Channels, Get Suggestions, What's On (now and next of a channel, or what
  the favorite channels show), Search TV Guide, Show Channel Schedule, Set Programme Reminder, Open Screen (Home,
  TV Guide, Search, Favorites, Recently Watched, Recordings, Library; on iOS the last two open the Library tab), and Visual Intelligence search. Results come with a
  dialog and a snippet view. Opening a screen moves a full-screen player out of the way as its close button does
  (into Picture in Picture when Settings › Playback asks for it, else the mini player).
- App Shortcuts (`FluxoShortcuts`, the maximum of ten), with phrases in all 16 languages (`AppShortcuts.xcstrings`):
  see [Siri & Apple Intelligence](#siri--apple-intelligence).

## Siri & Apple Intelligence

**What the iOS 27.2 SDK offers, and what Fluxo uses** (checked in the SDK's `.swiftinterface` files):

| Capability | In Fluxo |
|---|---|
| App Shortcuts (`AppShortcutsProvider`): phrases that work without setup, at most ten shortcuts, each phrase with the app name; parameters only from an `AppEnum` or from the entities given to `updateAppShortcutParameters()` | Ten shortcuts. The channel parameter knows the favorites, the watch history and the first live channels of each playlist (up to 80), with spoken-name synonyms; refreshed at launch and, when these names change, after the favorites change or a channel starts (each refresh makes the system query the app again) |
| Assistant schemas, `@AppIntent(schema:)` (iOS 27 `AppSchema`), so Siri with Apple Intelligence understands an intent without a fixed phrase. Domains: assistant, audio (music, podcasts, audiobooks, radio), books, browser, calendar, camera, clock, files, journal, mail, maps, messages, notes, phone, photos, presentation, reader, reminders, spreadsheet, system, visualIntelligence, whiteboard, wordProcessor. **There is no video or TV domain** | `system.open` on Play Channel and `system.searchInApp` on Search in Fluxo (on iOS, and from macOS 27; `AppSchemaAdoption.swift` writes the extension the macro generates, since the macro cannot gate one conformance of a type that exists from macOS 26). `visualIntelligence.semanticContentSearch` (iOS, macOS 27) |
| System intent protocols: `OpenIntent`, `PlayVideoIntent`, `ShowInAppSearchResultsIntent`, `AudioPlaybackIntent` … | Play Channel, Play by Name, Search in Fluxo |
| Spotlight: `IndexedEntity`, `CSSearchableIndex.indexAppEntities`, iOS 27 `IndexedEntityQuery` (Spotlight asks the app to index again) | Channels, with alternate names; `IndexedEntityQuery` on iOS and from macOS 27 |
| On-screen awareness: `View.appEntityIdentifier(_:)`, iOS 27 `MPNowPlayingInfoPropertyAppEntityIdentifiers` | The player view, and the Now Playing entry (so "this channel" works with the player closed) |
| Predictions and donations: `PredictableIntent`, `AppIntent.donate()` | Play Channel is donated whenever a channel starts (from the app, Siri or Shortcuts), so Siri can suggest the channel watched at that time of day |
| Visual Intelligence: `IntentValueQuery` over `SemanticContentDescriptor`, the `semanticContentSearch` schema | Camera or screenshot → Search → Fluxo's channels: the text in the image is read on the device (Vision, with channel names as custom words) and matched to channel names and guide titles, then the labels to guide categories (`VisualSearchIntents.swift`) |
| Foundation Models (on-device model, tool calling, `@Generable`) | For You, smart search, programme summaries (above); Find Channels uses smart search |
| `SiriTipView`, `ShortcutsLink` | Settings › Siri & Shortcuts |
| SiriKit media intents (`INPlayMediaIntent`) | Not used: they need an Intents extension and are for audio |

**Why "Play … in Fluxo" did not work** (found with the debug harness and the built app's `Metadata.appintents`):

1. Siri never learned a channel name. The Spotlight update began with `CSSearchableIndex.deleteAppEntities(ofType:)`,
   which never returns on iOS 27.2, and `updateAppShortcutParameters()` came after it: nothing was indexed and the
   phrase parameters were never registered, so "Play Sky Sport F1 in Fluxo" matched no shortcut. The phrases are
   now refreshed first, and the index deletes only the channels that left it. No bulk delete is used: in the iOS 27.2
   Simulator `deleteAllSearchableItems()` did not return within 5 s either, and a late one could remove the new
   entries.
2. Even then Siri knew only favorites and recently watched channels: none after a fresh install. It now also
   knows the first live channels of each playlist, and their spoken names ("Sky Sport F1", not "IT: Sky Sport F1
   FHD").
3. A channel Siri does not know made the whole phrase fail. "Watch TV in Fluxo" / "Play a channel in Fluxo" now
   make Siri ask "Which channel?", and the answer is searched in every playlist.
4. No assistant schema: Siri with Apple Intelligence had no standard meaning for Fluxo's intents. Play Channel
   and Search in Fluxo now adopt `system.open` and `system.searchInApp`.
5. Stop Recording and a few actions had no phrase in most languages; the phrase sets of all 16 languages were
   checked (every phrase has the app name and only parameters of its intent).
6. Spotlight ran the wrong action for a channel. The system turns every channel of a phrase parameter into a
   tile titled with the channel's name alone, so with channel phrases for What's On, Add to Favorites and
   Recording too, Spotlight listed each channel several times, and opening its top hit told what is on or added
   a favorite instead of playing. Only Play Channel has channel phrases now; the other three act on the channel
   that plays ("Record this in Fluxo") or ask for one, and Siri AI and the Shortcuts app still fill in any channel.
7. A request that played a channel or opened a screen while a channel schedule was open showed the result behind
   that sheet. Intents now close it first (Recordings are a screen of the Library tab, not a sheet).
8. A channel name with a number that the library lacks played another channel: "Play Rai 4 in Fluxo" (or "BBC
   Four", which becomes "BBC 4") on a playlist without it played the fourth channel of the playlist. A number is
   now a playlist position only alone or next to "channel" / "number", and the closest name must have the numbers
   said (`siri-resolve-check` in the debug harness).

**What to say** (English; every language of the app has its own phrases, see Settings › Siri & Shortcuts):

- "Play Sky Sport F1 in Fluxo", "Watch Rai 1 on Fluxo", "Switch to BBC One in Fluxo"; "Watch TV in Fluxo" (Siri
  asks which channel: say any channel name or number)
- "Continue watching in Fluxo", "What's on in Fluxo" (what the favorite channels show), "What should I watch on
  Fluxo"
- "Search Fluxo" (then the words), "Search the Fluxo guide", "Open the TV guide in Fluxo", "Show my Fluxo
  recordings"
- "Add this channel to my Fluxo favorites", "Start recording in Fluxo", "Stop recording in Fluxo", "Remind me
  about a show in Fluxo"
- "Pause" / "Resume" (Siri's own, through Now Playing). With Siri and Apple Intelligence, requests in other
  words ("open Sky Sport F1 in Fluxo", "find football in Fluxo", "what's on Rai 1 in Fluxo") reach the schema
  intents and the actions without phrases, with the channel resolved through the same search.
- Spotlight: type a favorite or recently watched channel (or the name of a Fluxo action); opening the channel
  plays it.

**Steps on a device**

1. iPhone or iPad on iOS / iPadOS 27, or a Mac on macOS 27 (macOS 26 for everything but the schemas and the Now Playing entity)
   with Apple Intelligence for the Siri AI part (iPhone 15 Pro or later, iPad or Mac with M1 or later).
2. Install Fluxo and open it once, with a playlist imported. Wait a few seconds: the phrases and Spotlight are
   updated after launch. Mark a few favorites: Siri learns those first.
3. Settings › Apps › Fluxo › Siri: keep "Learn from this App", "Show App in Search"
   and "Show Content in Search" on.
4. Open the Shortcuts app › Fluxo: the ten shortcuts are listed (Open Screen as one tile per screen), plus one
   Play Channel tile per channel Siri knows by name and one Set Reminder tile per upcoming programme. If
   they are not there, the phrases are not registered yet: reopen Fluxo, or restart the device.
5. Say or type (Type to Siri) a phrase above.

**User-side requirements and common mistakes**

- The request must contain "Fluxo". "Play Sky Sport F1" without it goes to the Apple TV app or Music: no app
  can take over playback requests without its name (the SDK has no video schema).
- Siri's language is what counts, not the app's: with Siri in Italian, say the Italian phrases ("Metti Rai 1 su
  Fluxo", "Cosa c'è su Fluxo"). Fluxo has phrases in its 16 languages; in another Siri language, only the
  Shortcuts app works.
- Apple Intelligence needs a supported device, Siri language = device language (a supported one), the model
  downloaded (Settings › Apple Intelligence & Siri), and a region where it is available. Without it, App Shortcut
  phrases still work; only free-form requests need it.
- A channel name in a phrase must be one Siri knows (favorites, recently watched, first channels of a playlist).
  For any other, say "Watch TV in Fluxo" and then the name, or add the channel to the favorites.
- Open the app once after every install or update from Xcode, TestFlight or the App Store; App Shortcuts
  register at install, the channel names after the first launch. Debug builds from Xcode and TestFlight builds
  behave the same; a build from another bundle identifier is another app to Siri.
- Siri cannot be checked in the Simulator ("Siri is not enabled on this device" on iOS 27.2): try the phrases
  on a device. The Simulator's Shortcuts app and Spotlight do work (`Tools/Simulator/siri-tests.sh`).
- The first Set Reminder brings Fluxo to the front, once, for the notification permission; with notifications
  off for Fluxo it answers that reminders need them (Settings › Apps › Fluxo › Notifications).
- Visual Intelligence needs a device with the Camera Control or the Action button (or a screenshot), and
  Apple Intelligence on.
- Shortcuts built with the earlier Start Recording and Stop Recording actions must be rebuilt with Recording
  (Start or Stop): the two actions are now one (release note for the first TestFlight build).
- A Debug run of the macOS app on an isolated library (`-FluxoDebugStore`) neither indexes Spotlight nor donates
  to Siri: it shares the bundle identifier with the real app.

**How this was checked**

- `Metadata.appintents` of the built app (`extract.actionsdata`, `root.ssu.yaml`): 20 intents on iOS and macOS
  (19 in the Simulator, whose SDK has no Visual Intelligence), the schemas `system.open`, `system.searchInApp`
  and `visualIntelligence.semanticContentSearch`, two entities, three queries (two in the Simulator), ten App
  Shortcuts with their phrases in 16 languages, and no warning from `appintentsmetadataprocessor`.
- The debug harness runs every intent in the app, resolving parameters through the entity queries as Siri
  does (`DebugIntentRoutes.swift`; `Tools/Simulator/README.md`, routes `intent:`, `siri-resolve:`,
  `siri-resolve-check`, `siri-names`, `visual-search:`, `visual-ocr:`, `spotlight-reindex`), with the outcome in
  `Status/intents.log`.
- `Tools/Simulator/siri-tests.sh` (an XCUITest bundle) opens the Shortcuts app on a Simulator clone, checks the
  ten shortcuts and runs What's On through the system (its dialog and snippet answer), searches Spotlight for a
  seeded favorite and opens it (Fluxo comes to the front and plays it), screenshots Settings › Siri & Shortcuts,
  and asks Siri (not available in the Simulator).
