#!/bin/sh
# Seek latency and seek robustness, macOS: plays a realistic movie (1080p H.264 at about 4.5 Mbit/s, a key frame
# every 10 s at most, AAC; 10 minutes) through every on-demand route of the app (AVPlayer directly: MP4 with the
# moov first and last; the remux engine: Matroska and MPEG-TS) from a loopback server that mimics a phone on Wi-Fi
# (TTFB and bandwidth limits), and runs VODCheck's stress scenario (Stress.swift): a drag, four quick +30 taps,
# three -10 taps, two releases in a row, a fine drag, a seek near the end, a seek while paused, a resume. Each seek
# is measured from the release (or the last tap) until the player plays there with video frames that keep up.
#
#   Tools/EngineSmokeTest/run_seek.sh                       every route and network, with PlayerSeeker
#   SEEKER=legacy Tools/EngineSmokeTest/run_seek.sh         the seeks the player made before PlayerSeeker
#   Tools/EngineSmokeTest/run_seek.sh mkv wifi              cases whose name contains one of the words
#
# Networks: lan (no limit), wifi (60 ms to first byte, 3 MB/s), poor (250 ms, 1.2 MB/s: about twice the bit rate).
# Needs ffmpeg (Tools/FFmpeg/env.sh) the first time, to generate the media (about 1.4 GB in $MEDIA).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/Tools/FFmpeg/env.sh"
PORT=${PORT:-18950}
# The check's own loopback server (run_vod.sh uses 19323, the app 19123).
CHECK_PORT=${CHECK_PORT:-19333}
MEDIA=${MEDIA:-/tmp/fluxo-vod-real}
WORK=${WORK:-/tmp/fluxo-seek-check}
mkdir -p "$MEDIA" "$WORK"

if [ ! -f "$MEDIA/done" ]; then
    echo "[seek] generating the test movie in $MEDIA"
    q="-hide_banner -loglevel error -y"
    # Film grain-like noise keeps the bit rate up; testsrc2 shows the time, so screenshots show the position.
    "$FFMPEG" $q -f lavfi -i "testsrc2=size=1920x1080:rate=25:duration=600" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=600" \
        -vf "noise=alls=12:allf=t" -c:v libx264 -preset veryfast -threads 6 -x264-params keyint=250:min-keyint=25 -b:v 4500k -maxrate 6M -bufsize 12M \
        -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart "$MEDIA/real-h264.mp4"
    "$FFMPEG" $q -i "$MEDIA/real-h264.mp4" -c copy "$MEDIA/real-h264-moov-last.mp4"
    "$FFMPEG" $q -i "$MEDIA/real-h264.mp4" -c copy "$MEDIA/real-h264.mkv"
    "$FFMPEG" $q -i "$MEDIA/real-h264.mp4" -c copy -f mpegts "$MEDIA/real-h264.ts"
    touch "$MEDIA/done"
fi

CHECK=$(BUILD_ONLY=1 WORK="$WORK" CHECK_PORT="$CHECK_PORT" "$ROOT/Tools/EngineSmokeTest/run_vod.sh" | tail -n 1)
[ -x "$CHECK" ]

cleanup() {
    # (`kill 0` would end the whole process group.)
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM
for port in "$PORT" "$CHECK_PORT"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN > /dev/null 2>&1; then
        echo "error: port $port is in use (another check running?); set PORT / CHECK_PORT" >&2
        exit 1
    fi
done
# Loopback only (vod_server.py binds 127.0.0.1).
python3 -I "$ROOT/Tools/EngineSmokeTest/vod_server.py" --root "$MEDIA" --port "$PORT" > "$WORK/seek-server.log" 2>&1 &
SERVER_PID=$!
sleep 1
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | grep -q "127.0.0.1:$PORT" || { echo "error: the media server is not listening on 127.0.0.1:$PORT" >&2; exit 1; }

B=http://127.0.0.1:$PORT
SEEKER=${SEEKER:-new}
summary=""
failed=0
for network in lan:/ wifi:/lat/60/slow/3000/ poor:/lat/250/slow/1200/; do
    net=${network%%:*}
    prefix=${network#*:}
    for case in mp4:real-h264.mp4 mp4-moov-last:real-h264-moov-last.mp4 mkv:real-h264.mkv ts:real-h264.ts; do
        name="$net-${case%%:*}"
        file=${case#*:}
        if [ $# -gt 0 ]; then
            match=0
            for word in "$@"; do
                case $name in *"$word"*) match=1 ;; esac
            done
            [ $match -eq 1 ] || continue
        fi
        url="$B${prefix}movie/user/pass/$file"
        echo "=== $name ($SEEKER) $url"
        log="$WORK/seek-$SEEKER-$name.log"
        if MAX_SEGMENT=20 SCENARIO=stress SEEKER=$SEEKER "$CHECK" "$url" movie > "$log" 2>&1; then
            result=PASS
        else
            result=FAIL
            failed=$((failed + 1))
        fi
        grep -E '^\[stress\]|^\[check\] (route|result)' "$log" | sed 's/^/    /'
        summary="$summary
$result $name $(grep '^\[stress\] summary' "$log" | sed 's/^\[stress\] summary //')"
    done
done
echo "--- summary ($SEEKER, logs in $WORK)$summary"
[ "$failed" -eq 0 ]
