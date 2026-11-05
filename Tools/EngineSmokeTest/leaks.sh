#!/bin/sh
# Leak and footprint check of the remux engine (macOS, bundled FFmpeg.xcframework).
#
# Serves a live MPEG-TS test pattern on 127.0.0.1 only, runs CYCLES engine sessions of SECONDS
# each under `leaks --atExit` (FOOTPRINT_ONLY=1: without it), and prints the footprint after every cycle and the leaks report.
# Then CYCLES on-demand sessions of each of four 60 s movies (MPEG-TS H.264, planned every 4 s; MPEG-TS HEVC with
# ADTS AAC, fragmented MP4 output; the same in Matroska with a second audio track and subtitles, over HTTP on
# 127.0.0.1) with in-order, forward and backward segment requests and a cache small enough to evict segments.
set -eu

PORT=${PORT:-18925}
HTTP_PORT=${HTTP_PORT:-18926}
CYCLES=${CYCLES:-12}
SECONDS_PER_CYCLE=${SECONDS_PER_CYCLE:-4}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/Tools/FFmpeg/env.sh"
WORK=$(mktemp -d /tmp/fluxo-engine-leaks.XXXXXX)
BIN="$WORK/engine-churn"

# shellcheck disable=SC2086 # FFMPEG_CFLAGS / FFMPEG_LDFLAGS are lists of words.
clang -O1 -g -Wall -Wextra -o "$BIN" \
    -I "$ROOT/Fluxo/Features/Player/Engine" $FFMPEG_CFLAGS \
    "$ROOT/Tools/EngineSmokeTest/churn.c" "$ROOT/Fluxo/Features/Player/Engine/FluxoRemuxEngine.c" \
    $FFMPEG_LDFLAGS

cleanup() {
    kill "${LOOP_PID:-0}" "${HTTP_PID:-0}" 2>/dev/null || true
    pkill -f "127.0.0.1:$PORT/live.ts" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# On-demand inputs (local files: the engine treats them like any seekable input).
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25:duration=60" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=60" \
    -c:v libx264 -preset ultrafast -g 50 -c:a aac -b:a 96k -f mpegts "$WORK/vod-h264.ts"
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25:duration=60" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=60" \
    -c:v libx265 -preset ultrafast -x265-params keyint=60:log-level=error -c:a aac -b:a 96k -f mpegts "$WORK/vod-hevc.ts"
# Matroska with two audio tracks and subtitles (renditions; MPEG-TS and fragmented MP4 audio), served over HTTP
# on 127.0.0.1 (the engine's own AVIOContext for on-demand HTTP inputs).
printf '1\n00:00:01,000 --> 00:00:04,000\nOne\n\n2\n00:00:30,000 --> 00:00:34,000\nTwo\n' > "$WORK/vod.srt"
for codec in h264 hevc; do
    "$FFMPEG" -hide_banner -loglevel error -y -i "$WORK/vod-$codec.ts" -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=60" -i "$WORK/vod.srt" \
        -map 0:v -map 0:a -map 1:a -map 2 -c:v copy -c:a:0 copy -c:a:1 ac3 -c:s srt "$WORK/vod-$codec-tracks.mkv"
done
python3 -I -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK" > "$WORK/http.log" 2>&1 &
HTTP_PID=$!
VOD_INPUTS="$WORK/vod-h264.ts $WORK/vod-hevc.ts http://127.0.0.1:$HTTP_PORT/vod-h264-tracks.mkv http://127.0.0.1:$HTTP_PORT/vod-hevc-tracks.mkv"

# ffmpeg -listen 1 serves a single client, so restart it whenever a session disconnects.
(
    while true; do
        "$FFMPEG" -hide_banner -loglevel error -re \
            -f lavfi -i "testsrc2=size=640x360:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
            -c:v libx264 -preset ultrafast -tune zerolatency -g 25 -c:a aac -b:a 96k \
            -f mpegts -listen 1 "http://127.0.0.1:$PORT/live.ts" > /dev/null 2>&1 || true
    done
) &
LOOP_PID=$!
sleep 1

if [ "${FOOTPRINT_ONLY:-0}" = 1 ]; then
    # Without malloc stack logging, whose own bookkeeping grows the footprint.
    "$BIN" "http://127.0.0.1:$PORT/live.ts" "$WORK" "$CYCLES" "$SECONDS_PER_CYCLE" $VOD_INPUTS > "$WORK/leaks.log" 2>&1 || true
else
    MallocStackLogging=1 leaks --atExit -- "$BIN" "http://127.0.0.1:$PORT/live.ts" "$WORK" "$CYCLES" "$SECONDS_PER_CYCLE" $VOD_INPUTS > "$WORK/leaks.log" 2>&1 || true
fi
kill "$LOOP_PID" "$HTTP_PID" 2>/dev/null || true
pkill -f "127.0.0.1:$PORT/live.ts" 2>/dev/null || true

grep -E '^\[churn\]' "$WORK/leaks.log" || true
grep -E 'leaks for|total leaked bytes|Process [0-9]+: [0-9]+ (nodes|leaks)' "$WORK/leaks.log" || true
echo "full report: $WORK/leaks.log"
