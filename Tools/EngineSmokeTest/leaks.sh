#!/bin/sh
# Leak and footprint check of the remux engine (macOS, Homebrew FFmpeg).
#
# Serves a live MPEG-TS test pattern on 127.0.0.1 only, runs CYCLES engine sessions of SECONDS
# each under `leaks --atExit` (FOOTPRINT_ONLY=1: without it), and prints the footprint after every cycle and the leaks report.
set -eu

FFMPEG_PREFIX=${FFMPEG_PREFIX:-/opt/homebrew/opt/ffmpeg}
FFMPEG=${FFMPEG:-$FFMPEG_PREFIX/bin/ffmpeg}
PORT=${PORT:-18925}
CYCLES=${CYCLES:-12}
SECONDS_PER_CYCLE=${SECONDS_PER_CYCLE:-4}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d /tmp/fluxo-engine-leaks.XXXXXX)
BIN="$WORK/engine-churn"

clang -O1 -g -Wall -Wextra -o "$BIN" \
    -I "$ROOT/Fluxo/Features/Player/Engine" -I "$FFMPEG_PREFIX/include" \
    "$ROOT/Tools/EngineSmokeTest/churn.c" "$ROOT/Fluxo/Features/Player/Engine/FluxoRemuxEngine.c" \
    -L "$FFMPEG_PREFIX/lib" -lavformat -lavcodec -lavutil

cleanup() {
    kill "${LOOP_PID:-0}" 2>/dev/null || true
    pkill -f "127.0.0.1:$PORT/live.ts" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

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
    "$BIN" "http://127.0.0.1:$PORT/live.ts" "$WORK" "$CYCLES" "$SECONDS_PER_CYCLE" > "$WORK/leaks.log" 2>&1 || true
else
    MallocStackLogging=1 leaks --atExit -- "$BIN" "http://127.0.0.1:$PORT/live.ts" "$WORK" "$CYCLES" "$SECONDS_PER_CYCLE" > "$WORK/leaks.log" 2>&1 || true
fi
kill "$LOOP_PID" 2>/dev/null || true
pkill -f "127.0.0.1:$PORT/live.ts" 2>/dev/null || true

grep -E '^\[churn\]' "$WORK/leaks.log" || true
grep -E 'leaks for|total leaked bytes|Process [0-9]+: [0-9]+ (nodes|leaks)' "$WORK/leaks.log" || true
echo "full report: $WORK/leaks.log"
