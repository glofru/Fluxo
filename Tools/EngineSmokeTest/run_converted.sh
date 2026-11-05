#!/bin/sh
# Converted video (iPhone decisions, FLUXO_NATIVE_CODECS=0) through the remux engine, macOS:
#
#   restart  A live MPEG-TS whose timestamps start again (clips a b a b joined, as when an IPTV source restarts
#            its clock or a restreamer switches source), MPEG-2 / MP2 and H.264 High 10 / AAC: segments stay near
#            their target duration, and audio and video stay together in each one.
#   refuse   The video encoder refuses every picture for a while (FLUXO_TEST_REFUSE_ENCODER, as VideoToolbox does
#            in the background and in Picture in Picture), live and on demand, from the middle and from the start
#            (no encoder opens at first): the audio goes on (segments are still cut, with sound), and the picture
#            comes back afterwards; on demand, the segments written without a picture are deleted once it does.
#   convert  A file conversion (downloads) whose video encoder is refused, in the middle or from the start, fails
#            with FLUXO_REMUX_ERROR_ENCODER_UNAVAILABLE (to be converted again later) instead of leaving pictures
#            out or reporting an unsupported format, and converts completely otherwise.
#
#   Tools/EngineSmokeTest/run_converted.sh [restart] [refuse] [convert]     (all by default)
#
# Media are generated with ffmpeg (Tools/FFmpeg/env.sh) and served on 127.0.0.1 only (vod_server.py).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/Tools/FFmpeg/env.sh"
PORT=${PORT:-18961}
WORK=${WORK:-/tmp/fluxo-converted-check}
MEDIA=$WORK/media
BIN=$WORK/engine-smoke-test
TESTS=${*:-restart refuse convert}
mkdir -p "$MEDIA"
export FLUXO_NATIVE_CODECS=0

# shellcheck disable=SC2086 # FFMPEG_CFLAGS / FFMPEG_LDFLAGS / FLUXO_ENGINE_SOURCES are lists of words.
clang -O1 -g -Wall -Wextra -o "$BIN" \
    -I "$ROOT/Fluxo/Features/Player/Engine" $FFMPEG_CFLAGS \
    "$ROOT/Tools/EngineSmokeTest/main.c" $FLUXO_ENGINE_SOURCES \
    $FFMPEG_LDFLAGS

q="-hide_banner -loglevel error -y -nostdin"
gen() { # name args...: writes $MEDIA/<name> unless it exists
    out=$MEDIA/$1
    shift
    [ -f "$out" ] && return 0
    # shellcheck disable=SC2086
    "$FFMPEG" $q "$@" "$out.part.ts" && mv "$out.part.ts" "$out"
}
A="-f lavfi -i sine=frequency=440:sample_rate=48000"
MPEG2="-c:v mpeg2video -b:v 3M -g 12 -c:a mp2 -b:a 192k -f mpegts"
HIGH10="-c:v libx264 -preset veryfast -g 50 -b:v 1500k -pix_fmt yuv420p10le -profile:v high10 -c:a aac -b:a 128k -f mpegts"
# shellcheck disable=SC2086
{
    gen mpeg2-a.ts -f lavfi -i "testsrc=size=720x576:rate=25:duration=12" $A -t 12 $MPEG2
    gen mpeg2-b.ts -f lavfi -i "testsrc2=size=720x576:rate=25:duration=12" $A -t 12 $MPEG2
    gen high10-a.ts -f lavfi -i "testsrc=size=640x360:rate=25:duration=12" $A -t 12 $HIGH10
    gen high10-b.ts -f lavfi -i "testsrc2=size=640x360:rate=25:duration=12" $A -t 12 $HIGH10
    gen mpeg2-long.ts -f lavfi -i "testsrc=size=720x576:rate=25:duration=60" $A -t 60 $MPEG2
}
# Every clip starts at the same time (MPEG-TS's 1.4 s): joined, the timestamps jump back at each join.
for codec in mpeg2 high10; do
    [ -f "$MEDIA/$codec-restart.ts" ] || cat "$MEDIA/$codec-a.ts" "$MEDIA/$codec-b.ts" "$MEDIA/$codec-a.ts" "$MEDIA/$codec-b.ts" > "$MEDIA/$codec-restart.ts"
done

