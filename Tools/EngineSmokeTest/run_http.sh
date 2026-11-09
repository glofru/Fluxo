#!/bin/sh
# The engine's HTTP input through the URL loading system (FluxoEngineHTTP.m), against local servers on 127.0.0.1 only,
# macOS. Plain HTTP (vod_server.py), and HTTPS fronts of it (tls_proxy.mjs, Node.js): TLS 1.2 only, TLS 1.3 only and
# HTTP/2 (TLS 1.3), with certificates of a test authority of the check's own (tls.sh), which only the check trusts.
#
# 1. http_check, the connections themselves: every byte of a file and of byte ranges (past 4 GB too, a sparse file of
#    5 GB), the response (status, size, byte ranges, MIME type, the address after redirections); 4 redirections,
#    relative and absolute; a cookie set by a redirection; Basic authentication from the address (after a redirection
#    within its server too, never sent to another server a redirection leads to, unless the Location has its own); a
#    206 without Content-Range; the error of each HTTP status, of a refused connection and of an unknown host; a
#    SHOUTcast status line (the fallback to FFmpeg's http protocol); a read timeout; a server that sends headers and
#    then nothing (fails after one timeout); an interrupt (cancellation); flow control (memory stays bounded while
#    nothing reads); a connection unread for longer than the timeout, which reads on; the cookies of a client, which no
#    other client has and which go with it; a certificate for another name, one of no authority, a client certificate
#    asked for (failed handshake).
# 2. engine-probe, the whole engine: on-demand seeks in movies over every server variant, through a connection that
#    breaks off every 3 MB (made again at the position), a server that stops for 20 s once (the read timeout, then made
#    again), one that stops for 5 s on every response (slow, no timeout), redirections, cookies, authentication,
#    SHOUTcast (FFmpeg's http protocol), no byte ranges; live MPEG-TS without a length (chunked) and broken off every
#    1.5 MB (made again); live HLS behind an address without extension and a redirection (the playlist reloads and
#    segments through the URL loading system, relative to the address after the redirection); AES-128 HLS, live and on
#    demand, over HTTP and TLS 1.3 only (the engine decrypts the segments it reads through the URL loading system), with
#    a segment whose server stops for 2 minutes: the read times out (after 3 s here) and the channel goes on, through the
#    URL loading system, through FFmpeg's io_open (FLUXO_TEST_DEMUXER_REQUESTS=ffmpeg: the timeout the engine gives the
#    requests it leaves to FFmpeg) and through FFmpeg's http protocol (FLUXO_HTTP_INPUT=ffmpeg: the timeout the engine's
#    AVIOContext exports to the HLS demuxer); and FFmpeg's http protocol against the TLS 1.3 only server, which it
#    cannot talk to (Secure Transport stops at TLS 1.2).
# 2b. engine-paced: a movie played at 6 times real time with an I/O timeout of 2 s, with and without byte ranges, over
#    HTTP/1.1 and HTTP/2: the connection the engine leaves unread between its read-ahead stops (5 s at a time) must not
#    time out (no drop, no reopening, never Reconnecting).
# 3. CPU time and peak memory of the two inputs (FLUXO_HTTP_INPUT=system / ffmpeg): a 1080p movie of 20 Mbit/s read
#    whole on demand (engine-probe read), as fast as it goes and paced at 4 MB/s, over HTTP and TLS 1.2, and a live
#    channel of 60 s (summary.txt).
#
#   Tools/EngineSmokeTest/run_http.sh                 everything
#   Tools/EngineSmokeTest/run_http.sh http engine     the parts whose name contains one of the words (http, engine,
#                                                     engine-paced, cost; "engine" runs engine-paced too)
#
# Needs Node.js and ffmpeg (Tools/FFmpeg/env.sh); the engine's part plays the media of run_vod.sh (made when missing).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/Tools/FFmpeg/env.sh"
. "$ROOT/Tools/EngineSmokeTest/tls.sh"
PORT=${PORT:-18950}
MEDIA=${MEDIA:-/tmp/fluxo-vod-media}
WORK=${WORK:-/tmp/fluxo-http-check}
TLS_DIR=$WORK/tls
mkdir -p "$WORK"
SUMMARY=$WORK/summary.txt
: > "$SUMMARY"

PARTS="$*"
part() {
    [ -z "$PARTS" ] && return 0
    for word in $PARTS; do
        case $1 in *"$word"*) return 0 ;; esac
    done
    return 1
}

