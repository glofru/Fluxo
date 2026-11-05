#!/bin/sh
# Format matrix in the iOS Simulator: plays test files of the common containers and codecs in the app itself
# (the player's route, AVPlayer, the remux engine and its converter as iOS decides them) and checks each with the
# harness: enabled audio and video tracks (`probe-tracks`, which logs their formats: avc1 / aac for converted
# streams), playback with real frames (`probe-playback`), then a skip, a scrub and a skip back, each checked
# the same way.
#
#   Tools/Simulator/format-matrix.sh --device "iPhone 17e" --clone fluxo-mykey-1 [case words...]
#
# The media are the ones of Tools/EngineSmokeTest/run_formats.sh (generated here when missing), served on
# 127.0.0.1 only. The clone is kept between cases (one boot) and deleted at the end unless KEEP=1. Build the app
# first (Tools/Simulator/build.sh). Results: /tmp/fluxo-shots/<clone>/formats/summary.txt, one folder per case
# with the screenshot and app.log.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEVICE=""
CLONE=""
while [ $# -gt 0 ]; do
    case $1 in
        --device) DEVICE=$2; shift 2 ;;
        --clone) CLONE=$2; shift 2 ;;
        *) break ;;
    esac
done
[ -n "$CLONE" ] || { echo "usage: $0 --device NAME --clone fluxo-<key>-<n> [case words...]" >&2; exit 2; }
FILTER="$*"
PORT=${PORT:-18950}
MEDIA=${MEDIA:-/tmp/fluxo-format-media}
OUT=/tmp/fluxo-shots/$CLONE/formats
mkdir -p "$OUT"

MEDIA_ONLY=1 MEDIA=$MEDIA sh "$ROOT/Tools/EngineSmokeTest/run_formats.sh"

