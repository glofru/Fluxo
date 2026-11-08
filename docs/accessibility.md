# Accessibility

The building blocks are in `Fluxo/App/Accessibility` (`AccessibilitySupport.swift`: stacked layouts, card
scaling, the Large Content Viewer, Smart Invert, Button Shapes, announcements; `ChannelAccessibility.swift`:
what every channel card and row says and offers), the player's in `Features/Player/PlayerAnnouncements.swift`
and `Features/Player/MediaSelection.swift`, and the colors in `App/Design/Theme.swift`.

- **VoiceOver**: every card and row is one element that says the number, name, kind, favorite state, the
  programme on air (from the guide) or the time left of a movie, and plays when activated. Its custom actions
  (Actions rotor) add or remove the favorite, open the channel's schedule, play and record (live channels the
  remux engine records) and play from the beginning. Section titles are headings; long lists have a
  Favorites rotor, the guide grid a Channels rotor (each row is a container named after its channel, its
  programmes say their time, "On now, 20 min left" or "Ended", with Watch and Remind Me actions). The player
  is modal (VoiceOver stays in it), focuses the channel name when it opens, answers Magic Tap (play / pause)
  and the escape gesture (close); its scrubber is adjustable and says the position, or the time behind live.
  The mini player is a "Mini Player" container whose title opens the player. VoiceOver hears what the player
  does on its own, wherever the user is: the channel that starts ("Sky Sport F1, live"), buffering or
  connecting that lasts more than 2 s, reconnecting, failures (high priority), the end, recording started /
  stopped / failed, back to live and Cast. Search says how many results a query found.
- **Dynamic Type** up to AX5: rows, headers (See All moves under the title), the billboard, Settings and its rows
  (`SettingsLabel`: the tile above the title), the Library rows, the Continue Watching and On Now cards stack at
  the accessibility sizes, so a label has the whole width and a word that fits a line is not broken into syllables
  ("Favo-riten"); cards of the horizontal rows grow (`CardScale`) and their titles get more lines; segmented
  pickers become menus; the guide switches to a list of channels with now / next (Automatic layout; Grid and List
  can be chosen in its menu; Home's Live TV / Movies / Series menu has a label of its own, which the system's menu
  picker split inside a word). Switches of Settings and Diagnostic Reports go under their labels
  (`.switchAdaptingToTextSize`), and a row of a title and a detail puts its symbol above them (`DetailLabel`), so
  the label has the row's width instead of a narrow column next to the switch ("Per-sönli-che"). A form's menu
  pickers (Video Quality, Skip back, Remind Me…) are menus with the chosen value under the label, wrapping
  (`FormMenuPicker`): the system's picker cut it in the middle ("Hoc…80p)"). Empty states
  wrap their titles (`EmptyStateLabel`, `ContentUnavailableView(wrapping:…)`: the system's title was cut, "Playlists
  dur…"). A sheet's confirm button is the system's checkmark (`ConfirmToolbarButton`), so the sheet's title keeps
  the bar ("Playlist hinzu…"); the address field of Add Playlist has its buttons under it. The actions of a
  programme's sheet and of the next-episode card take the whole width, one under the other, with one-line titles
  (up to AX3, then the Large Content Viewer). The category browser shows as many columns of at least 380 pt as fit
  (one on an iPhone); below the accessibility sizes its columns are as wide as its cards have grown (`CardScale`), so
  a large standard size (xxxLarge on iPad) shows fewer of them. Home's horizontal rows (`CardRow`) are as tall as
  their tallest card there, so every name gets its lines (a lazy row took the height of its first card and cut the
  others: "Test Str…"), and a section header puts its symbol above its title and subtitle. The time line of a
  programme's sheet moves the day, the range and the length to the next line whole (a range wider than the line
  starts a line of its own and breaks after its dash), and its channel logo grows. See All drops its count when both
  do not fit on its line, and the time range of what is on now in the player's top bar shows only whole (it was cut
  to "5"); VoiceOver reads both in any case. Section and row subtitles (For You, Library) are never cut there. Large
  titles (Library, Settings, Search…) become inline titles there
  (`largeTitleAdaptingToTextSize()`): a large title is one line that is cut ("Einstellung…"). The billboard grows
  to the height its tallest page needs, its pages' content then starts at the top (so a shorter page's Play is in
  view first), and it pages back into place when its width changes (a rotation). The Play button of the billboard
  and of a series page (`HeroActions`) shares its row with the round buttons while its title fits on one line,
  else it takes the whole width with them under it; its title is always one line (up to AX3, then the Large
  Content Viewer). Controls that keep their size (the player's buttons, the mini player) show in the Large Content
  Viewer; the player's text grows up to AX2. The player's messages (an error, offline, the end, the next episode)
  stay between its top bar and its controls as they are laid out (`PlayerChromeClearance`), never under them: when
  the card does not fit, only its message scrolls, its title and buttons always show (on a phone in landscape,
  where the room between the bars is lowest, the card's text grows up to AX1). The scrolling message shows whole
  lines only (never a line cut through its glyphs), fades out over its last line when there is more, and is left
  out of the card, read by VoiceOver with the title, when not even one line fits; the card's buttons keep their
  titles on one line (they shrink a little, the Large Content Viewer shows them whole), and the card is wider
  where the player is wide (an iPad) at the accessibility sizes.
- **Lines of parts** (`TextParts.line`): the space before a separator (the app's ·, a provider's " | " or " - ")
  is a no-break space, so a wrapped line never starts with one ("| Drama"); the series page and the billboard
  leave out a category's kind prefix that repeats what the page says ("Serie TV | Drama" under Series is "Drama",
  `ChannelContentKind.category(fromGroupName:)`). A series' counts keep each number with its noun ("10 Folgen",
  `TextParts.keepingWordsTogether`). At the accessibility sizes such a line (the series page's "2021 · 2 Staffeln ·
  10 Folgen · Sci-Fi", the Downloads row of Settings) is `PartsLine`: a `Text` per part with the separator at its
  end (`TextParts.flowPieces`), laid out as a flow (`FlowLayout`, mirrored right to left), so a part moves to the
  next line whole instead of being hyphenated ("2 Staf-feln"); one wider than the line is a line of its own and
  wraps between its words.
  Below them it is one `Text`, as before. Running text (descriptions, footers) is still hyphenated by the system
  where a word does not fit the rest of a line, as everywhere in iOS; a single word wider than the whole line
  ("Synchronisieren" at AX5) can only be hyphenated.
- **Contrast** (WCAG 2.2 AA, measured in `Theme.swift`): text and thin glyph colors pass 4.5:1 on the
  backgrounds of their mode, icons 3:1; white text sits on fill colors that pass in both modes
  (`accentFill`, `liveFill`, `cyanFill`, `favoriteFill`). Secondary and tertiary text use `Theme.secondaryText`
  and `Theme.tertiaryText` (about 5.6:1 and 4.6:1 on white) instead of the system's `.secondary` and
  `.tertiary` (3.4:1 and 1.9:1).
  Every color asset has an Increase Contrast variant; hairlines, the timeline track, labels and scrims over
  video get stronger with it, and the LIVE badge gets a border.
- **Reduce Motion** (no zooms, pulses or autoplaying animations), **Reduce Transparency** (opaque scrims and
  backdrops; Liquid Glass adapts by itself), **Differentiate Without Color** (a checkmark on the selected
  chip, a live symbol and a thicker border on the guide's programme on air), **Button Shapes** (`See All`,
  `TV Guide` get a shape), **Smart Invert** (artwork, logos and video keep their colors).
- **Subtitles, captions and audio tracks**: the player's Audio and Subtitles button (and Playback > Audio and
  Subtitles) lists what the item has: HLS renditions, MP4 tracks, CEA-608 captions. Audio descriptions are
  marked AD, SDH subtitles and closed captions too. Automatic follows the system (Subtitles & Captioning,
  Audio Descriptions, languages), and the AVPlayerLayer draws captions in the system caption style.
