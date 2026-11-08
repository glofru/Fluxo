#!/bin/sh
# On-demand (VOD) playback check, macOS. Generates 10-minute test movies (H.264 and HEVC; MP4 with the
# moov first and last, MP4 tagged hev1, Matroska, MPEG-TS, HLS), serves them on 127.0.0.1 like IPTV panels
# do (Xtream Codes paths, extensionless and .php URLs, without byte ranges, throttled, one connection per
# account), and plays each one with VODCheck: the app's PlaybackRoute, StreamRemuxer, remux engine and
# loopback server (on another port than the app's) with AVPlayer. Every case seeks +30 s, scrubs to 25 / 50 / 90 %, skips back, then closes
# and resumes at the saved position, checking that playback continues with real video frames. Movies with two
# audio tracks and subtitles (H.264 and HEVC Matroska, as series episodes often are) play the master playlist:
# the check switches the audio track and checks that the subtitle cues come at their time. The live cases
# (a file served at about its bit rate, H.264 and HEVC) check that live channels still play from the live
# edge and within the time-shift window. The dropped-* cases (SCENARIO=dropped, Stress.swift) make AVPlayer drop
# seeks as it does while it starts an item: the seek must play at the target after a few drops, end with Try Again
# when every seek is dropped, and never stay loading. mkv-slow-segment (SCENARIO=slowsegment) seeks on a server that
# answers a seek after 12 s, then slowly: the segment takes about 20 s, and must play from that one request (the
# loopback server allows a request longer than the engine's 45 s wait, LoopbackTimeouts).
# live-pause (SCENARIO=livepause) pauses a live channel, closes its input for 70 s (longer than AVPlayer reloads an
# unchanged live playlist) and plays on as the app does: a new item at the paused media must play and follow the
# playlist past the resume, with the paused media and the old item's frame where it continues (live-pause-sliding: in
# a window of 30 s that fills and slides meanwhile).
#
#   Tools/EngineSmokeTest/run_vod.sh                 every case
#   Tools/EngineSmokeTest/run_vod.sh mkv-h264 ts     cases whose name contains one of the words
#
# Needs ffmpeg / ffprobe (see Tools/FFmpeg/env.sh) to generate the media, and network access the first
# time (Swift Package Manager fetches FlyingFox at the version the app uses).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/Tools/FFmpeg/env.sh"
# VODCheck checks the sound of the engine's segments with it.
export FFMPEG
PORT=${PORT:-18930}
MEDIA=${MEDIA:-/tmp/fluxo-vod-media}
WORK=${WORK:-/tmp/fluxo-vod-check}
DURATION=${DURATION:-600}

mkdir -p "$MEDIA" "$WORK"

# MARK: Media
make_media() {
    [ -f "$MEDIA/done-$DURATION" ] && return
    echo "[vod] generating ${DURATION}s test movies in $MEDIA"
    q="-hide_banner -loglevel error -y"
    # testsrc draws a second counter, so screenshots show the position too.
    "$FFMPEG" $q -f lavfi -i "testsrc=size=640x360:rate=25:duration=$DURATION" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$DURATION" \
        -c:v libx264 -preset veryfast -g 50 -keyint_min 25 -b:v 800k -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart "$MEDIA/h264.mp4"
    "$FFMPEG" $q -i "$MEDIA/h264.mp4" -c copy "$MEDIA/h264-moov-last.mp4"
    "$FFMPEG" $q -i "$MEDIA/h264.mp4" -c copy "$MEDIA/h264.mkv"
    "$FFMPEG" $q -i "$MEDIA/h264.mp4" -c copy -f mpegts "$MEDIA/h264.ts"
    # HEVC with a long, irregular GOP (2.4 s, scene cuts) and AC-3 audio, as web releases of series often are.
    "$FFMPEG" $q -f lavfi -i "testsrc=size=640x360:rate=25:duration=$DURATION" -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=$DURATION" \
        -c:v libx265 -preset ultrafast -x265-params keyint=60:min-keyint=24:log-level=error -b:v 600k -pix_fmt yuv420p -c:a ac3 -b:a 192k "$MEDIA/hevc.mkv"
    "$FFMPEG" $q -i "$MEDIA/hevc.mkv" -c:v copy -c:a aac -b:a 96k -tag:v hev1 "$MEDIA/hevc-hev1.mp4"
    "$FFMPEG" $q -i "$MEDIA/hevc.mkv" -c:v copy -c:a aac -b:a 96k -f mpegts "$MEDIA/hevc.ts"
    # Matroska written to a pipe: no index (Cues) and no duration, as live captures saved to files are.
    "$FFMPEG" $q -i "$MEDIA/h264.mp4" -c copy -f matroska - > "$MEDIA/h264-nocues.mkv"
    mkdir -p "$MEDIA/hls"
    "$FFMPEG" $q -i "$MEDIA/h264.mp4" -c copy -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_filename "$MEDIA/hls/seg-%04d.ts" "$MEDIA/hls/index.m3u8"
    # Xtream Codes style ids.
    ln -sf h264.mkv "$MEDIA/1001.mkv"
    ln -sf h264.ts "$MEDIA/1002.ts"
    ln -sf hevc.mkv "$MEDIA/2001.mkv"
    ln -sf h264.ts "$MEDIA/1003"
    touch "$MEDIA/done-$DURATION"
}

