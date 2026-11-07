# Offline downloads

Movies and episodes (never live channels) download to watch without a network (`Features/Downloads`).

- **Where**: Download in every movie and episode menu (cards, rows, the series page), a download button on each
  episode of a series page, and Download Season above its episodes (a tap downloads the episodes not downloaded yet;
  its menu pauses or deletes the season). Cards and rows show a downloaded arrow, or a progress ring while it
  downloads; series cards how many episodes are downloaded.
- **How** (`DownloadProbe`, `DownloadTransport`): the first 4 KB of the link are read (a ranged request) and the
  content is recognized by its signature, then its type and extension, since IPTV links are often extensionless:
  - HLS goes through `AVAssetDownloadURLSession` with an `AVAssetDownloadConfiguration`: the variant of the Video
    Quality setting (Best, up to 1080p, 720p or 480p; the size is estimated from its bit rate and the duration), the
    audio renditions in the user's languages and every subtitle, so Audio and Subtitles still switch offline (the
    player's menu lists only what was downloaded, `AVAssetCache`). The `.movpkg` stays where AVFoundation puts it,
    stored relative to the home folder (the container moves with updates), with the `important` storage priority.
  - MP4 / MOV / M4V / MP3 / AAC download as they are in a background `URLSession`.
  - What AVPlayer cannot play (Matroska / WebM, AVI, WMV, Ogg, MPEG-TS, FLV, MPEG-PS) downloads the same way, then the
    remux engine copies it into an MP4 (`fluxo_remux_convert_file`; video and audio, not the subtitles), converting the
    streams AVPlayer does not decode (DTS audio, Xvid video, ...: see [Formats](player.md#formats)), so it plays and seeks like any file.
    A file whose video the engine can neither copy nor convert (AV1 without an AV1 decoder) fails at the conversion with
    "This video format can't be played on this device"; links that return a web page are refused.
- **Queue**: two transfers at a time, the others wait in order; pause (file transfers keep resume data and continue
  where they stopped, HLS tasks are suspended), resume, cancel, retry, delete; Pause All / Resume All. Network failures
  are retried three times from where they stopped, and again when the network returns; a refused or vanished link
  (401, 403, 404, 410: expired tokens or credentials) is looked up again in the current copy of the playlist before it
  fails. The free space is checked first (the size, twice it for a file that is converted, plus 500 MB).
- **In the background**: the transfers run in background sessions, so they continue while the app is suspended or
  terminated; iOS relaunches the app to deliver their results (`backgroundTask(.urlSession(matching:))`) and the
  transfers that survived a relaunch are adopted at launch. An interrupted conversion starts again at the next launch.
- **Settings › Downloads**: Use Cellular Data (off by default; each kind of transfer has a session that may and one
  that may not use cellular data, and running transfers move when it changes), Video Quality, Delete Watched Downloads
  (a download played to the end is deleted once something else plays), Download Next Episode (finishing a downloaded
  episode downloads the next one), the space used and Delete All Downloads.
- **Offline playback**: a download is keyed like a bookmark (playlist + stream URL), so a downloaded movie or episode
  plays from its file wherever it is started (a card, Continue Watching, the series page, Siri), with its resume
  position, watched state and series progress; Chromecast still gets the stream URL.
- **Library**: Downloading (progress, size, time left, "Waiting for Wi-Fi" or "Waiting for a network connection"),
  then the downloads: movies one per row, a series as one row with its episodes behind it (by season), the first five
  with See All. Each keeps its artwork (shown offline), size, duration, quality and languages. The Mac sidebar has a
  Downloads entry. A download whose media the system removed (storage pressure) says so and offers Download Again.
- **Offline**: `NetworkMonitor` (`NWPathMonitor`) knows when the device has no network at all. Home then says "You're
  Offline" with the downloads first, the player says at once that something that is not downloaded needs a connection
  (and starts it when the network returns) instead of spinning until a timeout, and the TV guide refreshes wait for the
  network. Everything else (playlists, guide, artwork in the logo cache) comes from the device.
- **Storage**: files in `Application Support/Downloads/<id>/` (excluded from device backups: they can be downloaded
  again), the manifest in `Downloads/downloads.json` (not SwiftData: it describes files and must survive a reset of
  the library store). Downloads are deleted with their playlist.
- **The manifest outlives builds** (`DownloadManifest`): records are decoded one by one and each field leniently
  (`DownloadRecord.init(from:)`): a field an earlier build did not write takes its default, a value of a later build
  (a state, a method, a failure reason) is read as failed, to probe again, an unexpected stop; only a record without
  its id or link is left out of the list shown, and every save writes it back with all its fields, so a later build
  still reads it. A file that is not a list at all is kept next to it (`downloads.unreadable-<date>.json`, the newest
  three) before the next save replaces it, and a file that cannot be opened (locked, an I/O error) is never replaced.
  The folders whose owner is unknown (every download folder found while the file was not a list, the folders of
  records this build cannot read) are listed in `downloads.kept-folders.json` before any save, so they stay protected
  at later launches, after the list that named them is gone; an id leaves it once its folder is gone or a readable
  record owns it, which only a listing of the folder tells: while the folder cannot be listed, the kept list only
  grows, and a list lost meanwhile is noted in it (`"*"`: every folder found at the next listing is kept). At launch,
  folders of downloads no record owns (a crash between adding a download and saving the list) are deleted, never a
  kept one, and only when the folder could be listed and every record was read or told its id. A transfer that ends
  while no one listens (a background relaunch while the library opens, upgrades or waits for the first unlock) keeps
  its file: the transport queues the events that change a record until `DownloadCenter` attaches, and at launch a
  download whose file already arrived is kept instead of downloaded again. Transfers of records this build cannot
  read are left running for the build that owns them. `Tools/LibraryCheck` checks it on fixtures, across saves and
  relaunches, also with a folder that cannot be listed.
- **Failures** (`DownloadFailure`): the Library lists failed downloads in their own section, Couldn't Download (with
  Retry All), each with the whole reason and a Retry button when retrying can help. The reasons are sentences, never a
  bare system error: an unknown URL error ("unknown error", the most common one from AVFoundation) is "The download
  stopped unexpectedly", a broken response, a file that cannot be written and a full disk have their own, and the
  "unknown error" texts earlier builds stored read as the same sentence, as does Foundation's text for an error without
  a description ("The operation couldn’t be completed. (… error -1.)"), recognized in any language by its domain and
  code.
- **Simulator**: background HLS downloads need a signed app (an unsigned build fails with "does not have write access
  to destination directory"); `Tools/Simulator/build.sh` builds unsigned, so build the simulator app with
  `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual` to try them. See the download routes in `Tools/Simulator/README.md`.
