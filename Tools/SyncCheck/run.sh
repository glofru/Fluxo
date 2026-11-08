#!/bin/bash
# Checks iCloud sync (the reconciler, the records, conflict resolution, deletions, first-run import) with the app's
# own sources, on simulated devices that share a simulated cloud (Fluxo/App/Sync/SimulatedCloud.swift). Nothing goes
# on the network and no iCloud account is needed.
#
#   Tools/SyncCheck/run.sh
#
# Every scenario prints PASS or FAIL; the script fails when one does.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/Fluxo/App/Sync"
OUT="${OUT:-$(mktemp -d /tmp/fluxo-sync-check.XXXXXX)}"

mkdir -p "$OUT/bin"
source "$ROOT/Tools/swift-language.sh"
xcrun swiftc -O "${FLUXO_SWIFT_LANGUAGE[@]}" -D DEBUG -o "$OUT/bin/sync-check" \
    "$SRC/CloudSyncRecords.swift" \
    "$SRC/CloudSyncReconciler.swift" \
    "$SRC/SimulatedCloud.swift" \
    "$SRC/SerialTaskQueue.swift" \
    "$SRC/SyncDeletionJournal.swift" \
    "$HERE/FakeLibrary.swift" \
    "$HERE/ConvergenceScenarios.swift" \
    "$HERE/DataSafetyScenarios.swift" \
    "$HERE/HistoryRemovalScenarios.swift" \
    "$HERE/main.swift" 2> "$OUT/build.log" || { cat "$OUT/build.log"; exit 1; }
"$OUT/bin/sync-check"
