#!/bin/sh
# Runs the gesture UI tests (GestureTests/) with real touches on a clone kept by run.sh, against the Debug app
# of build.sh. The test streams of test-stream.sh must be running.
#
#   Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --keep
#   Tools/Simulator/test-stream.sh start
#   Tools/Simulator/gesture-tests.sh fluxo-mykey-1 [-only-testing:GestureTests/GestureTests/testStopButtonEndsPlayback]
#
# Screenshots: /tmp/fluxo-shots/<clone>/gesture-tests (FLUXO_SHOTS overrides it). Log: /tmp/fluxo-logs/<clone>-gesture-tests.log.
set -eu
. "$(dirname "$0")/common.sh"

[ $# -ge 1 ] || die "usage: gesture-tests.sh <clone> [xcodebuild test options]"
CLONE=$1
shift
case "$CLONE" in
    "$CLONE_PREFIX"*) ;;
    *) die "the clone name must start with $CLONE_PREFIX" ;;
esac
UDID=$(device_udid "$CLONE")
[ -n "$UDID" ] || die "no simulator named $CLONE (create it with run.sh --keep)"
[ "$(device_state "$UDID")" = Booted ] || die "$CLONE is not booted (run.sh --clone $CLONE --keep boots it)"
[ -d "$APP_PATH" ] || die "no app at $APP_PATH (run build.sh)"

SHOTS=${FLUXO_SHOTS:-/tmp/fluxo-shots/$CLONE/gesture-tests}
LOG_DIR=${FLUXO_SIM_LOG_DIR:-/tmp/fluxo-logs}
LOG="$LOG_DIR/$CLONE-gesture-tests.log"
mkdir -p "$SHOTS" "$LOG_DIR"

xcrun simctl install "$UDID" "$APP_PATH"

# Screenshots in the middle of a gesture: XCUITest blocks while a finger is down, so a test that wants one
# writes "$SHOTS/.capture-<name>" just before the gesture (see `GestureTests.captureDuringGesture`), and this
# loop takes "<name>.png" with simctl 1.2 s later, while the finger holds still.
rm -f "$SHOTS"/.capture-*
(
    while :; do
        for marker in "$SHOTS"/.capture-*; do
            [ -e "$marker" ] || continue
            name=${marker##*/.capture-}
            rm -f "$marker"
            sleep 1.2
            xcrun simctl io "$UDID" screenshot "$SHOTS/$name.png" > /dev/null 2>&1 || true
        done
        sleep 0.1
    done
) &
CAPTURE_PID=$!
trap 'kill "$CAPTURE_PID" 2> /dev/null || true' EXIT INT TERM

echo "Running the gesture tests on $CLONE (log: $LOG)..." >&2
STATUS=0
TEST_RUNNER_FLUXO_SHOTS="$SHOTS" xcodebuild test -project "$SIM_ROOT/Tools/Simulator/GestureTests/GestureTests.xcodeproj" \
    -scheme GestureTests -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA-gesture-tests" \
    CODE_SIGNING_ALLOWED=NO "$@" > "$LOG" 2>&1 || STATUS=$?
# xcodebuild leaves a workspace folder next to the project; it is not part of the repository.
rm -rf "$SIM_ROOT/Tools/Simulator/GestureTests/GestureTests.xcodeproj/project.xcworkspace"
grep -E "error:|' (passed|failed)|TEST (SUCCEEDED|FAILED)" "$LOG" >&2 || true
echo "Screenshots: $SHOTS" >&2
exit $STATUS