python3 -I "$ROOT/Tools/EngineSmokeTest/vod_server.py" --root "$MEDIA" --port "$PORT" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
cleanup() {
    kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
sleep 1
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | grep -q "127.0.0.1:$PORT" || { echo "error: the media server is not listening on 127.0.0.1:$PORT" >&2; exit 1; }
B=http://127.0.0.1:$PORT

failed=0
fail() {
    echo "FAIL $*"
    failed=$((failed + 1))
}

# Prints, for one segment: <video packets> <video first> <video last> <audio packets> <audio first> <audio last>.
segment_times() {
    "$FFPROBE" -v error -show_entries packet=codec_type,pts_time -of csv=p=0 "$1" | awk -F, '
        $2 != "N/A" { t = $2 + 0
            if ($1 == "video") { vn++; if (vn == 1 || t < v0) v0 = t; if (vn == 1 || t > v1) v1 = t }
            if ($1 == "audio") { an++; if (an == 1 || t < a0) a0 = t; if (an == 1 || t > a1) a1 = t } }
        END { printf "%d %.3f %.3f %d %.3f %.3f\n", vn, v0, v1, an, a0, a1 }'
}

# Checks the segments of `dir`: durations at most `max` seconds (the last one excepted), sound in every segment,
# and, in segments with video, audio and video together (start and end within a second, 25 pictures a second).
# Sets NO_VIDEO to the number of segments without video. TOGETHER=0: video may start or end within a segment
# (the encoder refused it meanwhile), only the sound is checked there.
check_segments() { # name dir max
    name=$1
    dir=$2
    max=$3
    grep '^#EXTINF' "$dir/stream-test.m3u8" | sed 's/#EXTINF:\([0-9.]*\),.*/\1/' | sed '$d' > "$dir/durations.txt"
    long=$(awk -v max="$max" '$1 > max' "$dir/durations.txt" | wc -l | tr -d ' ')
    count=$(wc -l < "$dir/durations.txt" | tr -d ' ')
    [ "$count" -ge 5 ] || fail "$name: only $count segments"
    [ "$long" -eq 0 ] || fail "$name: $long segments longer than $max s: $(tr '\n' ' ' < "$dir/durations.txt")"
    no_video=0
    for segment in $(grep -v '^#' "$dir/stream-test.m3u8"); do
        file=$dir/$(basename "$segment")
        [ -f "$file" ] || continue
        set -- $(segment_times "$file")
        vn=$1 v0=$2 v1=$3 an=$4 a0=$5 a1=$6
        echo "    $(basename "$file"): video $vn [$v0, $v1] audio $an [$a0, $a1]" >> "$dir/segments.txt"
        [ "$an" -gt 0 ] || fail "$name: $(basename "$file") has no audio"
        if [ "$vn" -eq 0 ]; then
            no_video=$((no_video + 1))
            continue
        fi
        [ "${TOGETHER:-1}" = 1 ] || continue
        if ! awk -v vn="$vn" -v v0="$v0" -v v1="$v1" -v a0="$a0" -v a1="$a1" 'BEGIN {
                d = v0 - a0; if (d < 0) d = -d; e = v1 - a1; if (e < 0) e = -e
                span = v1 - v0 + 0.04; rate = vn / span
                exit !(d <= 1 && e <= 1 && rate > 20 && rate < 30) }'; then
            fail "$name: $(basename "$file") audio and video apart: video $vn [$v0, $v1] audio $an [$a0, $a1]"
        fi
    done
    NO_VIDEO=$no_video
}

run_live() { # name url seconds [refused times, FLUXO_TEST_REFUSE_ENCODER]
    dir=$WORK/$1
    rm -rf "$dir"
    mkdir -p "$dir"
    env FLUXO_TEST_REFUSE_ENCODER="${4:-}" "$BIN" "$2" "$dir" "$3" 0 0 600 > "$dir/engine.log" 2>&1 || true
}

