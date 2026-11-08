# App Store listing

Drafts of the App Store texts, in English (U.S.) and Italian, to paste into App Store Connect › the app's page ›
each localization. Limits: name and subtitle 30 characters, promotional text 170, keywords 100 bytes (commas, no
spaces after them), description 4,000. The counts in parentheses are characters (keywords: bytes), counted with Python.

Rules the texts follow (App Review 2.3 and 5.2, `legal-review.md`):

- Fluxo plays what the user adds: no channel, film or broadcaster is named or promised, and the description says
  that Fluxo provides no content.
- No other company's trademark in the keywords (Apple's guideline 2.3.7). Chromecast and AirPlay appear only in the
  description, to say what Fluxo works with.
- Only what the app does on each platform: Apple Intelligence on iPhone, iPad and Mac (not Apple TV), Chromecast on
  iPhone and iPad, iCloud sync on iPhone, iPad and Apple TV (the Mac build has no iCloud container yet: say "Mac"
  for sync only once it has, see `README.md`).
- The words of the screenshots (`Design/AppStore/copy.json`) and of the privacy policy (`../privacy.md`).

The screenshots are in `Design/AppStore/` (see its README).

## English (U.S.)

**Name** (19): `Fluxo – IPTV Player`

**Subtitle** (29): `Live TV, your way. Privately.`

**Promotional text** (159):

```
Your playlists and TV guide in one beautiful player, with Apple Intelligence on the device. No account, no tracking,
no ads. Open source under the MIT License.
```

**Keywords** (99 bytes; not "iptv", already a word of the name, which the App Store indexes too):

```
m3u,m3u8,xmltv,epg,tv guide,live tv,video player,playlist,dvr,recorder,timeshift,streaming,channels
```

**Description** (about 2,500 characters):

```
Fluxo is a player for the IPTV playlists (M3U) and TV guides (XMLTV) you add, on iPhone, iPad, Mac and Apple TV.
It brings your live channels, movies and series together in one clean, fast app with a Liquid Glass design, and it
keeps everything on your device: no account, no tracking, no ads.

LIVE TV WITH A REAL TV GUIDE
• See what’s on now and next from your XMLTV guides, matched to your channels automatically
• Browse the guide day by day and set reminders for the start of a programme
• Pause and rewind live TV, and switch channels without leaving the player

MOVIES AND SERIES
• Series grouped by season and episode, with Up Next
• Every movie and episode resumes where you stopped
• Continue Watching and Favorites on Home, and in the Top Shelf on Apple TV

RECORDINGS AND DOWNLOADS
• Record live channels and watch the recordings later
• Download movies and episodes to watch offline

FLUXO INTELLIGENCE
• Recommendations picked for you by Apple Intelligence, on the device
• Search the way you speak: “sports tonight”, “italian news channels”, “something like this channel”
• Short summaries of long programme descriptions
On iPhone, iPad and Mac with Apple Intelligence; built-in recommendations and smart search work everywhere else.

PLAYS ALMOST ANYTHING
• HLS, MPEG-TS, Matroska, MP4, AVI, WMV, RTMP, RTSP and more, through its own FFmpeg-based engine
• Audio tracks and subtitles, including your own subtitle files
• Picture in Picture, AirPlay, and Chromecast on iPhone and iPad

SIRI AND SHORTCUTS
• “What’s on in Fluxo?”, “Continue watching in Fluxo”, play a channel by name
• Record, set reminders and add favorites with your voice or in Shortcuts
• Voice search with the Siri Remote on Apple TV

EVERY SCREEN
• iPhone, iPad (with the guide beside the video), Mac and Apple TV
• Your playlists, favorites and history in sync on iPhone, iPad and Apple TV through your private iCloud database

PRIVACY FIRST
Fluxo has no server and no account. It collects nothing about you: no analytics, no tracking, no advertising.
Apple Intelligence runs on the device. iCloud sync uses your own private iCloud database, and stream addresses are
encrypted on the device before they are sent.

OPEN SOURCE
Fluxo is open source under the MIT License. Read the code, build it yourself and help make it better:
github.com/glofru/Fluxo

Fluxo doesn’t provide any channels or content. Add only playlists from providers you subscribe to or have the right
to use. To try it, tap “Try the Demo Playlist” on the first screen.
```

