# Playlists, Home and search

## Playlist import

Playlists are streamed from the network (`DownloadManager`), parsed incrementally
by a byte-level M3U parser (`M3UParser`), and stored in batches on a background
`ModelContext` (`PlaylistImporter`). The main actor only receives throttled
progress (`PlaylistImportCenter`). A refresh writes a complete new copy of the
channels and switches to it only when the copy is fully stored. If the refresh is
cancelled or fails, the previous channels are kept.

To benchmark the old and new pipelines on a synthetic 100k-entry playlist, and to
run the parser edge-case self test:

```sh
Tools/PlaylistBenchmark/run.sh             # ENTRIES=20000 for a quicker run
```

## Home, favorites and search

- **Featured** (the billboard at the top of Home, the hero of the Apple TV Home; `FeaturedPicker`, `FeaturedLoader`,
  `FeaturedRotation`): eight different things with artwork. Providers list related entries together (a category of
  every "Fast & Furious" film, "Sky Sport 1…10"), so the pages come from categories, not from a run of the playlist:
  at most one per category, movies, series and live channels interleaved (about three, three and two; a kind the
  scope lacks gives its pages to the others), mixed across the playlists and the provider sections of the category
  names ("IT | …", "UK | …"). A title counts once whatever its quality, language, year or edition tags ("Avatar
  (2009) [ITA]" and "Avatar 4K"), and so do a series, a franchise ("Toy Story", "Toy Story 3") and a channel family
  ("Rai 1", "Rai 2"; `FeaturedTitle`). Real artwork comes before placeholders. The categories and kinds the viewer
  watches are drawn more often (a weighted random draw, so they never take over), and what Continue Watching shows is
  not featured. The draw follows a seed: the same pages until the app comes back to the foreground on another day or
  six hours later, or Home is pulled to refresh, never while it stays on screen; the seed is kept, so a relaunch
  shows the same pages until then. Loading reads a few rows of about a dozen categories on a background context (about
  20 ms for 120 categories and 20,000 entries, `Tools/FeaturedCheck`).
- **Adult content** (`MatureContent`, `MatureContentFilter`): Settings › Recommendations › "Hide adult content from
  recommendations" (on by default, synced with iCloud) leaves channels, movies, series, categories and programmes for
  adults out of what Fluxo puts forward on its own: Featured, For You, Because You Watched, On Now, For You Tonight
  and the Apple TV Top Shelf. Search, the categories and the user's own lists (Favorites, Continue Watching, Recently
  Watched) still show them, and a scope whose categories are all for adults is not filtered (there would be
  nothing else to show). The classifier reads category, channel, series and programme names, folded (case,
  diacritics, width) and as whole words: "XXX", "18+" / "+18", "Adult" and its translations ("Adulti", "Para
  adultos", "Erwachsene", "Для взрослых", "للكبار", "アダルト", "성인방송"…), "Porn", "Erotik", "Hentai", the
  networks ("Playboy TV", "Dorcel", "Brazzers"), and categories named only "Sex". It leaves "Essex", "Sussex",
  "Adult Swim", "Adult Contemporary", "Sex Education", "xXx" (the 2002 film) and "Super Bowl XXX" alone. M3U has no
  standard adult flag (the rare `adult="1"` attributes would need a schema version to store, for what the names
  already say), so names are what it reads.
- **Home** (`Features/Home`) shows the featured billboard, a playlist switcher ("All Playlists" plus one
  chip per playlist), Continue Watching (movies and episodes with a progress bar and the time left, live
  channels with what is on now), On Now (large cards of what the user's favorite and recent channels show,
  from the TV guide, topped up with other channels of the scope that have a guide; hidden without a guide),
  Favorites, Because You Watched (more of the category of the last thing watched), then the groups of the
  chosen kind (Live TV / Movies / Series): a strip of category cards and a lazy row per group with its
  first 24 channels. Group rows are fetched 8 at a time as they scroll in.
- **Category browsing** (`Features/Browse`): category cards show an artwork mosaic of the first channels
  with a logo (four logos, or three fanned posters; one indexed fetch of 4 rows per card) and the count.
  "See All" of the strip opens the category browser (every category of the kind, two or more columns, a
  name filter, playlist / A–Z / size order, 60 cards per page). A category (`CategoryDetailView`) has a
  pinned bar of its sibling categories to hop between them without going back, a list (channel numbers,
  logos, LIVE, the programme on air with its progress and time left, what comes next) or a grid, the
  orders Channel Number / Name (A–Z) / Recently Added (last playlist entries first, where providers append
  new VOD) / Most Watched (the most played channels of the category from the history, then the rest), a
  search within the category (500 matches at most), and an A–Z quick scroller on the trailing edge in the
  A–Z order (it reads only the names of the category). Channels are fetched as values on a background
  context, 120 at a time. The order and layout are remembered per kind, and the first row seen per
  category and order (60 categories at most, offsets only), so coming back scrolls to where you left.
- **Channel numbers** are the position of the entry in its playlist, from 1, as set-top boxes number them.
- **Channel rows** swipe right to play, left to add or remove the favorite and to open the channel's
  schedule (today and the next days from the guide, with reminders); the context menu has the same actions.
- **Favorites** (`Features/Favorites`): what the favorites show now, as large cards, then every favorite with
  its artwork, playlist and category, the programme on air with its progress and what follows (or the watch
  progress of a movie), in sections by type or playlist (or none), a type filter, swipe and menu actions, and
  the user's own order (Edit on iOS, drag on macOS; `ChannelBookmark.favoriteOrder`, new favorites first).
- **Watch progress** (`WatchProgressRecorder`): the position of movies and episodes is saved every 10 s of
  playback, on pause, at the end, when another item starts and when the app leaves the foreground, and
  playback resumes there (once the item can seek that far, within 20 s of the start). The last 3 % (at most
  5 minutes) count as watched and clear the position; positions under 30 s are not resumed. The context menu
  offers Play from Beginning. Recently Watched lists the history by day.
- **Content kinds** are guessed once at import time (`ChannelContentKind`) from
  the URL (Xtream `/movie/` and `/series/` paths, file extensions) and from the
  names (episode markers, see [Series](series.md); "Series" groups). Each group gets the most common kind of its
  channels. Playlists imported before this change show as Live TV until refreshed.
- **Favorites and watch history** are `ChannelBookmark` rows keyed by
  playlist + stream URL, so they survive refreshes (which rewrite channel rows),
  and they are deleted with their playlist. The history keeps the 200 most recent
  entries.
- **Search** is token based (`SearchMatcher`, `ChannelSearchIndex`): every word of the query must
  match a word of a channel or group name, in any order ("Sky F1" finds "Sky Sport F1", "f1 sky"
  too), ignoring case, accents, width and punctuation ("IT | Sky-Sport" = "it sky sport"). A word
  matches exactly, as a prefix, inside a word, across words ("skysport"), or, for words of 4+
  letters, with one typo (two from 8 letters; digits never). Results are ranked: the exact name,
  then names that start with the query, then by match quality, words in order and fewer extra words.
  The names of each visible import are read once into memory (on a background context, about a
  second for 100k channels, started when Search appears), and each keystroke then scans them in
  about 5 ms (50 ms for a typo search), 250 ms after the last keystroke. Only the best 150 channels
  and 20 groups are fetched from the store.
- **Library** (`Features/Library/LibraryView.swift`, iOS): the tab with what the user keeps. A first section links
  to Favorites (with their count) and Recently Watched (with the last thing watched), then the offline downloads
  (see [Offline downloads](downloads.md)), then the recordings are listed in place (play, delete; Delete All in the More
  menu). Library replaced the Favorites tab: Favorites already lead Home (a row with See All), so a tab repeated Home,
  while the recordings were only reachable from a Home toolbar button or the player's menu.
- **Copy Link and Share** (`Features/Library/ChannelLinkSharing.swift`) are in every channel menu; Settings › TV
  Guide's Copy Address goes the same way. A link that looks like it carries the account's login (`StreamLink`:
  `user:pass@`, a password or token parameter, an Xtream Codes path) is copied with the warning "Includes your
  account login", stays on this device (`localOnly` on iPhone and iPad, `currentHostOnly` on the Mac: no Universal
  Clipboard) and leaves the clipboard after 2 minutes (`StreamLinkPasteboard.credentialsLifetime`; an expiration
  date on iPhone and iPad; on the Mac it is cleared then if nothing else was copied meanwhile, and it is marked
  concealed for clipboard managers). The toast says so, in the window it was copied in (the Mac's Settings window
  too).
- **macOS** uses a sidebar (Home, TV Guide, Search, a Library section with Favorites, Recently Watched, Downloads
  and Recordings, and each playlist) and a Settings window (Cmd-,). iPhone uses tabs; iPad uses a sidebar-adaptable
  tab view (see [iPad](interface.md#ipad)).
