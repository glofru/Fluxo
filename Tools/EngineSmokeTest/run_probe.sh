#!/bin/sh
# Engine checks without AVPlayer, macOS (probe.c): fast enough to run under the sanitizers.
#
# - on-demand seeks: every container of the format matrix over HTTP (127.0.0.1), segments requested in the order of a
#   player that seeks forward and back (30% 66% 83% 30% 93% 10% of the playlist); FLV included, whose forward seeks
#   used to end the movie;
# - dead channels fail fast: a refused connection, a failed name lookup, 404 and 401 in about half a second, a
#   server that refuses the account (403, 5xx) in about 4 s;
# - a session that ended answers -2 for a segment that is not on disk (never 0, "wait");
# - a seek past the real end of an input whose duration is estimated too long ends it within seconds (it used to read
#   the whole input again from its start first);
# - a paused live channel's input is suspended and resumed (no segments meanwhile, a discontinuity after, the dates
#   following the durations across it).
#
#   Tools/EngineSmokeTest/run_probe.sh                 everything
#   SANITIZE=1 Tools/EngineSmokeTest/run_probe.sh      the same with AddressSanitizer and UndefinedBehaviorSanitizer (any
#                                                      report fails the run)
#   TLS=1.3 Tools/EngineSmokeTest/run_probe.sh         through an HTTPS front of the server: 1.2, 1.3 (TLS 1.3 only) or h2
#                                                      (HTTP/2), see tls.sh (needs Node.js)
#   FLUXO_HTTP_INPUT=ffmpeg Tools/EngineSmokeTest/run_probe.sh   with FFmpeg's http protocol instead of the URL loading
#                                                      system (the app's Legacy Networking)
#
# The media are the format matrix's (run_formats.sh MEDIA_ONLY=1 makes them, with ffmpeg).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/Tools/FFmpeg/env.sh"
PORT=${PORT:-18947}
MEDIA=${MEDIA:-/tmp/fluxo-format-media}
WORK=${WORK:-/tmp/fluxo-probe-check}
mkdir -p "$WORK"
BIN=$WORK/engine-probe

if [ ! -f "$MEDIA/flv-h264-aac.flv" ]; then
    MEDIA="$MEDIA" MEDIA_ONLY=1 FETCH=0 "$ROOT/Tools/EngineSmokeTest/run_formats.sh"
fi

# An FLV whose metadata say 120 s more than it has (the duration of an on-demand input is the planned playlist): a seek
# past its real end must end it, not read it again from its start (fluxo_vod_retry_seek).
if [ ! -f "$MEDIA/flv-overlong.flv" ]; then
    python3 -I - "$MEDIA/flv-h264-aac.flv" "$MEDIA/flv-overlong.flv" <<'PY'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
at = data.find(b"duration", 0, 4096)
assert at > 0 and data[at + 8] == 0, "no AMF number after onMetaData duration"
value = struct.unpack(">d", data[at + 9:at + 17])[0]
data[at + 9:at + 17] = struct.pack(">d", value + 120)
open(sys.argv[2], "wb").write(data)
PY
fi

FLAGS="-O1 -g"
if [ "${SANITIZE:-0}" = 1 ]; then
    # Every report stops the process (and fails its check).
    FLAGS="$FLAGS -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer"
    export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=0:halt_on_error=1}
    export UBSAN_OPTIONS=${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}
fi
# shellcheck disable=SC2086 # FLAGS / FFMPEG_CFLAGS / FFMPEG_LDFLAGS / FLUXO_ENGINE_SOURCES are lists of words.
clang $FLAGS -Wall -Wextra -Wno-unused-parameter -DFLUXO_ENGINE_TRACE -DFLUXO_ENGINE_TESTING -o "$BIN" -I "$ROOT/Fluxo/Features/Player/Engine" $FFMPEG_CFLAGS \
    "$ROOT/Tools/EngineSmokeTest/probe.c" $FLUXO_ENGINE_SOURCES $FFMPEG_LDFLAGS

cleanup() {
    # (Never "kill 0": that is the whole process group.)
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
    # TLS=…: the HTTPS front (tls.sh).
    if command -v tls_stop_all > /dev/null 2>&1; then
        tls_stop_all
    fi
}
trap cleanup EXIT INT TERM
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN > /dev/null 2>&1; then
    echo "error: port $PORT is in use; set PORT" >&2
    exit 1
fi
# Loopback only (vod_server.py binds 127.0.0.1).
python3 -I "$ROOT/Tools/EngineSmokeTest/vod_server.py" --root "$MEDIA" --port "$PORT" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | grep -q "127.0.0.1:$PORT" || { echo "error: the media server is not listening on 127.0.0.1:$PORT" >&2; exit 1; }