# Two audio tracks (AAC English, AC-3 Italian) and English / Italian SubRip subtitles, a cue every 10 s that
# says when it starts ("Cue at 125 s"), H.264 and HEVC; and the HEVC one as a live MPEG-TS channel.
make_track_media() {
    [ -f "$MEDIA/tracks-done-$DURATION" ] && return
    echo "[vod] generating ${DURATION}s test movies with audio tracks and subtitles in $MEDIA"
    q="-hide_banner -loglevel error -y"
    : > "$MEDIA/cues.srt"
    n=1
    t=5
    while [ "$t" -lt "$DURATION" ]; do
        printf '%d\n%02d:%02d:%02d,000 --> %02d:%02d:%02d,000\nCue at %d s\n\n' "$n" $((t / 3600)) $((t / 60 % 60)) $((t % 60)) \
            $(((t + 4) / 3600)) $(((t + 4) / 60 % 60)) $(((t + 4) % 60)) "$t" >> "$MEDIA/cues.srt"
        n=$((n + 1))
        t=$((t + 10))
    done
    for codec in h264 hevc; do
        "$FFMPEG" $q -i "$MEDIA/$codec.mkv" -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=$DURATION" -i "$MEDIA/cues.srt" -i "$MEDIA/cues.srt" \
            -map 0:v -map 0:a -map 1:a -map 2 -map 3 -c:v copy -c:a:0 aac -b:a:0 96k -c:a:1 ac3 -b:a:1 128k -c:s srt \
            -metadata:s:a:0 language=eng -metadata:s:a:1 language=ita -metadata:s:s:0 language=eng -metadata:s:s:1 language=ita \
            -disposition:a:0 default -disposition:a:1 0 -disposition:s:0 0 -disposition:s:1 0 "$MEDIA/tracks-$codec.mkv"
    done
    "$FFMPEG" $q -i "$MEDIA/tracks-hevc.mkv" -map 0:v -map 0:a -c copy -f mpegts "$MEDIA/tracks-hevc.ts"
    touch "$MEDIA/tracks-done-$DURATION"
}

# MARK: Harness
# shellcheck source=vodcheck.sh
. "$ROOT/Tools/EngineSmokeTest/vodcheck.sh"

