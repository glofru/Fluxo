#!/bin/bash
# Benchmarks the playlist import pipeline before and after the streaming parser rewrite.
#
#   Tools/PlaylistBenchmark/run.sh            # 100k entries
#   ENTRIES=20000 Tools/PlaylistBenchmark/run.sh
#
# OLD_REV is the commit that still has PlaylistValidator/PlaylistViewModel (default: the commit before the rewrite).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OLD_REV="${OLD_REV:-ef77322}"
ENTRIES="${ENTRIES:-100000}"
OUT="${OUT:-$(mktemp -d /tmp/fluxo-playlist-bench.XXXXXX)}"
source "$ROOT/Tools/swift-language.sh"
SWIFTC=(xcrun swiftc -O "${FLUXO_SWIFT_LANGUAGE[@]}" -parse-as-library)
# The sources of OLD_REV predate the Swift 6 language mode.
SWIFTC_OLD=(xcrun swiftc -O -swift-version 5 -parse-as-library)

mkdir -p "$OUT/old"
python3 "$HERE/generate_m3u.py" "$OUT/playlist.m3u" --entries "$ENTRIES"
python3 "$HERE/generate_m3u.py" "$OUT/playlist-crlf.m3u" --entries "$ENTRIES" --crlf
ls -lh "$OUT"/*.m3u

for file in Fluxo/Features/Playlist/Playlist.swift Fluxo/Features/Playlist/PlaylistValidator.swift \
            Fluxo/Features/Playlist/PlaylistViewModel.swift Fluxo/App/Download/DownloadManager.swift; do
    git -C "$ROOT" show "$OLD_REV:$file" > "$OUT/old/$(basename "$file")"
done

"${SWIFTC_OLD[@]}" -o "$OUT/bench-old" "$OUT"/old/*.swift "$HERE/BenchSupport.swift" "$HERE/OldMain.swift" 2> "$OUT/build-old.log" \
    || { cat "$OUT/build-old.log"; exit 1; }
"${SWIFTC[@]}" -o "$OUT/bench-new" \
    "$ROOT/Fluxo/Features/Playlist/Playlist.swift" \
    "$ROOT/Fluxo/Features/Playlist/ChannelContentKind.swift" \
    "$ROOT/Fluxo/Features/Library/ChannelBookmark.swift" \
    "$ROOT/Fluxo/Features/Playlist/Import/M3UParser.swift" \
    "$ROOT/Fluxo/Features/Playlist/Import/PlaylistImporter.swift" \
    "$ROOT/Fluxo/App/Download/DownloadManager.swift" \
    "$ROOT/Fluxo/Features/Library/ChannelLibrary.swift" \
    "$ROOT/Fluxo/App/Sync/SyncDeletionJournal.swift" \
    "$ROOT/Fluxo/App/Sync/CloudSyncRecords.swift" \
    "$ROOT/Fluxo/App/Sync/CloudSyncReconciler.swift" \
    "$ROOT/Fluxo/App/Extensions/UserDefaults+Fluxo.swift" \
    "$ROOT/Fluxo/Features/Home/HomeQueries.swift" \
    "$ROOT/Fluxo/Features/Search/SearchMatcher.swift" \
    "$ROOT/Fluxo/Features/Search/ChannelSearchIndex.swift" \
    "$ROOT/Fluxo/Features/Series/EpisodeParser.swift" \
    "$ROOT/Fluxo/Features/Series/SeriesModels.swift" \
    "$ROOT/Fluxo/Features/Series/SeriesAccumulator.swift" \
    "$ROOT/Fluxo/Features/Series/SeriesIndexer.swift" \
    "$ROOT/Fluxo/Features/Series/SeriesLookup.swift" \
    "$ROOT/Fluxo/Features/Series/SeriesLibrary.swift" \
    "$ROOT/Fluxo/App/Design/TextParts.swift" \
    "$HERE/BenchSupport.swift" "$HERE/NewMain.swift" 2> "$OUT/build-new.log" \
    || { cat "$OUT/build-new.log"; exit 1; }

echo "== parser self test"
"$OUT/bench-new" selftest -
echo "== parse ($ENTRIES entries, LF)"
"$OUT/bench-old" parse "$OUT/playlist.m3u"
"$OUT/bench-new" parse "$OUT/playlist.m3u"
echo "== parse ($ENTRIES entries, CRLF)"
"$OUT/bench-old" parse "$OUT/playlist-crlf.m3u"
"$OUT/bench-new" parse "$OUT/playlist-crlf.m3u"
echo "== import into an on-disk SwiftData store"
"$OUT/bench-old" import "$OUT/playlist.m3u"
"$OUT/bench-new" import "$OUT/playlist.m3u"

echo "Artifacts in $OUT"
