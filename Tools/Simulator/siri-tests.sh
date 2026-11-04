#!/bin/sh
# Runs the Siri, Shortcuts and Spotlight checks (SiriTests/) on a clone kept by run.sh, against the Debug app of
# build.sh: the Shortcuts app lists and runs Fluxo's shortcuts, Spotlight finds an indexed channel, and Siri (when
# the Simulator has it) answers a phrase.
#
#   Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --keep
#   Tools/Simulator/siri-tests.sh fluxo-mykey-1 [-only-testing:SiriTests/SiriTests/testSpotlightFindsIndexedChannel]
#
# Screenshots: /tmp/fluxo-shots/<clone>/siri-tests (FLUXO_SHOTS overrides it). Log: /tmp/fluxo-logs/<clone>-siri-tests.log.
set -eu
. "$(dirname "$0")/common.sh"

[ $# -ge 1 ] || die "usage: siri-tests.sh <clone> [xcodebuild test options]"
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

SHOTS=${FLUXO_SHOTS:-/tmp/fluxo-shots/$CLONE/siri-tests}
LOG_DIR=${FLUXO_SIM_LOG_DIR:-/tmp/fluxo-logs}
LOG="$LOG_DIR/$CLONE-siri-tests.log"
mkdir -p "$SHOTS" "$LOG_DIR"
# A fresh install registers the App Shortcuts, as an install from TestFlight or the App Store does.
xcrun simctl install "$UDID" "$APP_PATH"

echo "Running the Siri tests on $CLONE (log: $LOG)..." >&2
STATUS=0
TEST_RUNNER_FLUXO_SHOTS="$SHOTS" xcodebuild test -project "$SIM_ROOT/Tools/Simulator/SiriTests/SiriTests.xcodeproj" \
    -scheme SiriTests -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA-siri-tests" \
    CODE_SIGNING_ALLOWED=NO "$@" > "$LOG" 2>&1 || STATUS=$?
# xcodebuild leaves a workspace folder next to the project; it is not part of the repository.
rm -rf "$SIM_ROOT/Tools/Simulator/SiriTests/SiriTests.xcodeproj/project.xcworkspace"
grep -E "error:|' (passed|failed)|TEST (SUCCEEDED|FAILED)" "$LOG" >&2 || true
echo "Screenshots: $SHOTS" >&2
exit $STATUS
