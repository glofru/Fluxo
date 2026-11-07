#!/bin/bash
# Checks the featured billboard and the adult-content filter (see main.swift): the classifier on a broad list of
# names, the title keys, the picker on synthetic categories, the rotation, and the loader on an on-disk SwiftData
# store, with the app's sources.
#
#   Tools/FeaturedCheck/run.sh                  # 20k filler entries in the store
#   FILLER=100000 Tools/FeaturedCheck/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FILLER="${FILLER:-20000}"
OUT="${OUT:-$(mktemp -d /tmp/fluxo-featured-check.XXXXXX)}"
F="$ROOT/Fluxo"

source "$ROOT/Tools/swift-language.sh"
xcrun swiftc -O "${FLUXO_SWIFT_LANGUAGE[@]}" -parse-as-library -o "$OUT/check" \
    "$F/Features/Playlist/Playlist.swift" \
    "$F/Features/Playlist/ChannelContentKind.swift" \
    "$F/Features/Library/ChannelBookmark.swift" \
    "$F/Features/Library/ChannelLibrary.swift" \
    "$F/Features/Library/MatureContent.swift" \
    "$F/App/Sync/SyncDeletionJournal.swift" \
    "$F/App/Sync/CloudSyncRecords.swift" \
    "$F/App/Sync/CloudSyncReconciler.swift" \
    "$F/App/Extensions/UserDefaults+Fluxo.swift" \
    "$F/Features/Library/ChannelZapper.swift" \
    "$F/Features/Home/HomeQueries.swift" \
    "$F/Features/Home/LibraryScope.swift" \
    "$F/Features/Home/FeaturedPicker.swift" \
    "$F/Features/Home/FeaturedLoader.swift" \
    "$F/Features/Home/FeaturedRotation.swift" \
    "$F/Features/Intelligence/LibraryLookup.swift" \
    "$F/Features/Intelligence/Recommendations/RecommendationTypes.swift" \
    "$F/Features/Search/SearchMatcher.swift" \
    "$F/Features/Search/ChannelSearchIndex.swift" \
    "$F/App/Database/ModelRegistry.swift" \
    "$F/Features/Guide/Model/EPGModels.swift" \
    "$F/Features/Guide/Model/GuideValues.swift" \
    "$F/Features/Guide/Matching/ChannelNameNormalizer.swift" \
    "$F/Features/Series/EpisodeParser.swift" \
    "$F/Features/Series/SeriesModels.swift" \
    "$F/Features/Series/SeriesLookup.swift" \
    "$F/Features/Series/SeriesLibrary.swift" \
    "$F/App/Design/TextParts.swift" \
    "$ROOT/Tools/SeriesCheck/ToolStubs.swift" \
    "$HERE/Stubs.swift" \
    "$ROOT/FluxoTests/Fixtures/MatureContentCases.swift" \
    "$HERE/main.swift" 2> "$OUT/build.log" || { cat "$OUT/build.log"; exit 1; }

"$OUT/check" "$OUT/store.sqlite" "$FILLER"
echo "Artifacts in $OUT"
