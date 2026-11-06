#!/bin/sh
# Checks Fluxo's Top Shelf on the Apple TV Home Screen of a clone kept by run.sh, with Siri Remote presses
# (TopShelfTests/, an XCUITest bundle that drives the Home Screen, not the app).
#
#   Tools/Simulator/build.sh --platform tvos
#   Tools/Simulator/run.sh --device "Apple TV 4K (4th generation)" --clone fluxo-mykey-tv-1 --keep \
#       --route "seed-guide;progress:Crimson Signal;topshelf:continueWatching,favorites,onNow"
#   Tools/Simulator/topshelf-tests.sh fluxo-mykey-tv-1 ["home,focus:Fluxo,wait:5,shot:icon,up,wait:2,shot:item"]
#
# The steps (see TopShelfTests.swift) default to focusing Fluxo's icon and a screenshot. Fluxo stays running in the
# background, so selecting an item opens it in the seeded library of that run.
# Screenshots: /tmp/fluxo-shots/<clone>/topshelf (FLUXO_SHOTS overrides it). Log: /tmp/fluxo-logs/<clone>-topshelf-tests.log.
set -eu
. "$(dirname "$0")/common.sh"

[ $# -ge 1 ] || die "usage: topshelf-tests.sh <clone> [steps]"
CLONE=$1
STEPS=${2:-home,wait:2,focus:Fluxo,wait:5,shot:icon-focused}
case "$CLONE" in
    "$CLONE_PREFIX"*) ;;
    *) die "the clone name must start with $CLONE_PREFIX" ;;
esac
UDID=$(device_udid "$CLONE")
[ -n "$UDID" ] || die "no simulator named $CLONE (create it with run.sh --keep)"
[ "$(device_state "$UDID")" = Booted ] || die "$CLONE is not booted (run.sh --clone $CLONE --keep boots it)"
[ "$(device_platform "$UDID")" = tvos ] || die "$CLONE is not an Apple TV"

SHOTS=${FLUXO_SHOTS:-/tmp/fluxo-shots/$CLONE/topshelf}
LOG_DIR=${FLUXO_SIM_LOG_DIR:-/tmp/fluxo-logs}
LOG="$LOG_DIR/$CLONE-topshelf-tests.log"
mkdir -p "$SHOTS" "$LOG_DIR"

echo "Driving the Home Screen of $CLONE (log: $LOG)..." >&2
STATUS=0
TEST_RUNNER_FLUXO_SHOTS="$SHOTS" TEST_RUNNER_FLUXO_TOPSHELF_STEPS="$STEPS" xcodebuild test \
    -project "$SIM_ROOT/Tools/Simulator/TopShelfTests/TopShelfTests.xcodeproj" -scheme TopShelfTests \
    -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA-topshelf-tests" CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1 || STATUS=$?
# xcodebuild leaves a workspace folder next to the project; it is not part of the repository.
rm -rf "$SIM_ROOT/Tools/Simulator/TopShelfTests/TopShelfTests.xcodeproj/project.xcworkspace"
grep -E "error:|TopShelfTests (focus|focused):|' (passed|failed)|TEST (SUCCEEDED|FAILED)" "$LOG" >&2 || true
echo "Screenshots: $SHOTS" >&2
exit $STATUS
