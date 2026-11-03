#!/bin/sh
# Plays the engine's live HLS output with AVPlayer through a loopback-only HTTP server and
# exercises pause / resume / skip / go live. macOS only.
set -eu
PORT=${PORT:-18923}
HTTP_PORT=${HTTP_PORT:-18924}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/Tools/FFmpeg/env.sh"
WORK=$(mktemp -d /tmp/fluxo-avplayer-test.XXXXXX)
BIN="$WORK/engine-smoke-test"

# shellcheck disable=SC2086 # FFMPEG_CFLAGS / FFMPEG_LDFLAGS are lists of words.
clang -O1 -o "$BIN" -I "$ROOT/Fluxo/Features/Player/Engine" $FFMPEG_CFLAGS \
    "$ROOT/Tools/EngineSmokeTest/main.c" "$ROOT/Fluxo/Features/Player/Engine/FluxoRemuxEngine.c" \
    $FFMPEG_LDFLAGS

cleanup() {
    kill "${SERVER_PID:-0}" "${ENGINE_PID:-0}" "${HTTP_PID:-0}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"$FFMPEG" -hide_banner -loglevel error -re \
    -f lavfi -i "testsrc2=size=640x360:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 25 -c:a aac -b:a 96k \
    -f mpegts -listen 1 "http://127.0.0.1:$PORT/live.ts" &
SERVER_PID=$!
sleep 1
"$BIN" "http://127.0.0.1:$PORT/live.ts" "$WORK" 90 0 0 60 > "$WORK/engine.log" 2>&1 &
ENGINE_PID=$!
# Loopback only.
python3 -I -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK" > "$WORK/http.log" 2>&1 &
HTTP_PID=$!
# Let a few segments accumulate so that there is something to seek back into.
sleep 20
lsof -nP -iTCP -sTCP:LISTEN | grep -E ":($PORT|$HTTP_PORT) " || true
swift "$ROOT/Tools/EngineSmokeTest/avplayer_check.swift" "http://127.0.0.1:$HTTP_PORT/stream-test.m3u8"
grep -c "segment written" "$WORK/engine.log"
grep -v "segment written" "$WORK/engine.log" | head
grep -c " 404 " "$WORK/http.log" || true