## Italiano

**Nome** (19): `Fluxo – IPTV Player`

**Sottotitolo** (29): `La tua TV, in modo riservato.`

**Testo promozionale** (164):

```
Le tue playlist e la guida TV in un player bellissimo, con Apple Intelligence sul dispositivo. Nessun account, nessun
tracciamento, nessuna pubblicità. Open source.
```

**Parole chiave** (99 byte; not "iptv", a word of the name):

```
m3u,m3u8,xmltv,epg,guida tv,tv in diretta,lettore video,playlist,registrazione,dvr,streaming,canali
```

**Descrizione** (circa 2.650 caratteri):

```
Fluxo è un player per le playlist IPTV (M3U) e le guide TV (XMLTV) che aggiungi tu, su iPhone, iPad, Mac e Apple TV.
Riunisce i tuoi canali in diretta, i film e le serie in un’app pulita e veloce, con un design Liquid Glass, e tiene
tutto sul tuo dispositivo: nessun account, nessun tracciamento, nessuna pubblicità.

LA DIRETTA, CON UNA VERA GUIDA TV
• Cosa va in onda ora e dopo dalle tue guide XMLTV, abbinate ai tuoi canali in automatico
• Sfoglia la guida giorno per giorno e imposta un promemoria per l’inizio di un programma
• Metti in pausa e riavvolgi la diretta, e cambia canale senza lasciare il player

FILM E SERIE
• Serie raggruppate per stagione ed episodio, con il prossimo da vedere
• Ogni film ed episodio riparte da dove ti eri fermato
• Continua a guardare e Preferiti nella Home, e nella Top Shelf di Apple TV

REGISTRAZIONI E DOWNLOAD
• Registra i canali in diretta e guarda le registrazioni quando vuoi
• Scarica film ed episodi da guardare offline

FLUXO INTELLIGENCE
• Consigli scelti per te da Apple Intelligence, sul dispositivo
• Cerca come parli: «sport stasera», «canali di notizie italiani», «qualcosa come questo canale»
• Brevi riassunti delle descrizioni lunghe dei programmi
Su iPhone, iPad e Mac con Apple Intelligence; consigli e ricerca intelligente integrati funzionano ovunque.

RIPRODUCE QUASI TUTTO
• HLS, MPEG-TS, Matroska, MP4, AVI, WMV, RTMP, RTSP e altro, con il suo motore basato su FFmpeg
• Tracce audio e sottotitoli, anche i tuoi file di sottotitoli
• Picture in Picture, AirPlay e Chromecast su iPhone e iPad

SIRI E COMANDI RAPIDI
• «Cosa c’è su Fluxo?», «Continua a guardare su Fluxo», riproduci un canale per nome
• Registra, imposta promemoria e aggiungi preferiti con la voce o con Comandi Rapidi
• Ricerca vocale con il Siri Remote su Apple TV

SU OGNI SCHERMO
• iPhone, iPad (con la guida accanto al video), Mac e Apple TV
• Playlist, preferiti e cronologia sincronizzati su iPhone, iPad e Apple TV tramite il tuo database iCloud privato

PRIVACY PRIMA DI TUTTO
Fluxo non ha server né account. Non raccoglie nulla su di te: niente analisi, niente tracciamento, niente pubblicità.
Apple Intelligence lavora sul dispositivo. La sincronizzazione iCloud usa il tuo database iCloud privato, e gli
indirizzi degli stream sono crittografati sul dispositivo prima di essere inviati.

OPEN SOURCE
Fluxo è open source con licenza MIT. Leggi il codice, compilalo da te e aiutaci a migliorarlo:
github.com/glofru/Fluxo

Fluxo non fornisce canali né contenuti. Aggiungi solo playlist di provider a cui sei abbonato o che hai il diritto di
usare. Per provarlo, tocca «Prova la playlist demo» nella prima schermata.
```

## Before pasting

- "Try the Demo Playlist" has no Italian translation yet (`Localizable.xcstrings`): once the translation sweep adds
  it, use the app's words in the last sentence of the Italian description («Prova la playlist demo» is a placeholder).
- Once the Mac build syncs with iCloud, the descriptions may say so for the Mac too.
- What's New: write it per release.
