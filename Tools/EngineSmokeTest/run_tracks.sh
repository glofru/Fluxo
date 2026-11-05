#!/bin/sh
# Audio tracks and subtitles of the remux engine (macOS, bundled FFmpeg.xcframework):
#
# 1. On demand: a generated Matroska file with two audio tracks (AAC English, AC-3 Italian), SubRip and ASS
#    subtitles and forced subtitles is remuxed; the master playlist, the renditions and the WebVTT segments
#    are checked, then AVPlayer plays the master playlist through a loopback-only HTTP server
#    (tracks_check.swift: options listed, audio switch, cues at the right time, seek).
# 2. Live: an MPEG-TS stream with three audio tracks (AAC English, AC-3 German, MP2 French, as DVB channels
#    have) is served on 127.0.0.1 and remuxed with a reconnection in the middle; AVPlayer plays the master
#    playlist. MP2 is not an HLS codec (AVPlayer on iOS fails on it), so only English and German are offered.
# Needs ffmpeg / ffprobe (test-only, see Tools/FFmpeg/env.sh).
set -eu
PORT=${PORT:-18931}
HTTP_PORT=${HTTP_PORT:-18932}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/Tools/FFmpeg/env.sh"
WORK=$(mktemp -d /tmp/fluxo-tracks-test.XXXXXX)
BIN="$WORK/engine-smoke-test"
MEDIA="$WORK/media"
mkdir -p "$MEDIA" "$WORK/vod" "$WORK/live"

# shellcheck disable=SC2086 # FFMPEG_CFLAGS / FFMPEG_LDFLAGS / FLUXO_ENGINE_SOURCES are lists of words.
clang -O1 -g -Wall -Wextra -o "$BIN" -I "$ROOT/Fluxo/Features/Player/Engine" $FFMPEG_CFLAGS \
    "$ROOT/Tools/EngineSmokeTest/main.c" $FLUXO_ENGINE_SOURCES \
    $FFMPEG_LDFLAGS