- **Voice Control** names for icon buttons ("Close", "Stop", "Subtitles") and channels (the name without its
  provider prefix and quality tags: "Tap Sky Sport F1"). **Keyboard**: Go menu (⌘1 Home, ⌘2 TV Guide,
  ⌘3 Favorites, ⌘4 Recently Watched, ⌘5 Recordings, ⌘6 Settings on iPad, ⌘F Search), the Playback menu (space, ⌘← / ⌘→, ⌘↑ / ⌘↓,
  ⌘L, ⇧⌘R, ⌘.), Escape closes the player; the player's controls never hide while an assistive technology
  (VoiceOver, Switch Control, Voice Control, Full Keyboard Access) is on.

## Audit

`Tools/Simulator/accessibility-audit.sh` runs the Xcode accessibility audit (`performAccessibilityAudit`) on
15 screens in three variants of a simulator (default, AX5, dark with Increase Contrast) and writes one report
per variant (see `Tools/Simulator/README.md`); `testMediaSelectionMenu` checks the Audio and Subtitles menu
with the test streams. Manual checks before a release, on a device:

1. VoiceOver: Home to a channel and back, the Actions rotor of a card (Favorite, Schedule, Play and Record),
   the Channels rotor of the guide, the player (focus on open, Magic Tap, scrubber, escape), the mini
   player, the announcements when a channel buffers, fails and records.
2. Settings > Accessibility > Display & Text Size > Larger Text at the largest size: every tab, a category,
   the player; nothing is clipped, long press the player's buttons for the Large Content Viewer.
3. Increase Contrast, Reduce Transparency, Differentiate Without Color, Button Shapes, Smart Invert and
   Reduce Motion, one at a time, on Home, the guide and the player.
4. Subtitles & Captioning > Closed Captions + SDH, and a caption style: a stream with captions shows them
   in that style; Audio Descriptions picks the AD track.
5. Voice Control ("Show names", "Tap Sky Sport F1", "Tap Stop") and Full Keyboard Access (Tab through Home,
   ⌘1–⌘6 and ⌘F, space in the player); on the Mac, keyboard navigation of the sidebar and VoiceOver.
6. Right-to-left (`-NSForceRightToLeftWritingDirection YES`): rows, cards and the player mirror (the
   layouts use leading / trailing only).