cleanup() {
    # (`kill 0` would end the whole process group.)
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

if [ "${BUILD_ONLY:-0}" = 1 ]; then
    # run_seek.sh: only the check binary, its path on the last line.
    build_check >&2
    echo "$CHECK"
    exit 0
fi
make_media
make_track_media
build_check

# Loopback only (vod_server.py binds 127.0.0.1).
python3 -I "$ROOT/Tools/EngineSmokeTest/vod_server.py" --root "$MEDIA" --port "$PORT" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | grep -q "127.0.0.1:$PORT" || { echo "error: the media server is not listening on 127.0.0.1:$PORT" >&2; exit 1; }

B=http://127.0.0.1:$PORT
# name|url|kind
CASES="
mp4-moov-first|$B/movie/user/pass/h264.mp4|movie
mp4-moov-last|$B/movie/user/pass/h264-moov-last.mp4|movie
mp4-no-ranges|$B/norange/movie/user/pass/h264.mp4|movie
mp4-hev1|$B/movie/user/pass/hevc-hev1.mp4|movie
mp4-one-connection|$B/slow/150/busy/movie/user/pass/h264.mp4|movie
mp4-newest-connection|$B/slow/150/oneconn/movie/user/pass/h264.mp4|movie
mkv-h264|$B/movie/user/pass/1001.mkv|movie
mkv-hevc-ac3|$B/series/user/pass/2001.mkv|series
mkv-no-cues|$B/movie/user/pass/h264-nocues.mkv|movie
mkv-no-ranges|$B/norange/movie/user/pass/1001.mkv|movie
mkv-slow|$B/slow/400/movie/user/pass/1001.mkv|movie
ts-xtream|$B/movie/user/pass/1002.ts|movie
ts-hevc|$B/movie/user/pass/hevc.ts|movie
ts-extensionless|$B/movie/user/pass/1003|movie
ts-no-ranges|$B/norange/movie/user/pass/1002.ts|movie
ts-slow|$B/slow/150/movie/user/pass/1002.ts|movie
php-mkv|$B/play.php?stream=h264.mkv|movie
mkv-tracks|$B/movie/user/pass/tracks-h264.mkv|movie
mkv-hevc-tracks|$B/series/user/pass/tracks-hevc.mkv|series
ts-hevc-tracks|$B/movie/user/pass/tracks-hevc.ts|movie
hls-vod|$B/hls/index.m3u8|movie
live-ts|$B/slow/100/live/user/pass/1002.ts|live
live-hevc|$B/slow/110/user/pass/hevc.ts|live
live-hevc-tracks|$B/slow/130/live/user/pass/tracks-hevc.ts|live
live-pause|$B/slow/100/live/user/pass/1002.ts|live
live-pause-sliding|$B/slow/100/live/user/pass/1002.ts|live
mkv-slow-segment|$B/seekdelay/12000/slow/60/movie/user/pass/1001.mkv|movie
dropped-mp4|$B/movie/user/pass/h264.mp4|movie
dropped-ts|$B/slow/400/movie/user/pass/1002.ts|movie
"
passed=0
failed=0
summary=""
for line in $CASES; do
    name=${line%%|*}
    rest=${line#*|}
    url=${rest%|*}
    kind=${rest##*|}
    if [ $# -gt 0 ]; then
        match=0
        for word in "$@"; do
            case $name in *"$word"*) match=1 ;; esac
        done
        [ $match -eq 1 ] || continue
    fi
    echo "=== $name ($kind) $url"
    # dropped-*: AVPlayer dropping seeks (VODCheck SCENARIO=dropped, Stress.swift).
    scenario=
    case $name in dropped-*) scenario=dropped ;; *-slow-segment) scenario=slowsegment ;; live-pause*) scenario=livepause ;; esac
    # live-pause-sliding: a time-shift window of 30 s, which fills during the pause and lets go of its oldest segments
    # (the policy then closes the input), the paused media still in it.
    window=
    case $name in *-sliding) window=30 ;; esac
    if WINDOW_SECONDS=$window SCENARIO=$scenario "$CHECK" "$url" "$kind" > "$WORK/$name.log" 2>&1; then
        passed=$((passed + 1))
        result=PASS
    else
        failed=$((failed + 1))
        result=FAIL
    fi
    grep -E '^\[check\] (route|playlist|master|tracks|playing after|.*=> |result)|^\[dropped\]|^\[stress\] .*=> ' "$WORK/$name.log" | sed 's/^/    /'
    summary="$summary
$result $name"
done
echo "--- summary (logs in $WORK)$summary"
echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]
