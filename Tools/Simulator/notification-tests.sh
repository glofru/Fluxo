#!/bin/sh
# Opens Fluxo's reminder notifications the way a viewer does (NotificationTests/, an XCUITest bundle) on a clone kept
# by run.sh, against the Debug app of build.sh: a reminder set through the harness fires a few seconds later, and its
# banner is tapped with Fluxo in the foreground, in the background and terminated (a cold launch from the
# notification), and once for a reminder deleted meanwhile. Fails as well when Fluxo left a crash report.
#
#   Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --keep
#   Tools/Simulator/notification-tests.sh fluxo-mykey-1 [-only-testing:NotificationTests/NotificationTests/testReminderOpenedAfterTermination]
#
# Screenshots and crash reports: /tmp/fluxo-shots/<clone>/notification-tests (FLUXO_SHOTS overrides it).
# Log: /tmp/fluxo-logs/<clone>-notification-tests.log.
set -eu
. "$(dirname "$0")/common.sh"

[ $# -ge 1 ] || die "usage: notification-tests.sh <clone> [xcodebuild test options]"
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

SHOTS=${FLUXO_SHOTS:-/tmp/fluxo-shots/$CLONE/notification-tests}
LOG_DIR=${FLUXO_SIM_LOG_DIR:-/tmp/fluxo-logs}
LOG="$LOG_DIR/$CLONE-notification-tests.log"
mkdir -p "$SHOTS" "$LOG_DIR"
xcrun simctl install "$UDID" "$APP_PATH"

# Crash reports of simulator apps are written on the Mac; this marks the start of the run.
MARKER="$SHOTS/.started"
touch "$MARKER"

echo "Running the notification tests on $CLONE (log: $LOG)..." >&2
STATUS=0
TEST_RUNNER_FLUXO_SHOTS="$SHOTS" xcodebuild test -project "$SIM_ROOT/Tools/Simulator/NotificationTests/NotificationTests.xcodeproj" \
    -scheme NotificationTests -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA-notification-tests" \
    CODE_SIGNING_ALLOWED=NO "$@" > "$LOG" 2>&1 || STATUS=$?
# xcodebuild leaves a workspace folder next to the project; it is not part of the repository.
rm -rf "$SIM_ROOT/Tools/Simulator/NotificationTests/NotificationTests.xcodeproj/project.xcworkspace"
grep -E "error:|' (passed|failed)|TEST (SUCCEEDED|FAILED)" "$LOG" >&2 || true

CRASHES=$(find "$HOME/Library/Logs/DiagnosticReports" -name 'Fluxo*.ips' -newer "$MARKER" 2>/dev/null || true)
if [ -n "$CRASHES" ]; then
    echo "Fluxo crashed during the run:" >&2
    for report in $CRASHES; do
        cp "$report" "$SHOTS/"
        echo "  $SHOTS/$(basename "$report")" >&2
    done
    STATUS=1
fi
rm -f "$MARKER"
echo "Screenshots: $SHOTS" >&2
exit $STATUS
