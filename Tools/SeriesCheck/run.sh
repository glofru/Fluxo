#!/bin/bash
# Checks series grouping (see main.swift):
#   1. the episode parser on a broad list of real-world names, the series keys, and its speed;
#   2. the import of a synthetic playlist with series into an on-disk SwiftData store, and the queries of Home,
#      Search and the series page (timings);
#   3. the migration: OLD_REV's models write a store (with a watched episode in the history), this version opens
#      it and groups its series at "launch".
#
#   Tools/SeriesCheck/run.sh                  # 100k entries
#   ENTRIES=20000 Tools/SeriesCheck/run.sh
#   PARSER_ONLY=1 Tools/SeriesCheck/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ENTRIES="${ENTRIES:-100000}"
OLD_REV="${OLD_REV:-a7d64f6}"
OUT="${OUT:-$(mktemp -d /tmp/fluxo-series-check.XXXXXX)}"
source "$ROOT/Tools/swift-language.sh"
SWIFTC=(xcrun swiftc -O "${FLUXO_SWIFT_LANGUAGE[@]}" -parse-as-library)
# The models of OLD_REV predate the Swift 6 language mode.
SWIFTC_OLD=(xcrun swiftc -O -swift-version 5 -parse-as-library)
F="$ROOT/Fluxo"

if [ "${PARSER_ONLY:-0}" = 1 ]; then
    "${SWIFTC[@]}" -o "$OUT/parser" "$F/Features/Series/EpisodeParser.swift" "$F/Features/Playlist/ChannelContentKind.swift" \
        "$HERE/ParserCases.swift" "$HERE/ParserChecks.swift" "$HERE/ParserOnlyMain.swift" 2> "$OUT/build-parser.log" \
        || { cat "$OUT/build-parser.log"; exit 1; }
    "$OUT/parser"
    exit 0
fi

"${SWIFTC[@]}" -o "$OUT/check" \
    "$F/Features/Playlist/Playlist.swift" \
    "$F/Features/Playlist/ChannelContentKind.swift" \
    "$F/Features/Playlist/Import/M3UParser.swift" \
    "$F/Features/Playlist/Import/PlaylistImporter.swift" \
    "$F/App/Download/DownloadManager.swift" \
    "$F/Features/Library/ChannelBookmark.swift" \
    "$F/Features/Library/ChannelLibrary.swift" \
    "$F/App/Sync/SyncDeletionJournal.swift" \
    "$F/App/Sync/CloudSyncRecords.swift" \
    "$F/App/Sync/CloudSyncReconciler.swift" \
    "$F/App/Extensions/UserDefaults+Fluxo.swift" \
    "$F/Features/Home/HomeQueries.swift" \
    "$F/Features/Search/SearchMatcher.swift" \
    "$F/Features/Search/ChannelSearchIndex.swift" \
    "$F/Features/Series/EpisodeParser.swift" \
    "$F/Features/Series/SeriesModels.swift" \
    "$F/Features/Series/SeriesAccumulator.swift" \
    "$F/Features/Series/SeriesIndexer.swift" \
    "$F/Features/Series/SeriesLookup.swift" \
    "$F/Features/Series/SeriesLibrary.swift" \
    "$F/App/Design/TextParts.swift" \
    "$F/App/Database/ModelRegistry.swift" \
    "$F/App/Database/StoreHistory.swift" \
    "$F/Features/Guide/Model/EPGModels.swift" \
    "$F/Features/Guide/Model/GuideValues.swift" \
    "$HERE/ParserCases.swift" "$HERE/ParserChecks.swift" "$HERE/SyntheticPlaylist.swift" "$HERE/StoreCheck.swift" "$HERE/ToolStubs.swift" "$HERE/main.swift" \
    2> "$OUT/build.log" || { cat "$OUT/build.log"; exit 1; }

echo "== parser"
"$OUT/check" parser
echo "== store ($ENTRIES entries)"
"$OUT/check" store "$OUT/store.sqlite" "$OUT/playlist.m3u" "$ENTRIES"

echo "== migration from $OLD_REV"
mkdir -p "$OUT/old"
for file in Features/Playlist/Playlist.swift Features/Playlist/ChannelContentKind.swift Features/Playlist/Import/M3UParser.swift \
            Features/Playlist/Import/PlaylistImporter.swift App/Download/DownloadManager.swift Features/Library/ChannelBookmark.swift \
            App/Database/ModelRegistry.swift Features/Guide/Model/EPGModels.swift Features/Guide/Model/GuideValues.swift \
            Features/Library/ChannelLibrary.swift Features/Home/HomeQueries.swift App/Design/TextParts.swift; do
    git -C "$ROOT" show "$OLD_REV:Fluxo/$file" > "$OUT/old/$(basename "$file")"
done
"${SWIFTC_OLD[@]}" -o "$OUT/old-store" "$OUT"/old/*.swift "$HERE/ToolStubs.swift" "$HERE/OldMain.swift" 2> "$OUT/build-old.log" \
    || { cat "$OUT/build-old.log"; exit 1; }
"$OUT/check" generate "$OUT/playlist-old.m3u" "$ENTRIES"
"$OUT/old-store" "$OUT/old.sqlite" "$OUT/playlist-old.m3u"
"$OUT/check" backfill "$OUT/old.sqlite" "$OUT/playlist-old.m3u" "$ENTRIES"

echo "Artifacts in $OUT"
