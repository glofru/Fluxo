# Series

On-demand entries named like episodes are grouped into series, so a series shows once everywhere (Home's billboard,
rows, category cards and grids, Search, For You, Because You Watched, Continue Watching) and opens its own page.

- **Parsing** (`Features/Series/EpisodeParser.swift`): a scan over the scalars of the name, with a lowercase,
  accent-free copy, about 2 µs per name. Strong markers (a season and an episode) are `S01E02`, `S01 E02`, `s1e2`,
  `S01.E02`, `S01xE02`, `S01 Ep. 02`, `T01E02`, `1x02`, `Season 1 Episode 2`, `Series 2 Episode 3` and the
  localized words (Stagione / Episodio, Staffel / Folge, Temporada / Episodio / Capítulo, Saison / Épisode, Seizoen
  / Aflevering, Sezon / Odcinek / Bölüm, Säsong / Avsnitt, сезон / серия, also as "2. Staffel" or "1 сезон 2
  серия"); double episodes (`S01E01E02`) count as the first. Weak markers (an episode number only: `Episode 12`,
  `Ep. 3`, `E05`, `Folge 5`, `Puntata 6000`) count only for entries that are series by their URL (`/series/`) or
  category, never to turn a movie into a series. The text before the marker becomes the series title, without
  provider prefixes (`IT:`, `|EN|`, `[4K]`, `4K-IT:`; `CSI: Miami` keeps its title), file tags (FHD, 4K, HEVC,
  `[MULTI]`, `SUB ITA`, …) and a year in parentheses, which goes into the key (`Doctor Who (1963)` and
  `Doctor Who (2005)` stay apart); scene names (`Breaking.Bad.S01E01.720p`) read dots as spaces; the text after it
  becomes the episode title. A name with nothing before the marker takes the series title from its category
  (`Series | Breaking Bad`), unless the category only says "Series". Anything else stays a single entry.
- **Model**: each episode keeps its series key and, packed into one attribute (`StoredEpisode`: each attribute of
  a model costs about 0.25 s per 100k inserts), its series title, season, number and title on its `PlaylistChannel`, and
  `isListed` is false for every episode but the first of its series in its category (that "head" stands for the
  series in the category's rows and grids; every listing query filters on it, so paging, orders, the A–Z index and
  counts are unchanged). `PlaylistSeries` sums up a series of an import (title, year, artwork of the first episode
  with a poster, category, first and last position, episode and season counts); groups know their `listedCount`
  and `seriesCount` ("3 series · 30 episodes"). `SeriesBookmark` (playlist + series key, so it survives refreshes,
  deleted with its playlist) keeps the favorite, the episode watched last and the episodes watched. The resume
  position of each episode stays on its `ChannelBookmark`, as for movies.
- **Existing libraries**: imports stored before series existed (or by an older `EpisodeParser.version`) are grouped
  at launch on a background context (`SeriesIndexer`, about 1 to 4 s for 100k entries); their favorites and history
  are linked to their series and episodes watched to the end count as watched. The store migrates by itself (new
  attributes have defaults).
- **Series page** (`SeriesDetailView`): the poster on a blurred backdrop, the title, year and counts, Continue (resume
  the episode watched last, else play the next unwatched one, else Watch Again), favorite, Mark Series as Watched /
  Unwatched, the seasons as chips (Specials last, a checkmark on watched seasons), and the episodes with their
  number, title, watched state, progress and time left; Up Next is highlighted. An episode's menu has Resume / Play
  from Beginning, Mark as Watched / Unwatched, Mark Watched Up to Here and its own favorite.
- **Tracking**: playing an episode makes it the series' last episode; playing it to the end (the last 3 %) marks it
  watched. Continue Watching shows a series once: the episode that stopped part-way, or "Up Next" with the next
  episode. In the player, an episode longer than 5 minutes shows Next Episode during its credits, and its end
  shows the next episode with an 8 s countdown (Cancel, Play Again; no countdown with VoiceOver or Switch Control).
  On iPad and the iPhone Duo the player's channel list shows the series' episodes while an episode plays.
- **Search** lists a series once, with its counts, when its title or one of its episodes ("Ozymandias") matches; its
  episodes are on its page. Recommendations (For You, smart search, Because You Watched) suggest series as a whole.
- **For App Intents** (`SeriesLookup`, off the main actor, values only): `series(matching:importIDs:limit:in:)`,
  `episodes(of:in:)`, `episodeToPlay(for:in:)` (where the viewer left off) and `nextEpisode(after:in:)`.

To check the parser on 100+ real-world names, an import of 100k entries with series, the series queries (timings)
and the migration and backfill of a store written by the previous version:

```sh
Tools/SeriesCheck/run.sh              # ENTRIES=20000 for a quicker run, PARSER_ONLY=1 for the parser only
```

To check every Home and Search query against an on-disk store (100k channels), including the token
search (matches, ranking, typos) and its timings:

```sh
CHANNELS=100000 Tools/HomeQueriesCheck/run.sh
```

To check the featured billboard and the adult-content filter: the classifier on about 200 names that are or only look
like adult content (in many languages and scripts), the title keys, the picker on synthetic categories (one page per
category, title and franchise, kinds interleaved, the same pages for a seed, the taste, adult content left out unless
it is all there is), the rotation, and the loader on an on-disk store:

```sh
Tools/FeaturedCheck/run.sh            # FILLER=100000 for a larger store
```