B=http://127.0.0.1:$PORT
if [ -n "${TLS:-}" ]; then
    # TLS=1.2|1.3|h2: through an HTTPS front of the server (tls.sh).
    . "$ROOT/Tools/EngineSmokeTest/tls.sh"
    tls_wrap "$PORT" "$WORK"
fi
# A port of 127.0.0.1 nothing listens on (refused connections).
CLOSED=1
while lsof -nP -iTCP:"$CLOSED" -sTCP:LISTEN > /dev/null 2>&1; do CLOSED=$((CLOSED + 1)); done
# name|mode|url|argument
CASES="
vod-flv-h264-aac|vod|$B/movie/u/p/flv-h264-aac.flv|30% 66% 83% 30% 93% 10%
vod-flv-flv1-mp3|vod|$B/movie/u/p/flv-flv1-mp3.flv|30% 66% 83% 30% 93% 10%
vod-mkv-h264-aac|vod|$B/movie/u/p/mkv-h264-aac.mkv|30% 66% 83% 30% 93% 10%
vod-mkv-tracks|vod|$B/movie/u/p/mkv-tracks-dts-ac3-srt-ass.mkv|30% 66% 83% 30% 93% 10%
vod-mp4-hev1-aac|vod|$B/movie/u/p/mp4-hev1-aac.mp4|30% 66% 83% 30% 93% 10%
vod-ts-h264-aac|vod|$B/movie/u/p/ts-h264-aac.ts|30% 66% 83% 30% 93% 10%
vod-ts-mpeg2-mp2|vod|$B/movie/u/p/ts-mpeg2-mp2.ts|30% 66% 83% 30% 93% 10%
vod-avi-xvid-mp3|vod|$B/movie/u/p/avi-xvid-mp3.avi|30% 66% 83% 30% 93% 10%
vod-wmv-wmv2-wma2|vod|$B/movie/u/p/wmv-wmv2-wma2.wmv|30% 66% 83% 30% 93% 10%
vod-mpg-mpeg2-mp2|vod|$B/movie/u/p/mpg-mpeg2-mp2.mpg|30% 66% 83% 30% 93% 10%
vod-webm-vp9-opus|vod|$B/movie/u/p/webm-vp9-opus.webm|30% 66% 83% 30% 93% 10%
vod-flv-no-ranges|vod|$B/norange/movie/u/p/flv-h264-aac.flv|30% 66% 83% 30%
dead-refused|dead|http://127.0.0.1:$CLOSED/live/u/p/1.ts|1.5
dead-no-such-host|dead|http://no-such-host.invalid/live/u/p/1.ts|1.5
dead-404|dead|$B/live/u/p/no-such-channel.ts|1.5
dead-401|dead|$B/status/401/live/u/p/1.ts|1.5
dead-403|dead|$B/status/403/live/u/p/1.ts|4.5
dead-503|dead|$B/status/503/live/u/p/1.ts|4.5
finished-mkv|finished|$MEDIA/mkv-h264-aac.mkv|
vod-flv-overlong|vod|$B/slow/400/movie/u/p/flv-overlong.flv|10% 40% 20%
ended-flv-overlong|ended|$B/slow/400/movie/u/p/flv-overlong.flv|80% 12
suspend-live|suspend|$B/slow/130/live/u/p/ts-h264-aac.ts|
"
passed=0
failed=0
summary=""
IFS='
'
for line in $CASES; do
    [ -n "$line" ] || continue
    name=$(echo "$line" | cut -d'|' -f1)
    mode=$(echo "$line" | cut -d'|' -f2)
    url=$(echo "$line" | cut -d'|' -f3)
    argument=$(echo "$line" | cut -d'|' -f4)
    out=$WORK/out-$name
    rm -rf "$out"
    mkdir -p "$out"
    unset IFS
    # shellcheck disable=SC2086 # the segment indexes are words.
    if "$BIN" "$mode" "$url" "$out" $argument > "$WORK/$name.log" 2>&1; then
        passed=$((passed + 1))
        result=PASS
    else
        failed=$((failed + 1))
        result=FAIL
    fi
    IFS='
'
    detail=$(grep -E '^\[probe\] (vod|dead|finished|ended|suspend|convert) ' "$WORK/$name.log" | tail -n 1 || true)
    if grep -qE 'ERROR: AddressSanitizer|runtime error:' "$WORK/$name.log"; then
        detail="$detail (sanitizer: $(grep -m 1 -E 'ERROR: AddressSanitizer|runtime error:' "$WORK/$name.log"))"
    fi
    echo "$result $name $detail"
    summary="$summary
$result $name"
done
unset IFS
echo "--- summary (logs in $WORK)$summary"
echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]
