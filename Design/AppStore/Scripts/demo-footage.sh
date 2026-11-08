#!/bin/bash
# Demo footage for the App Store screenshots: "Dusk" (dusk_footage.py, drawn with FigCraft) as a slow, looping push-in,
# served on 127.0.0.1 only where the `store` seed looks for the test streams (`-FluxoDebugTestStreamURL
# http://127.0.0.1:$PORT`): as live HLS for the live channels Wildframe and Northwind Sports (/hls/live.m3u8), and as
# a film for The Silent Harbor and Crimson Signal (/movie/clip.mp4, with byte ranges, so they play and download): the
# picture with a light grain at about 2 Mbit/s for 1 h 47 min (1.6 GB, 30 s repeated), so Downloads shows the length and
# size of a real film. The server is Tools/EngineSmokeTest/vod_server.py, which only binds 127.0.0.1. Its throttle
# (`/slow/<KB/s>/` before a path) lets a capture catch a download half way.
#
#   FIGCRAFT_CLI=/path/to/figcraft-cli Design/AppStore/Scripts/demo-footage.sh start   # background
#   Design/AppStore/Scripts/demo-footage.sh status | stop
#
# The address is fixed to 127.0.0.1 (the iOS and tvOS Simulators share the Mac's loopback interface); only the port
# can change (PORT=, default 18960). The content is a synthetic picture with silence; the loopback bind is its only
# protection, so do not widen it. Needs ffmpeg (FFMPEG=, default the one on PATH) and figcraft-cli.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=${PORT:-18960}
WORK=${FLUXO_FOOTAGE_DIR:-/tmp/fluxo-appstore-footage}
FFMPEG=${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}
BIND=127.0.0.1

die() { echo "error: $*" >&2; exit 1; }

prepare() {
    mkdir -p "$WORK/www/hls" "$WORK/www/movie"
    if [ ! -f "$WORK/loop.mp4" ]; then
        [ -x "${FIGCRAFT_CLI:-}" ] || die "set FIGCRAFT_CLI to figcraft-cli (the figcraft-cli-<version>-macos-universal.zip release asset)"
        python3 -I "$HERE/dusk_footage.py" "$WORK/dusk.json"
        "$FIGCRAFT_CLI" run "$WORK/dusk.json" --out "$WORK/dusk.figcraft" > /dev/null
        "$FIGCRAFT_CLI" render "$WORK/dusk.figcraft" -o "$WORK/dusk.png" --scale 2 > /dev/null
        # 30 s: a push-in from 100 % to 112 % and back (seamless when looped), 1920 x 1080, 30 fps, silent AAC.
        "$FFMPEG" -hide_banner -loglevel error -y -loop 1 -i "$WORK/dusk.png" \
            -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
            -filter_complex "[0:v]scale=3840:2160,zoompan=z='1+0.12*(0.5-0.5*cos(2*PI*on/900))':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,format=yuv420p[v]" \
            -map "[v]" -map 1:a -t 30 -c:v libx264 -preset medium -crf 18 -g 60 -keyint_min 60 -sc_threshold 0 \
            -c:a aac -b:a 64k -shortest -movflags +faststart "$WORK/loop.mp4"
    fi
    if [ ! -f "$WORK/www/movie/clip.mp4" ]; then
        "$FFMPEG" -hide_banner -loglevel error -y -loop 1 -framerate 24 -i "$WORK/dusk.png" -t 30 \
            -vf "scale=1920:1080,noise=alls=8:allf=t,format=yuv420p" -c:v libx264 -preset veryfast -b:v 2000k \
            -maxrate 2400k -bufsize 4000k -g 48 -an "$WORK/film-part.mp4"
        for _ in $(seq 1 214); do echo "file '$WORK/film-part.mp4'"; done > "$WORK/film.txt"
        "$FFMPEG" -hide_banner -loglevel error -y -f concat -safe 0 -i "$WORK/film.txt" -c copy -movflags +faststart \
            "$WORK/www/movie/clip.mp4"
        rm -f "$WORK/film-part.mp4" "$WORK/film.txt"
    fi
}

running() { [ -f "$WORK/$1.pid" ] && kill -0 "$(cat "$WORK/$1.pid")" 2> /dev/null; }

start() {
    running server && { echo "already running: http://$BIND:$PORT/hls/live.m3u8"; return; }
    prepare
    rm -f "$WORK/www/hls/"*
    "$FFMPEG" -hide_banner -loglevel error -re -stream_loop -1 -i "$WORK/loop.mp4" -c copy -f hls -hls_time 2 \
        -hls_list_size 6 -hls_flags delete_segments+omit_endlist -hls_segment_filename "$WORK/www/hls/live-%05d.ts" \
        "$WORK/www/hls/live.m3u8" > "$WORK/encoder.log" 2>&1 &
    echo $! > "$WORK/encoder.pid"
    python3 -I "$HERE/../../../Tools/EngineSmokeTest/vod_server.py" --root "$WORK/www" --port "$PORT" > "$WORK/server.log" 2>&1 &
    echo $! > "$WORK/server.pid"
    for _ in $(seq 1 40); do
        [ -f "$WORK/www/hls/live.m3u8" ] && curl -sf "http://$BIND:$PORT/hls/live.m3u8" > /dev/null && break
        sleep 0.25
    done
    curl -sf "http://$BIND:$PORT/hls/live.m3u8" > /dev/null || { stop; die "the stream did not start (see $WORK/*.log)"; }
    echo "serving http://$BIND:$PORT/hls/live.m3u8"
}

stop() {
    for name in server encoder; do
        if running "$name"; then kill "$(cat "$WORK/$name.pid")" 2> /dev/null || true; fi
        rm -f "$WORK/$name.pid"
    done
}

case "${1:-}" in
start) start ;;
stop) stop ;;
status) if running server; then echo "running: http://$BIND:$PORT/hls/live.m3u8"; else echo "stopped"; fi ;;
*) die "usage: demo-footage.sh start|stop|status" ;;
esac
