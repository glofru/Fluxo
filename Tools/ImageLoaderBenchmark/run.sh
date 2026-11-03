#!/bin/sh
# Benchmarks LogoImageLoader against the former logo path (macOS).
#
#   Tools/ImageLoaderBenchmark/run.sh          # 200 logos
#   COUNT=500 Tools/ImageLoaderBenchmark/run.sh
#
# A 1024x1024 PNG is generated with the ffmpeg command line tool and served by a Python HTTP server bound to
# 127.0.0.1 only; every request uses a distinct query string, so each one is a distinct logo URL.
set -eu

FFMPEG=${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}
PORT=${PORT:-18931}
COUNT=${COUNT:-200}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=$(mktemp -d /tmp/fluxo-image-bench.XXXXXX)
mkdir -p "$WORK/www"

cleanup() {
    kill "${HTTP_PID:-0}" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

"$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=1024x1024" -frames:v 1 "$WORK/www/logo.png"
ls -l "$WORK/www/logo.png" | awk '{print "source logo: 1024x1024 PNG, " $5 " bytes"}'

xcrun swiftc -O -swift-version 5 -D FLUXO_LOADER_STATISTICS -o "$WORK/bench" \
    "$ROOT/Fluxo/App/Images/LogoImageLoader.swift" "$HERE/main.swift" 2> "$WORK/build.log" \
    || { cat "$WORK/build.log"; exit 1; }

python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" > /dev/null 2> "$WORK/http.log" &
HTTP_PID=$!
sleep 1

"$WORK/bench" "http://127.0.0.1:$PORT/logo.png" "$WORK/www/logo.png" "$COUNT"

echo "HTTP requests served: legacy $(grep -c 'legacy=' "$WORK/http.log" || true), loader logos $(grep -c 'logo.png?logo=' "$WORK/http.log" || true) (cold + disk-cache runs), coalesced $(grep -c 'shared=' "$WORK/http.log" || true), cancelled-run $(grep -c 'cancel=' "$WORK/http.log" || true)"