mkdir -p "$WORK/media"
# The engine's cases play the movies of run_vod.sh (made when missing, a few minutes); the connections need one file.
if { part engine || part engine-paced; } && [ ! -f "$MEDIA/done-600" ]; then
    MEDIA="$MEDIA" DURATION=600 "$ROOT/Tools/EngineSmokeTest/run_vod.sh" no-such-case > /dev/null
fi
if [ -f "$MEDIA/done-600" ]; then
    for name in h264.mkv 1001.mkv 1002.ts h264.ts hls; do
        ln -sfn "$MEDIA/$name" "$WORK/media/$name"
    done
elif [ ! -f "$WORK/media/h264.mkv" ]; then
    "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=640x360:rate=25:duration=60" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=60" -c:v libx264 -preset veryfast -g 50 -c:a aac -b:a 96k \
        "$WORK/media/h264.mkv"
fi
# A sparse file of 5 GB with random blocks around 4 GB and at its end (byte positions past 32 bits).
if [ ! -f "$WORK/media/large.bin" ]; then
    python3 -I - "$WORK/media/large.bin" <<'PY'
import os, sys
size = 5 * 1024 ** 3 + 12345
with open(sys.argv[1], "wb") as f:
    f.truncate(size)
    for offset in (0, 4 * 1024 ** 3 - 7, 4 * 1024 ** 3 + 1000, size - 4096):
        f.seek(offset)
        f.write(os.urandom(min(4096, size - offset)))
PY
fi
# 1080p at 20 Mbit/s, 2 minutes (the cost comparison).
if part cost && [ ! -f "$WORK/media/1080p.mkv" ]; then
    "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=25:duration=120" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=120" -c:v libx264 -preset ultrafast -b:v 20M -maxrate 20M -bufsize 20M \
        -g 50 -c:a aac -b:a 128k "$WORK/media/1080p.mkv"
fi
tls_make_certs "$TLS_DIR"
export FLUXO_TEST_CA_FILE="$TLS_DIR/ca.pem"
# Every error of the URL loading system goes to the logs (NSError, -DFLUXO_ENGINE_TESTING builds only).
export FLUXO_HTTP_TRACE=1

BIN=$WORK/bin
mkdir -p "$BIN"
# -DFLUXO_ENGINE_TESTING: the engine trusts the test authority (FLUXO_TEST_CA_FILE); never in the app.
# shellcheck disable=SC2086 # FFMPEG_CFLAGS / FFMPEG_LDFLAGS / FLUXO_ENGINE_SOURCES are lists of words.
clang -O1 -g -Wall -Wextra -DFLUXO_ENGINE_TESTING -o "$BIN/http-check" -I "$ROOT/Fluxo/Features/Player/Engine" $FFMPEG_CFLAGS \
    "$ROOT/Tools/EngineSmokeTest/http_check.c" "$ROOT/Fluxo/Features/Player/Engine/FluxoEngineHTTP.m" $FFMPEG_LDFLAGS
# shellcheck disable=SC2086
clang -O1 -g -Wall -Wextra -Wno-unused-parameter -DFLUXO_ENGINE_TRACE -DFLUXO_ENGINE_TESTING -o "$BIN/engine-probe" \
    -I "$ROOT/Fluxo/Features/Player/Engine" $FFMPEG_CFLAGS "$ROOT/Tools/EngineSmokeTest/probe.c" $FLUXO_ENGINE_SOURCES $FFMPEG_LDFLAGS

