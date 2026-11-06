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

source "$ROOT/Tools/swift-language.sh"
xcrun swiftc -O "${FLUXO_SWIFT_LANGUAGE[@]}" -parse-as-library -o "$OUT/check" \
    "$ROOT/Fluxo/Features/Playlist/Playlist.swift" \
    "$ROOT/Fluxo/Features/Playlist/ChannelContentKind.swift" \
    "$ROOT/Fluxo/Features/Library/ChannelBookmark.swift" \
    "$ROOT/Fluxo/Features/Library/ChannelLibrary.swift" \
    "$ROOT/Fluxo/App/Sync/SyncDeletionJournal.swift" \
    "$ROOT/Fluxo/App/Sync/CloudSyncRecords.swift" \
    "$ROOT/Fluxo/App/Sync/CloudSyncReconciler.swift" \
    "$ROOT/Fluxo/App/Extensions/UserDefaults+Fluxo.swift" \
    "$ROOT/Fluxo/Features/Library/ChannelZapper.swift" \
    "$ROOT/Fluxo/Features/Home/HomeQueries.swift" \
    "$ROOT/Fluxo/Features/Search/SearchMatcher.swift" \
    "$ROOT/Fluxo/Features/Search/ChannelSearchIndex.swift" \
    "$ROOT/Fluxo/App/Database/ModelRegistry.swift" \
    "$ROOT/Fluxo/Features/Guide/Model/EPGModels.swift" \
    "$ROOT/Fluxo/Features/Guide/Model/GuideValues.swift" \
    "$ROOT/Fluxo/Features/Series/EpisodeParser.swift" \
    "$ROOT/Fluxo/Features/Series/SeriesModels.swift" \
    "$ROOT/Fluxo/Features/Series/SeriesLookup.swift" \
    "$ROOT/Fluxo/Features/Series/SeriesLibrary.swift" \
    "$ROOT/Fluxo/App/Design/TextParts.swift" \
    "$ROOT/Tools/SeriesCheck/ToolStubs.swift" \
    "$HERE/main.swift" 2> "$OUT/build.log" || { cat "$OUT/build.log"; exit 1; }

"$OUT/check" "$OUT/store.sqlite" "$CHANNELS"
echo "Artifacts in $OUT"