python3 -I "$ROOT/Tools/EngineSmokeTest/vod_server.py" --root "$MEDIA" --port "$PORT" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
cleanup() {
    kill "$SERVER_PID" 2>/dev/null || true
    if [ "${KEEP:-0}" != 1 ]; then
        "$ROOT/Tools/Simulator/cleanup.sh" "$CLONE" > /dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM
sleep 1
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | grep -q "127.0.0.1:$PORT" || { echo "error: the media server is not listening on 127.0.0.1:$PORT" >&2; exit 1; }

M=http://127.0.0.1:$PORT/movie/user/pass
# name|file|expects (a: audio, v: video)
CASES="
mp4-h264-aac|mp4-h264-aac.mp4|av
mov-mpeg4-aac|mov-mpeg4-aac.mov|av
mp4-mpeg4sp-aac|mp4-mpeg4sp-aac.mp4|av
mp4-hevc-eac3|mp4-hevc-eac3.mp4|av
mp4-hev1-aac|mp4-hev1-aac.mp4|av
mp4-h264-dts|mp4-h264-dts.mp4|av
3gp-h263-aac|3gp-h263-aac.3gp|av
mkv-h264-aac|mkv-h264-aac.mkv|av
mkv-h264-ac3|mkv-h264-ac3.mkv|av
mkv-h264-eac3|mkv-h264-eac3.mkv|av
mkv-h264-dts|mkv-h264-dts.mkv|av
mkv-hevc-dts|mkv-hevc-dts.mkv|av
mkv-h264-truehd|mkv-h264-truehd.mkv|av
mkv-h264-flac|mkv-h264-flac.mkv|av
mkv-h264-opus|mkv-h264-opus.mkv|av
mkv-h264-vorbis|mkv-h264-vorbis.mkv|av
mkv-h264-pcm|mkv-h264-pcm.mkv|av
mkv-h264-mp2|mkv-h264-mp2.mkv|av
mkv-h26410-aac|mkv-h26410-aac.mkv|av
mkv-hevc10-hdr10-eac3|mkv-hevc10-hdr10-eac3.mkv|av
mkv-av1-opus|mkv-av1-opus.mkv|av
mkv-vp9-opus|mkv-vp9-opus.mkv|av
mkv-mpeg2-ac3|mkv-mpeg2-ac3.mkv|av
mkv-tracks-dts-ac3-srt-ass|mkv-tracks-dts-ac3-srt-ass.mkv|av
webm-vp8-vorbis|webm-vp8-vorbis.webm|av
avi-xvid-mp3|avi-xvid-mp3.avi|av
avi-divx3-mp3|avi-divx3-mp3.avi|av
avi-mjpeg-pcm|avi-mjpeg-pcm.avi|av
ts-h264-latm|ts-h264-latm.ts|av
ts-mpeg2i-mp2|ts-mpeg2i-mp2.ts|av
m2ts-h264-dts|m2ts-h264-dts.m2ts|av
flv-flv1-mp3|flv-flv1-mp3.flv|av
wmv-wmv2-wma2|wmv-wmv2-wma2.wmv|av
vob-mpeg2-ac3|vob-mpeg2-ac3.vob|av
ogg-vorbis|ogg-vorbis.ogg|a
xtream-extensionless-dts|4001|av
sample-wmv-vc1|sample-Test_1440x576_WVC1_6Mbps.wmv|v
sample-m2ts-vc1i-dts|sample-vc1-interlaced-bframes.m2ts|av
"
: > "$OUT/summary.txt"
first=1
for line in $CASES; do
    name=$(echo "$line" | cut -d'|' -f1)
    file=$(echo "$line" | cut -d'|' -f2)
    expects=$(echo "$line" | cut -d'|' -f3)
    if [ -n "$FILTER" ]; then
        match=0
        for word in $FILTER; do
            case $name in *"$word"*) match=1 ;; esac
        done
        [ $match -eq 1 ] || continue
    fi
    if [ ! -e "$MEDIA/$file" ] && ! ls "$MEDIA/$file".* > /dev/null 2>&1; then
        echo "SKIP $name (no media)" | tee -a "$OUT/summary.txt"
        continue
    fi
    case $name in
        sample-wmv-*) steps="seek:50%;skip:-5" ;;
        *) steps="skip:30;seek:75%;skip:-10" ;;
    esac
    case $expects in *v*) probe="probe-playback;$steps" ;; *) probe="" ;; esac
    # The Blu-ray sample is a night sky (too dark for the probe's black-frame check): its tracks only.
    case $name in sample-m2ts-*) probe="" ;; esac
    route="play-movie:$M/$file;wait:2;probe-tracks:$expects${probe:+;$probe};stop"
    echo "=== $name" >&2
    if [ "$first" -eq 1 ]; then
        first=0
        "$ROOT/Tools/Simulator/run.sh" --device "$DEVICE" --clone "$CLONE" --keep --seed none --timeout 200 --out "$OUT/$name" \
            --route "$route" > "$OUT/$name.run.log" 2>&1 || true
    else
        "$ROOT/Tools/Simulator/run.sh" --no-install --clone "$CLONE" --keep --seed none --timeout 200 --out "$OUT/$name" \
            --route "$route" > "$OUT/$name.run.log" 2>&1 || true
    fi
    log=$OUT/$name/app.log
    tracks=$(grep -o 'Playback tracks after [^:]*: .*' "$log" 2>/dev/null | head -n 1 | sed 's/Playback tracks after probe-tracks: //')
    if grep -q 'failed:' "$log" 2>/dev/null || ! grep -q 'Playback tracks' "$log" 2>/dev/null; then
        result=FAIL
    else
        result=PASS
    fi
    echo "$result $name $tracks" | tee -a "$OUT/summary.txt"
    grep -o 'Route "[^"]*" failed: .*' "$log" 2>/dev/null | sed 's/^/    /' | tee -a "$OUT/summary.txt" || true
done
echo "--- $(grep -c '^PASS' "$OUT/summary.txt") passed, $(grep -c '^FAIL' "$OUT/summary.txt") failed (details in $OUT)"
! grep -q '^FAIL' "$OUT/summary.txt"
