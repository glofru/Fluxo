#!/bin/sh
# Runs the Siri Remote UI tests (RemoteTests/, an XCUITest bundle that presses the remote with XCUIRemote and reads
# the focused element) on an Apple TV clone kept by run.sh, against the Debug app of build.sh --platform tvos.
#
#   Tools/Simulator/build.sh --platform tvos
#   Tools/Simulator/run.sh --device "Apple TV 4K (4th generation)" --clone fluxo-mykey-tv-1 --keep
#   Tools/Simulator/remote-tests.sh fluxo-mykey-tv-1 [-only-testing:RemoteTests/SeriesSeasonFocusTests/testTwelveSeasons]
#
# FLUXO_APPEARANCE=light runs them in light mode (dark by default).
# Screenshots: /tmp/fluxo-shots/<clone>/remote-tests (FLUXO_SHOTS overrides it). Log: /tmp/fluxo-logs/<clone>-remote-tests.log.
set -eu
. "$(dirname "$0")/common.sh"

[ $# -ge 1 ] || die "usage: remote-tests.sh <clone> [xcodebuild test options]"
CLONE=$1
shift
case "$CLONE" in
    "$CLONE_PREFIX"*) ;;
    *) die "the clone name must start with $CLONE_PREFIX" ;;
esac
UDID=$(device_udid "$CLONE")
[ -n "$UDID" ] || die "no simulator named $CLONE (create it with run.sh --keep)"
[ "$(device_state "$UDID")" = Booted ] || die "$CLONE is not booted (run.sh --clone $CLONE --keep boots it)"
[ "$(device_platform "$UDID")" = tvos ] || die "$CLONE is not an Apple TV"
APP=$(app_path tvos)
[ -d "$APP" ] || die "no app at $APP (run build.sh --platform tvos)"

SHOTS=${FLUXO_SHOTS:-/tmp/fluxo-shots/$CLONE/remote-tests}
LOG_DIR=${FLUXO_SIM_LOG_DIR:-/tmp/fluxo-logs}
LOG="$LOG_DIR/$CLONE-remote-tests.log"
mkdir -p "$SHOTS" "$LOG_DIR"

xcrun simctl install "$UDID" "$APP"

echo "Running the Siri Remote tests on $CLONE (log: $LOG)..." >&2
STATUS=0
TEST_RUNNER_FLUXO_SHOTS="$SHOTS" TEST_RUNNER_FLUXO_APPEARANCE="${FLUXO_APPEARANCE:-dark}" xcodebuild test \
    -project "$SIM_ROOT/Tools/Simulator/RemoteTests/RemoteTests.xcodeproj" -scheme RemoteTests \
    -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA-remote-tests" CODE_SIGNING_ALLOWED=NO "$@" > "$LOG" 2>&1 || STATUS=$?
# xcodebuild leaves a workspace folder next to the project; it is not part of the repository.
rm -rf "$SIM_ROOT/Tools/Simulator/RemoteTests/RemoteTests.xcodeproj/project.xcworkspace"
grep -E "error:|RemoteTests focused:|' (passed|failed)|TEST (SUCCEEDED|FAILED)" "$LOG" >&2 || true
echo "Screenshots: $SHOTS" >&2
exit $STATUS
