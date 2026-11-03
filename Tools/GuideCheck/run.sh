#!/bin/bash
# Checks the TV guide pipeline (XMLTV streaming parser, gzip, channel matching, SwiftData import and every guide
# query) with the app's sources, on real public guides and on a synthetic large one, with timings and peak memory.
#
#   Tools/GuideCheck/run.sh                       # synthetic guide: 1,500 channels x 8 days of half-hour shows
#   CHANNELS=300 DAYS=3 Tools/GuideCheck/run.sh   # quicker
#   OFFLINE=1 Tools/GuideCheck/run.sh             # skip the downloads
#
# Real samples: epgshare01 (free XMLTV guides by country, https://epgshare01.online) for Italy and Albania, and
# the Pluto TV Italy guide of i.mjh.nz. Downloads go to their own folder and are only read by the parser.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CHANNELS="${CHANNELS:-1500}"
DAYS="${DAYS:-8}"
OUT="${OUT:-$(mktemp -d /tmp/fluxo-guide-check.XXXXXX)}"
SRC="$ROOT/Fluxo"

mkdir -p "$OUT/bin" "$OUT/samples" "$OUT/synthetic"
xcrun swiftc -O -swift-version 5 -parse-as-library -o "$OUT/bin/guide-check" \
    "$SRC/Features/Playlist/Playlist.swift" \
    "$SRC/Features/Playlist/ChannelContentKind.swift" \
    "$SRC/Features/Playlist/Import/M3UParser.swift" \
    "$SRC/Features/Library/ChannelBookmark.swift" \
    "$SRC/Features/Library/ChannelLibrary.swift" \
    "$SRC/Features/Home/HomeQueries.swift" \
    "$SRC/App/Download/DownloadManager.swift" \
    "$SRC/App/Database/ModelRegistry.swift" \
    "$SRC/Features/Guide/Model/EPGModels.swift" \
    "$SRC/Features/Guide/Model/GuideValues.swift" \
    "$SRC/Features/Guide/Matching/ChannelNameNormalizer.swift" \
    "$SRC/Features/Guide/Matching/EPGChannelMatcher.swift" \
    "$SRC/Features/Guide/Import/InflatingInputStream.swift" \
    "$SRC/Features/Guide/Import/XMLTVParser.swift" \
    "$SRC/Features/Guide/Import/EPGImporter.swift" \
    "$SRC/Features/Guide/Store/EPGQueries.swift" \
    "$SRC/Features/Guide/Store/EPGReader.swift" \
    "$HERE/main.swift" 2> "$OUT/build.log" || { cat "$OUT/build.log"; exit 1; }
CHECK="$OUT/bin/guide-check"

# Runs a command and prints its wall time and peak memory (maximum resident set size).
measure() {
    local label="$1"
    shift
    /usr/bin/time -l "$@" 2> "$OUT/time.log"
    local rss
    rss=$(awk '/maximum resident set size/ {print $1}' "$OUT/time.log")
    local real
    real=$(awk '/ real / {print $1}' "$OUT/time.log")
    printf '  %-44s %6ss  peak %6.1f MB\n' "$label" "$real" "$(echo "$rss / 1048576" | bc -l)"
}

echo "== self test"
"$CHECK" selftest

if [[ -z "${OFFLINE:-}" ]]; then
    echo "== real guides"
    curl -sfL -m 120 -o "$OUT/samples/epgshare01-IT1.xml.gz" https://epgshare01.online/epgshare01/epg_ripper_IT1.xml.gz || echo "  (IT1 download failed)"
    curl -sfL -m 120 -o "$OUT/samples/epgshare01-AL1.xml.gz" https://epgshare01.online/epgshare01/epg_ripper_AL1.xml.gz || echo "  (AL1 download failed)"
    curl -sfL -m 120 -o "$OUT/samples/plutotv-it.xml.gz" https://i.mjh.nz/PlutoTV/it.xml.gz || echo "  (Pluto TV download failed)"
    for sample in "$OUT"/samples/*.xml.gz; do
        [[ -s "$sample" ]] || continue
        measure "parse $(basename "$sample") (all channels)" "$CHECK" parse "$sample"
        measure "import $(basename "$sample")" "$CHECK" import "$sample" "$OUT/samples/$(basename "$sample" .xml.gz).sqlite"
    done

    echo "== real refresh (download, gzip, matching of decorated IPTV names, unchanged-file skip)"
    measure "refresh epgshare01 IT1" "$CHECK" refresh https://epgshare01.online/epgshare01/epg_ripper_IT1.xml.gz "$OUT/samples/refresh.sqlite" \
        "IT: Sky Sport F1 FHD" "Sky Sport MotoGP HD" "Sky Sport Uno" "IT | Rai 1 HD" "Rai 2" "Rai 3 ᴴᴰ" "Canale 5 FHD" "Italia 1" "Rete 4 HD" \
        "La7" "TV8 HD" "Nove" "Sky TG24" "DMAX" "Real Time" "Sky Cinema Uno" "Cielo" "Focus" "Rai News 24" "Sky Atlantic"
fi

echo "== synthetic guide: $CHANNELS channels x $DAYS days"
"$CHECK" generate "$OUT/synthetic/guide.xml" "$CHANNELS" "$DAYS"
gzip -k -f "$OUT/synthetic/guide.xml"
ls -lh "$OUT/synthetic"
measure "parse guide.xml (all channels)" "$CHECK" parse "$OUT/synthetic/guide.xml"
measure "parse guide.xml.gz (all channels)" "$CHECK" parse "$OUT/synthetic/guide.xml.gz"
measure "parse guide.xml.gz (200 wanted channels)" "$CHECK" parse "$OUT/synthetic/guide.xml.gz" 200
measure "import guide.xml.gz (half the channels)" "$CHECK" import "$OUT/synthetic/guide.xml.gz" "$OUT/synthetic/guide.sqlite"

echo "Artifacts in $OUT"