cleanup() {
    kill "${SERVER_PID:-0}" "${ENGINE_PID:-0}" "${HTTP_PID:-0}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cat > "$MEDIA/en.srt" <<'SRT'
1
00:00:01,000 --> 00:00:04,000
Hello from the <i>English</i> subtitles.

2
00:00:05,000 --> 00:00:09,500
Second line & more
over two lines

3
00:00:12,000 --> 00:00:16,000
Cue at twelve seconds

4
00:00:20,000 --> 00:00:30,000
A long cue across segments
SRT
cat > "$MEDIA/it.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.50,0:00:04.00,Default,,0,0,0,,Ciao dai {\i1}sottotitoli{\i0} italiani
Dialogue: 0,0:00:06.00,0:00:10.00,Default,,0,0,0,,Prima riga\NSeconda riga
Dialogue: 0,0:00:14.00,0:00:18.00,Default,,0,0,0,,{\an8}In alto, a quattordici secondi
ASS
printf '1\n00:00:07,000 --> 00:00:09,000\n[SIGN: Forced text]\n' > "$MEDIA/forced.srt"

"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -f lavfi -i "sine=frequency=880:sample_rate=48000" \
    -i "$MEDIA/en.srt" -i "$MEDIA/it.ass" -i "$MEDIA/forced.srt" -t 40 \
    -map 0:v -map 1:a -map 2:a -map 3 -map 4 -map 5 -c:v libx264 -preset ultrafast -g 50 -bf 2 \
    -c:a:0 aac -b:a:0 96k -c:a:1 ac3 -b:a:1 128k -c:s:0 srt -c:s:1 ass -c:s:2 srt \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title=English -metadata:s:a:1 language=ita \
    -metadata:s:a:1 title=Русский -metadata:s:s:0 language=eng -metadata:s:s:1 language=ita \
    -metadata:s:s:1 title=Café -metadata:s:s:2 language=eng \
    -disposition:a:0 default -disposition:a:1 0 -disposition:s:0 0 -disposition:s:1 0 -disposition:s:2 forced \
    "$MEDIA/movie.mkv"

echo "=== on demand (Matroska)"
"$BIN" "$MEDIA/movie.mkv" "$WORK/vod" 8 0 0 0 vod | grep -v "segment written" | grep -v "convert ret" || true
cat "$WORK/vod/stream-test-master.m3u8"
# Titles that end in a multi-byte character are kept whole (the NAME of the rendition).
for NAME in 'NAME="Русский"' 'NAME="Café"'; do
    if grep -q "$NAME" "$WORK/vod/stream-test-master.m3u8"; then echo "ok: $NAME"; else echo "FAIL: no $NAME"; fi
done
echo "--- WebVTT segment 6 of the English subtitles"
cat "$WORK/vod/stream-test-s0-000006.vtt"
echo "--- first timestamps of the main and the Italian audio segments (both 2.4 s: the 1 s timestamp base and the 1.4 s muxing delay)"
"$FFPROBE" -v error -show_entries packet=pts_time,stream_index -of compact=p=0 -read_intervals "%+#2" "$WORK/vod/stream-test-000000.ts"
"$FFPROBE" -v error -show_entries packet=pts_time -of compact=p=0 -read_intervals "%+#1" "$WORK/vod/stream-test-a1-000000.ts"

# Loopback only.
python3 -I -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK/vod" > "$WORK/http-vod.log" 2>&1 &
HTTP_PID=$!
sleep 1
lsof -nP -iTCP:"$HTTP_PORT" -sTCP:LISTEN | tail -n 1
swift "$ROOT/Tools/EngineSmokeTest/tracks_check.swift" "http://127.0.0.1:$HTTP_PORT/stream-test-master.m3u8" "Second line" "twelve"
kill "$HTTP_PID" 2>/dev/null || true
wait "$HTTP_PID" 2>/dev/null || true

echo "=== live (MPEG-TS, AAC + AC-3 + MP2 audio, reconnection)"
serve() {
    "$FFMPEG" -hide_banner -loglevel error -re \
        -f lavfi -i "testsrc2=size=640x360:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -f lavfi -i "sine=frequency=660:sample_rate=48000" -f lavfi -i "sine=frequency=550:sample_rate=48000" \
        -map 0:v -map 1:a -map 2:a -map 3:a -c:v libx264 -preset ultrafast -tune zerolatency -g 25 \
        -c:a:0 aac -b:a:0 96k -c:a:1 ac3 -b:a:1 128k -c:a:2 mp2 -b:a:2 128k \
        -metadata:s:a:0 language=eng -metadata:s:a:1 language=deu -metadata:s:a:2 language=fra \
        -f mpegts -listen 1 "http://127.0.0.1:$PORT/live.ts" &
    SERVER_PID=$!
}
serve
sleep 1
"$BIN" "http://127.0.0.1:$PORT/live.ts" "$WORK/live" 45 0 0 60 > "$WORK/live/engine.log" 2>&1 &
ENGINE_PID=$!
python3 -I -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK/live" > "$WORK/http-live.log" 2>&1 &
HTTP_PID=$!
sleep 10
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
sleep 3
serve
sleep 6
cat "$WORK/live/stream-test-master.m3u8"
if grep -q 'LANGUAGE="fr"' "$WORK/live/stream-test-master.m3u8"; then echo "FAIL: the MP2 track is offered"; fi
grep -E "DISCONTINUITY|MEDIA-SEQUENCE" "$WORK/live/stream-test-a1.m3u8" | head -n 3
lsof -nP -iTCP -sTCP:LISTEN | grep -E ":($PORT|$HTTP_PORT) " || true
NO_SUBTITLES=1 swift "$ROOT/Tools/EngineSmokeTest/tracks_check.swift" "http://127.0.0.1:$HTTP_PORT/stream-test-master.m3u8" || true
wait "$ENGINE_PID" || true
grep -v "segment written" "$WORK/live/engine.log" | head -n 12
echo "404s: $(grep -c ' 404 ' "$WORK/http-live.log" || true)"
echo "work directory: $WORK"
