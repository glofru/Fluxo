#!/bin/sh
# Loopback-only test streams for the player (HLS, raw MPEG-TS, on-demand MP4 / TS). See README.md.
#
#   Tools/Simulator/test-stream.sh            run in the foreground (Ctrl-C stops it)
#   Tools/Simulator/test-stream.sh start      run in the background
#   Tools/Simulator/test-stream.sh status
#   Tools/Simulator/test-stream.sh stop
#
# PORT (default 18080) selects the port. The server always binds 127.0.0.1; the iOS Simulator shares the
# Mac's loopback interface, so apps in a simulator reach it at http://127.0.0.1:$PORT.
# FFMPEG selects the ffmpeg program (default /opt/homebrew/bin/ffmpeg, then the one on PATH).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PORT=${PORT:-18080}
WORK=${TEST_STREAM_WORK:-/tmp/fluxo-test-stream/$PORT}
PID_FILE="$WORK/server.pid"
LOG_FILE="$WORK/server.log"

if [ -z "${FFMPEG:-}" ]; then
    if [ -x /opt/homebrew/bin/ffmpeg ]; then
        FFMPEG=/opt/homebrew/bin/ffmpeg
    else
        FFMPEG=$(command -v ffmpeg || true)
    fi
fi
if [ -z "$FFMPEG" ] || [ ! -x "$FFMPEG" ]; then
    echo "error: ffmpeg not found; install it (brew install ffmpeg) or set FFMPEG" >&2
    exit 1
fi

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

print_urls() {
    echo "Test streams on http://127.0.0.1:$PORT (loopback only):"
    echo "  playlist     http://127.0.0.1:$PORT/playlist.m3u"
    echo "  live HLS     http://127.0.0.1:$PORT/hls/live.m3u8"
    echo "  live TS      http://127.0.0.1:$PORT/live/test-pattern"
    echo "  VOD MP4      http://127.0.0.1:$PORT/movie/clip.mp4"
    echo "  VOD TS       http://127.0.0.1:$PORT/movie/clip.ts"
}

mkdir -p "$WORK"
case "${1:-run}" in
run)
    print_urls
    exec /usr/bin/python3 -I "$HERE/test_stream_server.py" --port "$PORT" --work "$WORK" --ffmpeg "$FFMPEG"
    ;;
start)
    if is_running; then
        echo "already running (pid $(cat "$PID_FILE"))"
        print_urls
        exit 0
    fi
    nohup /usr/bin/python3 -I "$HERE/test_stream_server.py" --port "$PORT" --work "$WORK" --ffmpeg "$FFMPEG" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    # The first start encodes the on-demand clips; then the live playlist needs its first segments.
    for _ in $(seq 1 120); do
        if curl -sf -o /dev/null "http://127.0.0.1:$PORT/hls/live.m3u8"; then
            print_urls
            echo "log: $LOG_FILE"
            exit 0
        fi
        if ! is_running; then
            echo "error: the server exited:" >&2
            cat "$LOG_FILE" >&2
            exit 1
        fi
        sleep 0.5
    done
    echo "error: the server did not become ready; see $LOG_FILE" >&2
    exit 1
    ;;
status)
    if is_running; then
        echo "running (pid $(cat "$PID_FILE"))"
        lsof -nP -a -p "$(cat "$PID_FILE")" -iTCP -sTCP:LISTEN 2>/dev/null || true
        print_urls
    else
        echo "not running"
        exit 1
    fi
    ;;
stop)
    if is_running; then
        kill "$(cat "$PID_FILE")"
        for _ in $(seq 1 50); do
            is_running || break
            sleep 0.1
        done
        echo "stopped"
    else
        echo "not running"
    fi
    rm -f "$PID_FILE"
    ;;
*)
    echo "usage: $0 [run|start|status|stop]" >&2
    exit 2
    ;;
esac
