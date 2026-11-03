#!/bin/sh
# Builds the Debug app for the iOS Simulator once; run.sh installs it on every clone.
#
#   Tools/Simulator/build.sh
#
# The derived data folder is /tmp/fluxo-dd/<worktree folder>-sim (FLUXO_SIM_DERIVED_DATA overrides it), so
# every worktree has its own build. Prints the path of the app.
set -eu
. "$(dirname "$0")/common.sh"

LOG_DIR=${FLUXO_SIM_LOG_DIR:-/tmp/fluxo-logs}
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(basename "$DERIVED_DATA")-harness-build.log"

echo "Building the Debug simulator app (log: $LOG)..." >&2
if ! xcodebuild -project "$SIM_ROOT/Fluxo.xcodeproj" -scheme Fluxo -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED_DATA" \
    build CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1; then
    grep -E 'error:' "$LOG" | sort -u | head -20 >&2
    die "the build failed; see $LOG"
fi
[ -d "$APP_PATH" ] || die "the build succeeded but $APP_PATH is missing"
echo "$APP_PATH"
