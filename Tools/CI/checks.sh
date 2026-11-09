#!/bin/bash
# Runs the checks under Tools/ (each compiles the app's own sources with swiftc, or the C engine with clang, and
# exercises them on synthetic data), with sizes that keep a CI run to minutes. They used to drift silently when
# nobody ran them; CI runs them all (.github/workflows/ci.yml).
#
#   Tools/CI/checks.sh                    # every check
#   Tools/CI/checks.sh guide series      # some of them (names below)
#   SOURCE_PACKAGES=<derived data>/SourcePackages Tools/CI/checks.sh legal
#
# http-input also needs Node.js (skipped without it). The checks marked "ffmpeg" need the ffmpeg command line program
# (`brew install ffmpeg`, a test tool only: nothing links it); without it they are skipped, unless REQUIRE_FFMPEG=1.
# Nothing goes on the network: every server is bound to 127.0.0.1, and GuideCheck runs offline. One check at a time;
# each one's log is in $LOG_DIR/check-<name>.log.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
log_dir="${LOG_DIR:-/tmp/fluxo-logs}"
mkdir -p "$log_dir"
FFMPEG_BIN="${FFMPEG:-$(command -v ffmpeg || true)}"

ALL=(legal ffmpeg-framework sync series featured home-queries guide library playlist image-loader engine http-input test-streams)

run_check() { # name
    case "$1" in
        legal) "$ROOT/Tools/Legal/check-acknowledgements.sh" ${SOURCE_PACKAGES:+"$SOURCE_PACKAGES"} ;;
        ffmpeg-framework) "$ROOT/Tools/FFmpeg/check.sh" ;;
        sync) "$ROOT/Tools/SyncCheck/run.sh" ;;
        series) ENTRIES=20000 "$ROOT/Tools/SeriesCheck/run.sh" ;;
        featured) FILLER=5000 "$ROOT/Tools/FeaturedCheck/run.sh" ;;
        home-queries) CHANNELS=20000 "$ROOT/Tools/HomeQueriesCheck/run.sh" ;;
        guide) OFFLINE=1 CHANNELS=300 DAYS=3 "$ROOT/Tools/GuideCheck/run.sh" ;;
        library) "$ROOT/Tools/LibraryCheck/run.sh" ;;
        playlist) ENTRIES=20000 "$ROOT/Tools/PlaylistBenchmark/run.sh" ;;
        image-loader) COUNT=60 FFMPEG="$FFMPEG_BIN" "$ROOT/Tools/ImageLoaderBenchmark/run.sh" ;;
        engine) FFMPEG="$FFMPEG_BIN" "$ROOT/Tools/EngineSmokeTest/run.sh" ;;
        # The engine's HTTP input through the URL loading system: HTTP, TLS 1.2, TLS 1.3 only, HTTP/2 (needs Node.js).
        http-input) FFMPEG="$FFMPEG_BIN" "$ROOT/Tools/EngineSmokeTest/run_http.sh" http ;;
        test-streams) test_streams ;;
        *) echo "unknown check $1 (checks: ${ALL[*]})"; return 2 ;;
    esac
}

needs_ffmpeg() {
    case "$1" in image-loader | engine | http-input | test-streams) return 0 ;; *) return 1 ;; esac
}

# The simulator harness's loopback test server (Tools/Simulator/test_stream_server.py) starts, and every on-demand
# file it advertises is served.
test_streams() {
    local work port pid status=0
    work=$(mktemp -d /tmp/fluxo-ci-test-streams.XXXXXX)
    port=18995
    python3 -I "$ROOT/Tools/Simulator/test_stream_server.py" --port "$port" --work "$work" --ffmpeg "$FFMPEG_BIN" > "$work/server.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 180); do
        curl -sf -o /dev/null "http://127.0.0.1:$port/playlist.m3u" && break
        kill -0 "$pid" 2> /dev/null || break
        sleep 1
    done
    # The live HLS playlist appears once its encoder has written the first segments.
    for _ in $(seq 1 30); do
        curl -sf -o /dev/null "http://127.0.0.1:$port/hls/live.m3u8" && break
        sleep 1
    done
    for path in /playlist.m3u /movie/clip.mp4 /movie/clip.ts /movie/clip.mkv /movie/play/42 /movie/tracks.mkv /tracks/master.m3u8 /subtitles/clip.srt /hls/live.m3u8; do
        code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port$path")
        echo "  $path: $code"
        [ "$code" = 200 ] || status=1
    done
    kill "$pid" 2> /dev/null
    wait "$pid" 2> /dev/null
    [ "$status" = 0 ] || cat "$work/server.log"
    rm -rf "$work"
    return "$status"
}

selected=("$@")
[ ${#selected[@]} -gt 0 ] || selected=("${ALL[@]}")
failed=()
for name in "${selected[@]}"; do
    if needs_ffmpeg "$name" && [ -z "$FFMPEG_BIN" ]; then
        if [ "${REQUIRE_FFMPEG:-0}" = 1 ]; then
            echo "FAIL  $name (no ffmpeg command line program)"
            failed+=("$name")
        else
            echo "skip  $name (no ffmpeg command line program)"
        fi
        continue
    fi
    if [ "$name" = http-input ] && ! command -v node > /dev/null 2>&1; then
        # (The HTTPS test servers are Node.js: the system's Python has neither TLS 1.3 nor HTTP/2.)
        echo "skip  $name (no Node.js)"
        continue
    fi
    started=$(date +%s)
    if run_check "$name" > "$log_dir/check-$name.log" 2>&1; then
        echo "ok    $name ($(( $(date +%s) - started )) s)"
    else
        echo "FAIL  $name ($(( $(date +%s) - started )) s), last lines of $log_dir/check-$name.log:"
        tail -n 25 "$log_dir/check-$name.log" | sed 's/^/      /'
        failed+=("$name")
    fi
done
if [ ${#failed[@]} -gt 0 ]; then
    echo "${#failed[@]} check(s) failed: ${failed[*]}"
    exit 1
fi
echo "All checks passed."