SERVER_PIDS=
cleanup() {
    tls_stop_all
    for pid in $SERVER_PIDS; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM
for port in $PORT $((PORT + 1)) $((PORT + 2)) $((PORT + 3)) $((PORT + 4)) $((PORT + 5)) $((PORT + 6)) $((PORT + 7)); do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN > /dev/null 2>&1; then
        echo "error: port $port is in use; set PORT" >&2
        exit 1
    fi
done
# Loopback only (vod_server.py and tls_proxy.mjs bind 127.0.0.1).
python3 -I "$ROOT/Tools/EngineSmokeTest/vod_server.py" --root "$WORK/media" --port "$PORT" --log-headers > "$WORK/server.log" 2>&1 &
SERVER_PIDS="$SERVER_PIDS $!"
sleep 1
# Another server (another port), which the redirections of /to/<port>/ lead to.
OTHER=$((PORT + 7))
python3 -I "$ROOT/Tools/EngineSmokeTest/vod_server.py" --root "$WORK/media" --port "$OTHER" --log-headers > "$WORK/server-other.log" 2>&1 &
SERVER_PIDS="$SERVER_PIDS $!"
sleep 1
for port in $PORT $OTHER; do
    lsof -nP -iTCP:"$port" -sTCP:LISTEN | grep -q "127.0.0.1:$port" || { echo "error: the media server is not listening on 127.0.0.1:$port" >&2; exit 1; }
done
tls_front 1.2 $((PORT + 1)) "$PORT" "$WORK/tls12.log"
tls_front 1.3 $((PORT + 2)) "$PORT" "$WORK/tls13.log"
tls_front h2 $((PORT + 3)) "$PORT" "$WORK/h2.log"
tls_start $((PORT + 4)) "$PORT" "$WORK/wrong-name.log" --cert "$TLS_DIR/wrong-name.pem" --key "$TLS_DIR/wrong-name.key"
tls_start $((PORT + 5)) "$PORT" "$WORK/self-signed.log" --cert "$TLS_DIR/self-signed.pem" --key "$TLS_DIR/self-signed.key"
tls_start $((PORT + 6)) "$PORT" "$WORK/client-cert.log" --cert "$TLS_DIR/server.pem" --key "$TLS_DIR/server.key" --tls 1.2 \
    --client-cert "$TLS_DIR/ca.pem"

HTTP=http://127.0.0.1:$PORT
TLS12=https://127.0.0.1:$((PORT + 1))
TLS13=https://127.0.0.1:$((PORT + 2))
H2=https://127.0.0.1:$((PORT + 3))
M=$WORK/media
passed=0
failed=0
summary=""
# check <name> <command>...: runs a check, its log in $WORK/<name>.log.
check() {
    name=$1
    shift
    if "$@" > "$WORK/$name.log" 2>&1; then
        passed=$((passed + 1))
        result=PASS
    else
        failed=$((failed + 1))
        result=FAIL
    fi
    detail=$(grep -E '^\[(http|probe)\] (get|error|timeout|cancel|flow|pause|cookies|vod|dead|live|read|play) ' "$WORK/$name.log" | tail -n 1 || true)
    echo "$result $name $detail"
    summary="$summary
$result $name"
}
probe() {
    out=$WORK/out
    rm -rf "$out"
    mkdir -p "$out"
    mode=$1
    url=$2
    shift 2
    "$BIN/engine-probe" "$mode" "$url" "$out" "$@"
}
# probe_with "<VARIABLE=value>..." <mode> <url> <arguments>...: probe with those environment variables.
probe_with() {
    out=$WORK/out
    rm -rf "$out"
    mkdir -p "$out"
    variables=$1
    mode=$2
    url=$3
    shift 3
    # shellcheck disable=SC2086 # the assignments are separate words.
    env $variables "$BIN/engine-probe" "$mode" "$url" "$out" "$@"
}

# MARK: 1. The connections
if part http; then
    for variant in "http|$HTTP" "tls12|$TLS12" "tls13|$TLS13" "h2|$H2"; do
        v=${variant%%|*}
        B=${variant#*|}
        check "http-$v-whole" env HTTP_CHECK_EXPECT="status=206 seekable=1 mime=video/x-matroska" "$BIN/http-check" get "$B/movie/user/pass/h264.mkv" "$M/h264.mkv"
        check "http-$v-range" env HTTP_CHECK_EXPECT="status=206 start=1000000" "$BIN/http-check" get "$B/h264.mkv" "$M/h264.mkv" 1000000
        check "http-$v-byte-range" "$BIN/http-check" get "$B/h264.mkv" "$M/h264.mkv" 1000 5000
        check "http-$v-past-4gb" env HTTP_CHECK_EXPECT="status=206 size=5368721465 start=4294967289" "$BIN/http-check" get "$B/large.bin" "$M/large.bin" 4294967289 4294980000
        check "http-$v-no-ranges" env HTTP_CHECK_EXPECT="status=200 seekable=0" "$BIN/http-check" get "$B/norange/h264.mkv" "$M/h264.mkv"
        check "http-$v-redirects" env HTTP_CHECK_EXPECT="location-suffix=/movie/user/pass/h264.mkv" "$BIN/http-check" get "$B/redirect/4/movie/user/pass/h264.mkv" "$M/h264.mkv"
        check "http-$v-cookie" "$BIN/http-check" get "$B/cookie/h264.mkv?$v" "$M/h264.mkv"
        check "http-$v-auth" "$BIN/http-check" get "$(echo "$B" | sed 's#://#://user:pass@#')/auth/h264.mkv" "$M/h264.mkv"
        check "http-$v-auth-missing" "$BIN/http-check" error "$B/auth/h264.mkv" 401
        # Redirected within the same server (an absolute Location, then a relative one): the credentials still answer it.
        check "http-$v-auth-redirect-same-server" "$BIN/http-check" get "$(echo "$B" | sed 's#://#://user:pass@#')/redirect/2/auth/h264.mkv" "$M/h264.mkv"
        # Redirected to another server (http://127.0.0.1:$OTHER; from https:// a downgrade too): it never gets them.
        check "http-$v-auth-redirect-other-server" "$BIN/http-check" error "$(echo "$B" | sed 's#://#://user:pass@#')/to/$OTHER/auth/h264.mkv" 401
        # ... unless the new address has its own (FFmpeg takes them from the Location).
        check "http-$v-auth-redirect-own-credentials" "$BIN/http-check" get "$B/tocreds/$OTHER/auth/h264.mkv" "$M/h264.mkv"
        # A 206 without Content-Range (nor Accept-Ranges): the range asked for, the size from the length, seekable.
        check "http-$v-no-content-range" env HTTP_CHECK_EXPECT="status=206 seekable=1 start=1000000 size=$(wc -c < "$M/h264.mkv" | tr -d ' ')" \
            "$BIN/http-check" get "$B/nocontentrange/h264.mkv" "$M/h264.mkv" 1000000
        check "http-$v-403" "$BIN/http-check" error "$B/status/403/h264.mkv" 403
        check "http-$v-404" "$BIN/http-check" error "$B/no-such-file.mkv" 404
        check "http-$v-429" "$BIN/http-check" error "$B/status/429/h264.mkv" 429
        check "http-$v-418" "$BIN/http-check" error "$B/status/418/h264.mkv" 4xx
        check "http-$v-503" "$BIN/http-check" error "$B/status/503/h264.mkv" 5xx
        check "http-$v-too-many-redirects" "$BIN/http-check" error "$B/redirect/9/h264.mkv" eio
        check "http-$v-broken-off" "$BIN/http-check" error "$B/flaky/300000/h264.mkv" "eio|reset"
        check "http-$v-chunked" env HTTP_CHECK_EXPECT="status=200 seekable=0 size=-1" "$BIN/http-check" get "$B/chunked/h264.mkv" "$M/h264.mkv"
        check "http-$v-timeout" "$BIN/http-check" timeout "$B/stall/20000/h264.mkv" 2000
        check "http-$v-headers-then-nothing" env HTTP_CHECK_WHOLE=1 "$BIN/http-check" timeout "$B/headersonly/h264.mkv" 2000
        check "http-$v-cookies-of-the-client" "$BIN/http-check" cookies "$B/cookie/h264.mkv?client-$v" fluxo-token=1
        check "http-$v-cancel" "$BIN/http-check" cancel "$B/stall/20000/h264.mkv" 1500
        check "http-$v-cancel-before-response" "$BIN/http-check" cancel "$B/lat/20000/h264.mkv" 1000
        check "http-$v-flow" "$BIN/http-check" flow "$B/large.bin" "$M/large.bin"
        # Unread for longer than the timeout (2 s), suspended by the flow control: must read on, every byte, no error.
        check "http-$v-unread-longer-than-timeout" "$BIN/http-check" pause "$B/large.bin" "$M/large.bin" 2000 6000 67108864
    done
    CLOSED=1
    while lsof -nP -iTCP:"$CLOSED" -sTCP:LISTEN > /dev/null 2>&1; do CLOSED=$((CLOSED + 1)); done
    check http-refused "$BIN/http-check" error "http://127.0.0.1:$CLOSED/h264.mkv" refused
    check http-no-such-host "$BIN/http-check" error "http://no-such-host.invalid/h264.mkv" eio
    check http-icy "$BIN/http-check" error "$HTTP/icy/h264.mkv" incompatible
    check https-wrong-name "$BIN/http-check" error "https://127.0.0.1:$((PORT + 4))/h264.mkv" certificate
    check https-self-signed "$BIN/http-check" error "https://127.0.0.1:$((PORT + 5))/h264.mkv" certificate
    check https-client-certificate "$BIN/http-check" error "https://127.0.0.1:$((PORT + 6))/h264.mkv" handshake
    # Without the test authority: what the app does with a server it does not trust.
    check https-untrusted-authority env -u FLUXO_TEST_CA_FILE "$BIN/http-check" error "$TLS13/h264.mkv" certificate
fi

# MARK: 2. The engine
if part engine; then
    for variant in "http|$HTTP" "tls12|$TLS12" "tls13|$TLS13" "h2|$H2"; do
        v=${variant%%|*}
        B=${variant#*|}
        check "engine-$v-mkv" probe vod "$B/movie/user/pass/1001.mkv" 30% 66% 83% 30% 93% 10%
        check "engine-$v-ts" probe vod "$B/movie/user/pass/1002.ts" 30% 66% 83% 30% 93% 10%
        check "engine-$v-ts-no-ranges" probe vod "$B/norange/movie/user/pass/1002.ts" 30% 66% 30%
        check "engine-$v-broken-off" probe vod "$B/flaky/3000000/movie/user/pass/1001.mkv" 30% 66% 10% 90%
        check "engine-$v-stops-once" probe vod "$B/stallonce/20000/movie/user/pass/1001.mkv?$v" 30% 66% 10%
        check "engine-$v-slow" probe vod "$B/stall/5000/movie/user/pass/1001.mkv" 30% 66% 10%
        check "engine-$v-redirects-cookie" probe vod "$B/redirect/2/cookie/movie/user/pass/1001.mkv?$v" 50% 10%
        check "engine-$v-one-connection" probe vod "$B/slow/2000/busy/movie/user/pass/1001.mkv" 30% 66% 10%
        check "engine-$v-live-chunked" probe live "$B/slow/150/chunked/live/user/pass/1002.ts" 30 10
        check "engine-$v-live-broken-off" probe live "$B/flaky/1500000/slow/150/chunked/live/user/pass/1002.ts" 40 12
    done
    check engine-auth probe vod "http://user:pass@127.0.0.1:$PORT/auth/movie/user/pass/1001.mkv" 50% 10%
    check engine-no-content-range probe vod "$HTTP/nocontentrange/movie/user/pass/1001.mkv" 30% 66% 10% 90%
    check engine-icy-fallback probe vod "$HTTP/icy/movie/user/pass/1001.mkv" 50% 10%
    check engine-tls13-certificate-dead probe dead "https://127.0.0.1:$((PORT + 4))/live/user/pass/1002.ts" 1.5
    # FFmpeg's http protocol (Secure Transport) and a TLS 1.3 only server: it cannot connect. (Must fail.)
    # (env, not an assignment before the function: in sh that one stays set after the call.)
    rm -rf "$WORK/out"
    mkdir -p "$WORK/out"
    if env FLUXO_HTTP_INPUT=ffmpeg "$BIN/engine-probe" dead "$TLS13/live/user/pass/1002.ts" "$WORK/out" 10 > "$WORK/engine-ffmpeg-tls13.log" 2>&1; then
        passed=$((passed + 1))
        echo "PASS engine-ffmpeg-tls13-fails $(grep -E '^\[probe\] dead' "$WORK/engine-ffmpeg-tls13.log")"
    else
        failed=$((failed + 1))
        echo "FAIL engine-ffmpeg-tls13-fails (FFmpeg's http protocol connected to the TLS 1.3 only server)"
    fi

    # Live HLS: a playlist of 6 segments of 2 s written as it goes, behind an address without extension and one
    # redirection (the base of the segments is the address after it), through the URL loading system.
    rm -rf "$M/livehls"
    mkdir -p "$M/livehls"
    "$FFMPEG" -hide_banner -loglevel error -re -f lavfi -i "testsrc2=size=640x360:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -c:v libx264 -preset ultrafast -g 50 -c:a aac -b:a 96k -f hls -hls_time 2 -hls_list_size 6 -hls_flags delete_segments \
        -hls_segment_filename "$M/livehls/seg-%05d.ts" "$M/livehls/index.m3u8" &
    HLS_PID=$!
    SERVER_PIDS="$SERVER_PIDS $HLS_PID"
    sleep 8
    check engine-http-live-hls probe live "$HTTP/redirect/1/livehls/index" 30 10
    check engine-h2-live-hls probe live "$H2/redirect/1/livehls/index" 30 10
    kill "$HLS_PID" 2>/dev/null || true
    grep -q 'GET /livehls/seg-' "$WORK/h2.log" && echo "    (the HLS segments came over HTTP/2: $(grep -c 'GET /livehls/' "$WORK/h2.log") requests)"

    # AES-128 HLS. Live: the IV of each segment is its sequence number (no IV attribute); on demand: an explicit IV.
    rm -rf "$M/aeslive" "$M/aesvod"
    mkdir -p "$M/aeslive" "$M/aesvod"
    for kind in aeslive aesvod; do
        head -c 16 /dev/urandom > "$M/$kind/key.bin"
    done
    printf 'key.bin\n%s\n' "$M/aeslive/key.bin" > "$WORK/aeslive.keyinfo"
    printf 'key.bin\n%s\n%s\n' "$M/aesvod/key.bin" "$(head -c 16 /dev/urandom | xxd -p)" > "$WORK/aesvod.keyinfo"
    "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25:duration=120" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=120" \
        -c:v libx264 -preset ultrafast -g 50 -c:a aac -b:a 96k -f hls -hls_time 4 -hls_playlist_type vod -hls_key_info_file "$WORK/aesvod.keyinfo" \
        -hls_segment_filename "$M/aesvod/seg-%05d.ts" "$M/aesvod/index.m3u8"
    "$FFMPEG" -hide_banner -loglevel error -re -f lavfi -i "testsrc2=size=640x360:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -c:v libx264 -preset ultrafast -g 50 -c:a aac -b:a 96k -f hls -hls_time 2 -hls_list_size 6 -hls_flags delete_segments \
        -hls_key_info_file "$WORK/aeslive.keyinfo" -hls_segment_filename "$M/aeslive/seg-%05d.ts" "$M/aeslive/index.m3u8" &
    HLS_PID=$!
    SERVER_PIDS="$SERVER_PIDS $HLS_PID"
    sleep 8
    grep -q 'METHOD=AES-128' "$M/aeslive/index.m3u8" || echo "warning: the live playlist is not encrypted"
    check engine-http-live-aes-hls probe live "$HTTP/redirect/1/aeslive/index" 30 10
    check engine-tls13-live-aes-hls probe live "$TLS13/redirect/1/aeslive/index" 30 10
    check engine-tls13-vod-aes-hls probe vod "$TLS13/aesvod/index.m3u8" 30% 66% 83% 10%
    # A segment whose server stops for 2 minutes: the read must time out and the channel go on. With a timeout of 3 s
    # (FLUXO_PROBE_IO_TIMEOUT_MS): FFmpeg's crypto protocol reads its connection again after a failure, so a segment it
    # reads costs it two or three timeouts; without a timeout the engine would wait the whole run (a few segments, a
    # request that is never served). Each case its own prefix (the server counts the segments of each).
    T=FLUXO_PROBE_IO_TIMEOUT_MS=3000
    check engine-http-live-aes-hls-stalled-segment probe_with "$T" live "$HTTP/stallnth/3/120000/aeslive/index" 45 10
    check engine-tls13-live-aes-hls-stalled-segment probe_with "$T" live "$TLS13/stallnth/3/120001/aeslive/index" 45 10
    check engine-http-live-aes-hls-stalled-segment-ffmpeg-requests probe_with "$T FLUXO_TEST_DEMUXER_REQUESTS=ffmpeg" live \
        "$HTTP/stallnth/3/120002/aeslive/index" 45 10
    check engine-http-live-aes-hls-stalled-segment-ffmpeg-input probe_with "$T FLUXO_HTTP_INPUT=ffmpeg" live "$HTTP/stallnth/3/120003/aeslive/index" 45 10
    kill "$HLS_PID" 2>/dev/null || true
    check engine-http-vod-aes-hls-stalled-segment probe_with "$T" vod "$HTTP/stallnth/2/120000/aesvod/index.m3u8" 30% 66% 10%
    check engine-http-vod-aes-hls-stalled-segment-ffmpeg-requests probe_with "$T FLUXO_TEST_DEMUXER_REQUESTS=ffmpeg" vod \
        "$HTTP/stallnth/2/120001/aesvod/index.m3u8" 30% 66% 10%
    check engine-http-vod-aes-hls-stalled-segment-ffmpeg-input probe_with "$T FLUXO_HTTP_INPUT=ffmpeg" vod "$HTTP/stallnth/2/120002/aesvod/index.m3u8" \
        30% 66% 10%
    # (Every stalled segment's request was made: the server's log.)
    for prefix in 3/120000 3/120001 3/120002 3/120003 2/120000 2/120001 2/120002; do
        grep -q "GET /stallnth/$prefix/" "$WORK/server.log" || echo "warning: no request under /stallnth/$prefix"
    done
fi

# MARK: 2b. The engine at a player's pace
# A movie played from its start at 6 times real time for 60 s (6 minutes of it), with an I/O timeout of 2 s: the engine
# reads 60 s ahead, then stops reading until it is 30 s ahead, so the connection stays unread for 5 s at a time, the
# task suspended by the flow control (the movie is 0.6 Mbit/s: its 4 MB buffer holds about a minute). As FFmpeg's
# socket, the connection must not time out meanwhile: no drop within the input ("connection dropped"), no reopening
# of the movie ("reopened", fluxo_vod_recover), never Reconnecting; with and without byte ranges, over HTTP/1.1 and
# HTTP/2. (FLUXO_ENGINE_TRACE: the engine's trace in the log.)
# paced <url>: plays it so and fails on a drop or a reopening in the trace.
paced() {
    probe_with "FLUXO_PROBE_IO_TIMEOUT_MS=2000 FLUXO_ENGINE_TRACE=1" play "$1" 60 6 > "$WORK/paced.out" 2>&1
    status=$?
    cat "$WORK/paced.out"
    if grep -E 'connection dropped|reopened' "$WORK/paced.out" > /dev/null; then
        echo "[probe] read dropped or reopened while the connection was unread => FAIL"
        return 1
    fi
    return $status
}
if part engine-paced; then
    for variant in "http|$HTTP" "h2|$H2"; do
        v=${variant%%|*}
        B=${variant#*|}
        check "engine-$v-paced" paced "$B/movie/user/pass/1001.mkv?paced-$v"
        check "engine-$v-paced-no-ranges" paced "$B/norange/movie/user/pass/1001.mkv?paced-$v"
        # (Without byte ranges the movie is requested once: never read again from its start.)
        echo "    (requests of the movie, $v: $(grep -c "GET /movie/user/pass/1001.mkv?paced-$v" "$WORK/server.log") with byte ranges, $(grep -c "GET /norange/movie/user/pass/1001.mkv?paced-$v" "$WORK/server.log") without)"
    done
fi

# MARK: 3. Cost of the two inputs
# The movie read as fast as the loopback allows (throughput, CPU time per byte), and paced at 4 MB/s (1.6 times its
# bit rate, as the engine reads ahead of a player: CPU time per second of playback); a live channel at about its rate.
cost() {
    # (Not `name`: check sets it.)
    measured=$1
    shift
    rm -rf "$WORK/out-cost"
    mkdir -p "$WORK/out-cost"
    check "cost-$measured" "$@"
    echo "$measured: $(grep -E '^\[probe\] (read|live|footprint|cpu)' "$WORK/cost-$measured.log" | sed 's/^\[probe\] //' | tr '\n' ' ')" >> "$SUMMARY"
}
if part cost; then
    for variant in "http|$HTTP" "tls12|$TLS12"; do
        v=${variant%%|*}
        B=${variant#*|}
        for input in system ffmpeg; do
            cost "$v-movie-fast-$input" env FLUXO_HTTP_INPUT=$input "$BIN/engine-probe" read "$B/1080p.mkv" "$WORK/out-cost"
            cost "$v-movie-paced-$input" env FLUXO_HTTP_INPUT=$input "$BIN/engine-probe" read "$B/slow/4000/1080p.mkv" "$WORK/out-cost"
        done
    done
    for input in system ffmpeg; do
        cost "http-live-$input" env FLUXO_HTTP_INPUT=$input "$BIN/engine-probe" live "$HTTP/slow/300/chunked/live/user/pass/1002.ts" "$WORK/out-cost" 60 20
    done
    cat "$SUMMARY"
fi

echo "--- summary (logs in $WORK)$summary"
echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]
