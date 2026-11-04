#!/bin/sh
# Runs the Xcode accessibility audit (AccessibilityAudit/) of every main screen on a clone kept by run.sh, against
# the Debug app of build.sh, in three variants of the simulator: the default settings, the largest accessibility
# text size (AX5, which also audits Dynamic Type and clipped text), and dark mode with Increase Contrast.
#
#   Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 --keep
#   Tools/Simulator/accessibility-audit.sh fluxo-mykey-1 [default|ax5|contrast ...]
#
# With FLUXO_TEST_STREAM_URL (e.g. http://127.0.0.1:18080, test-stream.sh running) it also checks the player's
# Audio and Subtitles menu; extra xcodebuild options go in FLUXO_AUDIT_XCODEBUILD_ARGS (e.g.
# "-only-testing:AccessibilityAudit/AccessibilityAuditTests/testMediaSelectionMenu").
#
# Reports and screenshots: /tmp/fluxo-shots/<clone>/accessibility-audit/<variant>/ (FLUXO_AUDIT_OUT overrides it),
# one report.txt per variant. Log: /tmp/fluxo-logs/<clone>-accessibility-audit-<variant>.log. The clone's text size,
# appearance and contrast are set back to the defaults at the end.
set -eu
. "$(dirname "$0")/common.sh"

[ $# -ge 1 ] || die "usage: accessibility-audit.sh <clone> [default|ax5|contrast ...]"
CLONE=$1
shift
case "$CLONE" in
    "$CLONE_PREFIX"*) ;;
    *) die "the clone name must start with $CLONE_PREFIX" ;;
esac
VARIANTS=${*:-default ax5 contrast}
UDID=$(device_udid "$CLONE")
[ -n "$UDID" ] || die "no simulator named $CLONE (create it with run.sh --keep)"
[ "$(device_state "$UDID")" = Booted ] || die "$CLONE is not booted (run.sh --clone $CLONE --keep boots it)"
[ -d "$APP_PATH" ] || die "no app at $APP_PATH (run build.sh)"

OUT=${FLUXO_AUDIT_OUT:-/tmp/fluxo-shots/$CLONE/accessibility-audit}
LOG_DIR=${FLUXO_SIM_LOG_DIR:-/tmp/fluxo-logs}
mkdir -p "$OUT" "$LOG_DIR"

xcrun simctl install "$UDID" "$APP_PATH"
STATUS_DIR=$(status_directory "$UDID") || die "Fluxo is not installed on $CLONE"

reset_ui() {
    xcrun simctl ui "$UDID" content_size large > /dev/null 2>&1 || true
    xcrun simctl ui "$UDID" appearance light > /dev/null 2>&1 || true
    xcrun simctl ui "$UDID" increase_contrast disabled > /dev/null 2>&1 || true
}
trap reset_ui EXIT INT TERM

STATUS=0
for VARIANT in $VARIANTS; do
    reset_ui
    APPEARANCE=light
    case "$VARIANT" in
        default) ;;
        ax5) xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large ;;
        contrast)
            APPEARANCE=dark
            xcrun simctl ui "$UDID" appearance dark
            xcrun simctl ui "$UDID" increase_contrast enabled
            ;;
        *) die "unknown variant $VARIANT (default, ax5 or contrast)" ;;
    esac
    LOG="$LOG_DIR/$CLONE-accessibility-audit-$VARIANT.log"
    echo "Auditing $CLONE ($VARIANT; log: $LOG)..." >&2
    TEST_RUNNER_FLUXO_AUDIT_OUT="$OUT" TEST_RUNNER_FLUXO_AUDIT_VARIANT="$VARIANT" \
    TEST_RUNNER_FLUXO_AUDIT_APPEARANCE="$APPEARANCE" TEST_RUNNER_FLUXO_STATUS_DIR="$STATUS_DIR" \
    TEST_RUNNER_FLUXO_TEST_STREAM_URL="${FLUXO_TEST_STREAM_URL:-}" \
        xcodebuild test -project "$SIM_ROOT/Tools/Simulator/AccessibilityAudit/AccessibilityAudit.xcodeproj" \
        -scheme AccessibilityAudit -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA-accessibility-audit" \
        CODE_SIGNING_ALLOWED=NO ${FLUXO_AUDIT_XCODEBUILD_ARGS:-} > "$LOG" 2>&1 || STATUS=1
    # xcodebuild leaves a workspace folder next to the project; it is not part of the repository.
    rm -rf "$SIM_ROOT/Tools/Simulator/AccessibilityAudit/AccessibilityAudit.xcodeproj/project.xcworkspace"
    grep -E "error:|' (passed|failed)|TEST (SUCCEEDED|FAILED)" "$LOG" >&2 || true
    [ -f "$OUT/$VARIANT/report.txt" ] && head -1 "$OUT/$VARIANT/report.txt" >&2
done
echo "Reports: $OUT/<variant>/report.txt" >&2
exit $STATUS
