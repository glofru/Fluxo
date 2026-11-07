#!/bin/bash
# Checks the library store (see docs/library-store.md):
#   1. OLD_REV's sources (the last version before the versioned schema, by default) write a library as that version
#      did: a playlist and a guide through their importers, favorites, history with resume positions, a watched
#      series, a guide match chosen by hand, a reminder, a guide the user added;
#   2. this version opens it: the split into the library and the cache, the migration to 2.0.0, every attribute of every
#      user row unchanged, the cache kept, the files purged and compacted; then a second launch, a lost cache, a damaged
#      cache, a damaged library (reported, untouched, exported, Start Over keeps a backup), a library of a newer
#      version (reported, untouched), a split interrupted by a kill, a new installation;
#   3. the downloads list: lenient reading of the records of earlier and later builds, the records it cannot read
#      written back by every save, the copy kept of a file that could not be read, the folders kept for records it
#      could not read (also after a save, a relaunch, or a list written without them, and while the folder cannot be
#      listed), the orphan sweep, the failure reasons.
#
#   Tools/LibraryCheck/run.sh                              # 2,000 channels, a guide of 400 channels x 3 days
#   LIVE=100000 GUIDE_CHANNELS=1500 DAYS=7 Tools/LibraryCheck/run.sh   # a large library: how long the split takes
#   OLD_REV=<commit> Tools/LibraryCheck/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OLD_REV="${OLD_REV:-12dd923}"
LIVE="${LIVE:-2000}"
GUIDE_CHANNELS="${GUIDE_CHANNELS:-400}"
DAYS="${DAYS:-3}"
OUT="${OUT:-$(mktemp -d /tmp/fluxo-library-check.XXXXXX)}"
source "$ROOT/Tools/swift-language.sh"
SWIFTC=(xcrun swiftc -O "${FLUXO_SWIFT_LANGUAGE[@]}" -parse-as-library)

# The model, import and guide sources both versions are compiled with (relative to Fluxo/).
COMMON=(
    Features/Playlist/Playlist.swift Features/Playlist/ChannelContentKind.swift Features/Playlist/Import/M3UParser.swift
    Features/Playlist/Import/PlaylistImporter.swift App/Download/DownloadManager.swift
    Features/Library/ChannelBookmark.swift Features/Library/ChannelLibrary.swift
    App/Sync/SyncDeletionJournal.swift App/Sync/CloudSyncRecords.swift App/Sync/CloudSyncReconciler.swift
    App/Extensions/UserDefaults+Fluxo.swift Features/Home/HomeQueries.swift
    Features/Search/SearchMatcher.swift Features/Search/ChannelSearchIndex.swift
    Features/Series/EpisodeParser.swift Features/Series/SeriesModels.swift Features/Series/SeriesAccumulator.swift
    Features/Series/SeriesIndexer.swift Features/Series/SeriesLookup.swift Features/Series/SeriesLibrary.swift
    App/Design/TextParts.swift App/Database/ModelRegistry.swift
    Features/Guide/Model/EPGModels.swift Features/Guide/Model/GuideValues.swift
    Features/Guide/Matching/ChannelNameNormalizer.swift Features/Guide/Matching/EPGChannelMatcher.swift
    Features/Guide/Import/InflatingInputStream.swift Features/Guide/Import/XMLTVParser.swift
    Features/Guide/Import/GuideRefreshFailure.swift Features/Guide/Import/EPGImporter.swift Features/Guide/Store/EPGQueries.swift
)
# Only this version's.
NEW=(
    App/Database/StoreHistory.swift App/Database/FluxoSchema.swift App/Database/LibraryStore.swift App/Platform/PlatformFeatures.swift
    Features/Downloads/DownloadModels.swift Features/Downloads/DownloadFailure.swift Features/Downloads/DownloadManifest.swift
)

# GuideFormat (used by GuideValues) lives in a SwiftUI views file; compile just the enum, taken from the source.
guide_format() {
    { echo "import Foundation"; awk '/^enum GuideFormat/,/^}/'; } > "$2"
}

mkdir -p "$OUT/old-src/Fluxo" "$OUT/bin"
echo "== build: $OLD_REV (writes the library) and this version (opens it)"
old_files=()
for file in "${COMMON[@]}"; do
    mkdir -p "$OUT/old-src/Fluxo/$(dirname "$file")"
    git -C "$ROOT" show "$OLD_REV:Fluxo/$file" > "$OUT/old-src/Fluxo/$file"
    old_files+=("$OUT/old-src/Fluxo/$file")
done
git -C "$ROOT" show "$OLD_REV:Fluxo/Features/Guide/Views/NowNextViews.swift" | guide_format - "$OUT/old-src/GuideFormat.swift"
"${SWIFTC[@]}" -o "$OUT/bin/old" "${old_files[@]}" "$OUT/old-src/GuideFormat.swift" "$HERE/Fixture.swift" "$HERE/OldMain.swift" \
    2> "$OUT/build-old.log" || { cat "$OUT/build-old.log"; exit 1; }

new_files=()
for file in "${COMMON[@]}" "${NEW[@]}"; do
    new_files+=("$ROOT/Fluxo/$file")
done
guide_format - "$OUT/GuideFormat.swift" < "$ROOT/Fluxo/Features/Guide/Views/NowNextViews.swift"
"${SWIFTC[@]}" -o "$OUT/bin/check" "${new_files[@]}" "$OUT/GuideFormat.swift" "$HERE/Fixture.swift" "$HERE/ToolStubs.swift" "$HERE/main.swift" \
    2> "$OUT/build.log" || { cat "$OUT/build.log"; exit 1; }

echo "== the library of $OLD_REV ($LIVE live channels, a guide of $GUIDE_CHANNELS channels x $DAYS days)"
"$OUT/bin/old" "$OUT/legacy" "$LIVE" "$GUIDE_CHANNELS" "$DAYS" 2> "$OUT/old.log" || { cat "$OUT/old.log"; exit 1; }
ls -l "$OUT/legacy" | grep store

status=0
"$OUT/bin/check" migrate "$OUT/legacy" "$OUT/work" 2> "$OUT/check.log" || status=1
"$OUT/bin/check" relaunch "$OUT/work" 2>> "$OUT/check.log" || status=1
"$OUT/bin/check" downloads 2>> "$OUT/check.log" || status=1
echo "Artifacts in $OUT"
exit $status
