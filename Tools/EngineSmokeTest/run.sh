#!/bin/sh
# Smoke test of the remux engine against a local live MPEG-TS stream (macOS, Homebrew FFmpeg).
#
# 1. An ffmpeg process serves a real-time test pattern as MPEG-TS over HTTP on 127.0.0.1 only.
# 2. The engine remuxes it to HLS with a small time-shift window (WINDOW seconds) and records
#    from RECORD_START to RECORD_STOP seconds.
# 3. The stream server is killed for a few seconds in the middle to exercise reconnection.
# 4. The recording is converted to MP4 and both files are checked with ffprobe.
set -eu

FFMPEG_PREFIX=${FFMPEG_PREFIX:-/opt/homebrew/opt/ffmpeg}
FFMPEG=${FFMPEG:-$FFMPEG_PREFIX/bin/ffmpeg}
FFPROBE=${FFPROBE:-$FFMPEG_PREFIX/bin/ffprobe}
PORT=${PORT:-18923}
SECONDS_TOTAL=${SECONDS_TOTAL:-50}
RECORD_START=${RECORD_START:-6}
RECORD_STOP=${RECORD_STOP:-30}
WINDOW=${WINDOW:-12}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d /tmp/fluxo-engine-test.XXXXXX)
BIN="$WORK/engine-smoke-test"

clang -O1 -g -Wall -Wextra -o "$BIN" \
    -I "$ROOT/Fluxo/Features/Player/Engine" -I "$FFMPEG_PREFIX/include" \
    "$ROOT/Tools/EngineSmokeTest/main.c" "$ROOT/Fluxo/Features/Player/Engine/FluxoRemuxEngine.c" \
    -L "$FFMPEG_PREFIX/lib" -lavformat -lavcodec -lavutil

serve() {
    # -listen 1 makes ffmpeg an HTTP server; it is bound to the loopback address only.
    "$FFMPEG" -hide_banner -loglevel error -re \
        -f lavfi -i "testsrc2=size=640x360:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -c:v libx264 -preset ultrafast -tune zerolatency -g 25 -c:a aac -b:a 96k \
        -f mpegts -listen 1 "http://127.0.0.1:$PORT/live.ts" &
    SERVER_PID=$!
}

cleanup() {
    kill "${SERVER_PID:-0}" 2>/dev/null || true
    kill "${ENGINE_PID:-0}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

serve
sleep 1
"$BIN" "http://127.0.0.1:$PORT/live.ts" "$WORK" "$SECONDS_TOTAL" "$RECORD_START" "$RECORD_STOP" "$WINDOW" > "$WORK/engine.log" 2>&1 &
ENGINE_PID=$!

for t in $(seq 1 "$SECONDS_TOTAL"); do
    sleep 1
    if [ "$t" -eq 18 ]; then
        echo "[run] t=$t killing the stream server" >> "$WORK/engine.log"
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [ "$t" -eq 22 ]; then
        echo "[run] t=$t restarting the stream server" >> "$WORK/engine.log"
        serve
    fi
    if [ $((t % 10)) -eq 0 ]; then
        {
            echo "[run] t=$t segments on disk: $(ls "$WORK" | grep -c '^stream-test-.*\.ts$' || true)"
            grep -E 'MEDIA-SEQUENCE|DISCONTINUITY' "$WORK/stream-test.m3u8" 2>/dev/null | tr '\n' ' '
            echo "entries=$(grep -c EXTINF "$WORK/stream-test.m3u8" 2>/dev/null || echo 0)"
        } >> "$WORK/engine.log"
    fi
done
wait "$ENGINE_PID" || true

cat "$WORK/engine.log"
echo "--- final playlist"
cat "$WORK/stream-test.m3u8" || true
echo "--- recording.ts"
"$FFPROBE" -v error -show_entries format=duration,size:stream=codec_name,codec_type -of compact "$WORK/recording.ts" || true
echo "--- recording.mp4"
"$FFPROBE" -v error -show_entries format=duration,size,format_name:stream=codec_name,codec_type -of compact "$WORK/recording.mp4" || true
echo "--- decode check of recording.mp4"
"$FFMPEG" -v error -i "$WORK/recording.mp4" -f null - && echo "decoded without errors"
echo "work directory: $WORK"
