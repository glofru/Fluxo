# Fluxo demo playlist

[`fluxo-demo.m3u`](fluxo-demo.m3u) is the playlist that Fluxo offers as "Try the Demo Playlist" (first-run screen)
and "Use the Demo Playlist" (Add Playlist), and that App Review uses (`docs/AppStore/review-notes.md`). The app loads
it from `https://raw.githubusercontent.com/glofru/Fluxo/main/docs/demo/fluxo-demo.m3u`, so a stream that stops
working can be replaced here without an app update.

It contains only content that may be streamed freely, from the servers of its owners:

| Entry | Group | Source | License |
|---|---|---|---|
| Live Test Stream | Demo Live | Unified Streaming's public live demo (`demo.unified-streaming.com`), a continuous live HLS stream | Public demo stream of Unified Streaming, offered for testing players |
| Apple HLS Example | Demo Live | Apple's "Advanced stream" HLS example (`devstreaming-cdn.apple.com`), fMP4 with several qualities, audio and subtitles | Apple's sample stream for HLS developers |
| Tears of Steel (2012) | Open Movies · © Blender Foundation, CC BY | Blender Foundation, `download.blender.org` (720p QuickTime) | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/), (c) Blender Foundation, mango.blender.org |
| Sintel (2010) | Open Movies · © Blender Foundation, CC BY | Blender Foundation, `download.blender.org` (1080p Matroska: played through Fluxo's engine) | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/), (c) Blender Foundation, durian.blender.org |
| Elephants Dream (2006) | Open Movies · © Blender Foundation, CC BY | Blender Foundation (Orange Open Movie Project), `download.blender.org` (720p QuickTime) | [CC BY 2.5](https://creativecommons.org/licenses/by/2.5/), (c) Blender Foundation / Netherlands Media Art Institute |

Attribution: the films are by the Blender Foundation (www.blender.org) and are used unchanged. The group name
("Open Movies · © Blender Foundation, CC BY") carries the credit into the app, where the films are listed and
played; this table has the license version of each.

Not used, and why: NASA TV's public stream (retired in 2024, the address returns 404), Google's
`gtv-videos-bucket` sample files (now 403), and the Big Buck Bunny files of blender.org (only zip archives).

## Checking it

Before each App Store submission, check that every address still answers (HTTP 200 or 206):

```sh
grep '^https' docs/demo/fluxo-demo.m3u | while read -r url; do
    printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' -r 0-1000 --max-time 20 "$url")" "$url"
done
```

and play each entry once in the app (Debug harness: `Tools/Simulator/run.sh --seed none --route
"play-url:<address>;wait:8;probe-playback"`, or `play-movie:` for the films).
