#!/bin/bash
# Runs every Home / Search / library query against an on-disk SwiftData store, with the real model and
# query sources, to check that the predicates translate to SQL and return the expected rows.
#
#   Tools/HomeQueriesCheck/run.sh                 # 50k channels
#   CHANNELS=200000 Tools/HomeQueriesCheck/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CHANNELS="${CHANNELS:-50000}"
OUT="${OUT:-$(mktemp -d /tmp/fluxo-home-queries.XXXXXX)}"

xcrun swiftc -O -swift-version 5 -parse-as-library -o "$OUT/check" \
    "$ROOT/Fluxo/Features/Playlist/Playlist.swift" \
    "$ROOT/Fluxo/Features/Playlist/ChannelContentKind.swift" \
    "$ROOT/Fluxo/Features/Library/ChannelBookmark.swift" \
    "$ROOT/Fluxo/Features/Library/ChannelLibrary.swift" \
    "$ROOT/Fluxo/Features/Library/ChannelZapper.swift" \
    "$ROOT/Fluxo/Features/Home/HomeQueries.swift" \
    "$ROOT/Fluxo/Features/Search/SearchMatcher.swift" \
    "$ROOT/Fluxo/Features/Search/ChannelSearchIndex.swift" \
    "$ROOT/Fluxo/App/Database/ModelRegistry.swift" \
    "$ROOT/Fluxo/Features/Guide/Model/EPGModels.swift" \
    "$ROOT/Fluxo/Features/Guide/Model/GuideValues.swift" \
    "$HERE/main.swift" 2> "$OUT/build.log" || { cat "$OUT/build.log"; exit 1; }

"$OUT/check" "$OUT/store.sqlite" "$CHANNELS"
echo "Artifacts in $OUT"