for test in $TESTS; do
    case $test in
    restart)
        for codec in mpeg2 high10; do
            name=restart-$codec
            echo "=== $name (live, timestamps start again every 12 s)"
            case $codec in mpeg2) rate=440 ;; *) rate=220 ;; esac
            run_live "$name" "$B/slow/$rate/live/user/pass/$codec-restart.ts" 46
            check_segments "$name" "$WORK/$name" 3.5
            [ "$NO_VIDEO" -eq 0 ] || fail "$name: $NO_VIDEO segments without video"
            echo "    durations: $(tr '\n' ' ' < "$WORK/$name/durations.txt")"
        done
        ;;
    refuse)
        for window in 10:24 0:12; do
            case $window in 0:*) name=refuse-start-live ;; *) name=refuse-live ;; esac
            echo "=== $name (live, the encoder refuses the pictures from ${window%:*} to ${window#*:} s)"
            run_live "$name" "$B/slow/440/live/user/pass/mpeg2-long.ts" 40 "$window"
            dir=$WORK/$name
            ! grep -q 'state=failed' "$dir/engine.log" || fail "$name: the engine failed: $(grep 'state=failed' "$dir/engine.log")"
            TOGETHER=0 check_segments "$name" "$dir" 3.5
            [ "$NO_VIDEO" -ge 4 ] || fail "$name: expected segments without video while refused, got $NO_VIDEO"
            tail -n 3 "$dir/segments.txt" | grep -q 'video [1-9]' || fail "$name: the picture did not come back"
            echo "    durations: $(tr '\n' ' ' < "$dir/durations.txt"); $NO_VIDEO without video"
        done

        # Nothing asks for segments here (the player stays at the first one), so the reader writes them all; those
        # written without a picture are deleted once pictures come again (the player would get them again).
        for window in 10:24 0:12; do
            case $window in 0:*) name=refuse-start-vod ;; *) name=refuse-vod ;; esac
            echo "=== $name (on demand, the encoder refuses the pictures from ${window%:*} to ${window#*:} s)"
            dir=$WORK/$name
            rm -rf "$dir"
            mkdir -p "$dir"
            env FLUXO_TEST_REFUSE_ENCODER="$window" "$BIN" "$B/movie/user/pass/mpeg2-long.ts" "$dir" 25 0 0 600 vod > "$dir/engine.log" 2>&1 || true
            ! grep -q 'state=failed' "$dir/engine.log" || fail "$name: the engine failed: $(grep 'state=failed' "$dir/engine.log")"
            grep -q '#EXT-X-ENDLIST' "$dir/stream-test.m3u8" || fail "$name: the playlist did not end"
            written=$(ls "$dir" | grep -c '^stream-test.*\.ts$' || true)
            planned=$(grep -c '^#EXTINF' "$dir/stream-test.m3u8" || true)
            reported=$(grep -c 'segment written=' "$dir/engine.log" || true)
            deleted=$((planned - written))
            [ "$reported" -eq "$planned" ] || fail "$name: $reported of $planned segments written"
            TOGETHER=0 check_segments "$name" "$dir" 6
            # The first segment (the one the player asked for) is kept even without a picture.
            [ "$NO_VIDEO" -le 1 ] || fail "$name: $NO_VIDEO segments without video left on disk"
            [ "$deleted" -ge 4 ] || fail "$name: expected the segments without video to be deleted, $deleted were"
            echo "    $reported of $planned segments written, $deleted without a picture deleted, $NO_VIDEO without video kept"
        done
        ;;
    convert)
        name=convert
        echo "=== $name (file conversion of MPEG-2 video)"
        dir=$WORK/$name
        rm -rf "$dir"
        mkdir -p "$dir"
        if env FLUXO_TEST_REFUSE_ENCODER=10:24 "$BIN" convert "$MEDIA/mpeg2-long.ts" "$dir/refused.mp4" > "$dir/refused.log" 2>&1; then
            fail "$name: the conversion succeeded although the encoder was refused"
        fi
        grep -q 'ret=-1447385158' "$dir/refused.log" || fail "$name: not FLUXO_REMUX_ERROR_ENCODER_UNAVAILABLE: $(cat "$dir/refused.log")"
        [ ! -e "$dir/refused.mp4" ] || fail "$name: a partial file was left"
        # Refused as the conversion starts (the encoder cannot even be opened): the same, not an unsupported format.
        if env FLUXO_TEST_REFUSE_ENCODER=0:1000 "$BIN" convert "$MEDIA/mpeg2-long.ts" "$dir/refused-start.mp4" > "$dir/refused-start.log" 2>&1; then
            fail "$name: the conversion succeeded although the encoder was refused from the start"
        fi
        grep -q 'ret=-1447385158' "$dir/refused-start.log" || fail "$name: refused from the start, not FLUXO_REMUX_ERROR_ENCODER_UNAVAILABLE: $(cat "$dir/refused-start.log")"
        [ ! -e "$dir/refused-start.mp4" ] || fail "$name: a partial file was left (refused from the start)"
        "$BIN" convert "$MEDIA/mpeg2-long.ts" "$dir/converted.mp4" > "$dir/converted.log" 2>&1 || fail "$name: $(cat "$dir/converted.log")"
        frames=$("$FFPROBE" -v error -count_packets -select_streams v:0 -show_entries stream=codec_name,nb_read_packets -of csv=p=0 "$dir/converted.mp4" 2>/dev/null || true)
        case $frames in h264,1500) ;; *) fail "$name: expected 1500 H.264 pictures, got $frames" ;; esac
        echo "    refused: $(cat "$dir/refused.log"); refused from the start: $(cat "$dir/refused-start.log"); converted: $frames"
        ;;
    esac
done
echo "--- logs in $WORK"
if [ "$failed" -eq 0 ]; then
    echo "all passed"
else
    echo "$failed failed"
    exit 1
fi
