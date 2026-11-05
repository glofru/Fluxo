#!/bin/sh
# Builds the Debug app for the iOS Simulator (or the tvOS Simulator) once; run.sh installs it on every clone.
#
#   Tools/Simulator/build.sh                   iPhone and iPad simulators
#   Tools/Simulator/build.sh --platform tvos   Apple TV simulators
#
# The derived data folder is /tmp/fluxo-dd/<worktree folder>-sim (FLUXO_SIM_DERIVED_DATA overrides it), so
# every worktree has its own build; both platforms build into it side by side. Prints the path of the app.
set -eu
. "$(dirname "$0")/common.sh"

PLATFORM=ios
if [ "${1:-}" = "--platform" ]; then
    PLATFORM=${2:-}
    shift 2 || true
fi
case "$PLATFORM" in
ios) DESTINATION='generic/platform=iOS Simulator' ;;
tvos) DESTINATION='generic/platform=tvOS Simulator' ;;
*) die "unknown platform \"$PLATFORM\" (ios or tvos)" ;;
esac
APP=$(app_path "$PLATFORM")

LOG_DIR=${FLUXO_SIM_LOG_DIR:-/tmp/fluxo-logs}
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(basename "$DERIVED_DATA")-harness-build-$PLATFORM.log"

echo "Building the Debug $PLATFORM simulator app (log: $LOG)..." >&2
if ! xcodebuild -project "$SIM_ROOT/Fluxo.xcodeproj" -scheme Fluxo -configuration Debug \
    -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA" \
    build CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1; then
    grep -E 'error:' "$LOG" | sort -u | head -20 >&2
    die "the build failed; see $LOG"
fi
[ -d "$APP" ] || die "the build succeeded but $APP is missing"
echo "$APP"
