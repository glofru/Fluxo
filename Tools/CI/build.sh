#!/bin/bash
# Builds one platform gate of the Fluxo scheme, unsigned, the way CI does (.github/workflows/ci.yml) and the way to
# check a change by hand. One xcodebuild at a time: the gates are meant to run one after the other.
#
#   Tools/CI/build.sh <gate> [derived data folder]
#
# Gates:
#   ios      iOS device, Release           (generic/platform=iOS)
#   iossim   iOS Simulator, Debug          (generic/platform=iOS Simulator)
#   mac      macOS, Release                (platform=macOS)
#   tvos     Apple TV device, Release      (generic/platform=tvOS)
#   tvsim    tvOS Simulator, Debug         (generic/platform=tvOS Simulator)
#
# The log goes to $LOG_DIR/<gate>.log (default /tmp/fluxo-logs); the script prints its errors and warnings and fails
# on any of either: the build has no warnings, and must keep none.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
gate="${1:?usage: Tools/CI/build.sh <ios|iossim|mac|tvos|tvsim> [derived data folder]}"
derived="${2:-/tmp/fluxo-dd/ci-$gate}"
log_dir="${LOG_DIR:-/tmp/fluxo-logs}"
mkdir -p "$log_dir"
log="$log_dir/$gate.log"

case "$gate" in
    ios) configuration=Release; destination='generic/platform=iOS' ;;
    iossim) configuration=Debug; destination='generic/platform=iOS Simulator' ;;
    mac) configuration=Release; destination='platform=macOS' ;;
    tvos) configuration=Release; destination='generic/platform=tvOS' ;;
    tvsim) configuration=Debug; destination='generic/platform=tvOS Simulator' ;;
    *) echo "error: unknown gate $gate" >&2; exit 2 ;;
esac

# Messages of Xcode's tools that are not diagnostics of the code: the App Intents metadata step finds nothing to
# extract in the Top Shelf extension, which has no intents.
ignored='appintentsmetadataprocessor.*warning: Metadata extraction skipped, no AppIntents.framework dependency found'

echo "== $gate: $configuration, $destination ($(xcodebuild -version | tr '\n' ' '))"
status=0
xcodebuild -project "$ROOT/Fluxo.xcodeproj" -scheme Fluxo -configuration "$configuration" -destination "$destination" \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1 || status=$?
grep -E 'error:|warning:' "$log" | grep -vE "$ignored" | sort -u || true
grep -E '\*\* BUILD (SUCCEEDED|FAILED) \*\*' "$log" || true
if [ "$status" -ne 0 ]; then
    tail -n 30 "$log"
    exit "$status"
fi
if grep -E 'error:|warning:' "$log" | grep -qvE "$ignored"; then
    echo "error: the $gate build has warnings (see $log)" >&2
    exit 1
fi
