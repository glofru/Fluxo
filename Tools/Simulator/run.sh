#!/bin/sh
# Clones a simulator, boots it, installs the Debug app, launches it with the debug harness and screenshots
# every display. See README.md for examples. Apple TV simulators work the same way (the tvOS app comes from
# build.sh --platform tvos; the platform follows the simulator's runtime).
#
#   Tools/Simulator/run.sh --device "iPhone 17e" --clone fluxo-mykey-1 [options] [-- extra app arguments]
#   Tools/Simulator/run.sh --device "Apple TV 4K (4th generation)" --clone fluxo-mykey-tv-1 [options]
#
# Options:
#   --device NAME        simulator to clone (an existing one, e.g. "iPhone 17e"); not needed to reuse --clone
#   --clone NAME         name of the clone, must start with "fluxo-" (default fluxo-sim-<device>); reused if it exists
#   --seed sample|large|none   library to seed (default sample)
#   --store memory|temp|scratch  isolated store (default memory)
#   --route "a;b:arg"    -FluxoDebugRoute steps (see DebugRoutes.swift)
#   --step-shots         screenshot after every route step, not only at the end
#   --appearance light|dark      system appearance of the clone (simctl ui)
#   --content-size SIZE  Dynamic Type of the clone (simctl ui content_size, e.g. accessibility-extra-large)
#   --language CODE      app language and locale, e.g. it, de, ja, ar (passes -AppleLanguages / -AppleLocale)
#   --out DIR            screenshot folder (default /tmp/fluxo-shots/<clone>); several screenshots are also
#                        combined into <prefix>-contact.png
#   --name PREFIX        screenshot file prefix (default "shot")
#   --timeout SECONDS    longest wait for the harness (default 120)
#   --settle SECONDS     extra wait before the final screenshots (default 0.5)
#   --no-install         do not reinstall the app (keeps its data container)
#   --keep               leave the clone booted (reuse it with --clone, shot.sh, cleanup.sh); default: delete it
#
# Exit status: 0 when the harness reported "ready", 2 when it timed out (screenshots are still taken).
set -eu
. "$(dirname "$0")/common.sh"

DEVICE=""
CLONE=""
SEED=sample
STORE=memory
ROUTE=""
STEP_SHOTS=0
APPEARANCE=""
CONTENT_SIZE=""
LANGUAGE=""
OUT=""
NAME=shot
TIMEOUT=120
SETTLE=0.5
INSTALL=1
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
    --device) DEVICE=$2; shift 2 ;;
    --clone) CLONE=$2; shift 2 ;;
    --seed) SEED=$2; shift 2 ;;
    --store) STORE=$2; shift 2 ;;
    --route) ROUTE=$2; shift 2 ;;
    --step-shots) STEP_SHOTS=1; shift ;;
    --appearance) APPEARANCE=$2; shift 2 ;;
    --content-size) CONTENT_SIZE=$2; shift 2 ;;
    --language) LANGUAGE=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --settle) SETTLE=$2; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    --keep) KEEP=1; shift ;;
    --) shift; break ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
    esac
done

if [ -z "$CLONE" ]; then
    [ -n "$DEVICE" ] || die "pass --device or --clone"
    CLONE="${CLONE_PREFIX}sim-$(printf '%s' "$DEVICE" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/-$//')"
fi
case "$CLONE" in
"$CLONE_PREFIX"*) ;;
*) die "the clone name must start with $CLONE_PREFIX" ;;
esac
OUT=${OUT:-/tmp/fluxo-shots/$CLONE}
mkdir -p "$OUT"

# 1. The clone.
UDID=$(device_udid "$CLONE")
if [ -z "$UDID" ]; then
    [ -n "$DEVICE" ] || die "no simulator named $CLONE; pass --device to create it"
    SOURCE=$(device_udid "$DEVICE")
    [ -n "$SOURCE" ] || die "no simulator named \"$DEVICE\" (xcrun simctl list devices available)"
    [ "$(device_state "$SOURCE")" = "Shutdown" ] || die "\"$DEVICE\" must be shut down to be cloned"
    echo "Cloning \"$DEVICE\" as $CLONE..." >&2
    [ "$INSTALL" -eq 0 ] || [ -d "$(app_path "$(device_platform "$SOURCE")")" ] \
        || die "no app at $(app_path "$(device_platform "$SOURCE")"); run Tools/Simulator/build.sh first"
    UDID=$(xcrun simctl clone "$SOURCE" "$CLONE")
fi
PLATFORM=$(device_platform "$UDID")
APP=$(app_path "$PLATFORM")
[ "$INSTALL" -eq 0 ] || [ -d "$APP" ] || die "no app at $APP; run Tools/Simulator/build.sh$([ "$PLATFORM" = tvos ] && echo ' --platform tvos') first"

cleanup_clone() {
    if [ "$KEEP" -eq 0 ]; then
        echo "Deleting $CLONE..." >&2
        xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
        xcrun simctl delete "$UDID" > /dev/null 2>&1 || true
    else
        echo "Kept $CLONE ($UDID) booted. Delete it with: Tools/Simulator/cleanup.sh $CLONE" >&2
    fi
}
trap cleanup_clone EXIT
trap 'exit 130' INT TERM

# 2. Boot and system settings.
echo "Booting $CLONE ($UDID)..." >&2
WAS_BOOTED=0
[ "$(device_state "$UDID")" != "Booted" ] || WAS_BOOTED=1
xcrun simctl bootstatus "$UDID" -b > /dev/null
if [ "$WAS_BOOTED" -eq 0 ]; then
    # bootstatus returns before SpringBoard has finished its first-boot work; an app launched during it can
    # end up behind the Home Screen.
    sleep "${FLUXO_SIM_BOOT_SETTLE:-5}"
fi
[ -z "$APPEARANCE" ] || xcrun simctl ui "$UDID" appearance "$APPEARANCE"
[ -z "$CONTENT_SIZE" ] || xcrun simctl ui "$UDID" content_size "$CONTENT_SIZE"
# A clean, fixed status bar, so screenshots compare well (Apple TV has none).
if [ "$PLATFORM" != tvos ]; then
    xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 > /dev/null 2>&1 || true
fi

# 3. Install and launch.
if [ "$INSTALL" -eq 1 ]; then
    xcrun simctl install "$UDID" "$APP"
fi
STATUS_DIR=$(status_directory "$UDID") || die "Fluxo is not installed on $CLONE"
rm -rf "$STATUS_DIR"

if [ -n "$LANGUAGE" ]; then
    set -- -AppleLanguages "($LANGUAGE)" -AppleLocale "$LANGUAGE" "$@"
fi
if [ "$STEP_SHOTS" -eq 1 ]; then
    set -- -FluxoDebugPauseAfterEachRoute YES "$@"
fi
if [ -n "$ROUTE" ]; then
    set -- -FluxoDebugRoute "$ROUTE" "$@"
fi
if [ "$SEED" != "none" ]; then
    set -- -FluxoDebugSeed "$SEED" "$@"
fi
set -- -FluxoDebugStore "$STORE" "$@"

echo "Launching Fluxo $*" >&2
LOG_START=$(date '+%Y-%m-%d %H:%M:%S')
xcrun simctl launch --terminate-running-process --stdout="$OUT/app-stdout.log" --stderr="$OUT/app-stderr.log" \
    "$UDID" "$BUNDLE_ID" "$@" > /dev/null

# 4. Wait for the harness, with screenshots after each step if asked.
SHOTS="$OUT/.shots-$$"
: > "$SHOTS"
STARTED=$(date +%s)
STEP=1
RESULT=0
FRONT=0
while [ ! -f "$STATUS_DIR/ready" ]; do
    if [ -f "$STATUS_DIR/step-$STEP" ]; then
        if [ "$STEP_SHOTS" -eq 1 ]; then
            echo "Step $STEP: $(cat "$STATUS_DIR/step-$STEP")" >&2
            [ "$FRONT" -eq 1 ] || { bring_to_front "$UDID"; FRONT=1; }
            screenshot_all "$UDID" "$OUT/$NAME-step$STEP" | tee -a "$SHOTS"
            rm -f "$STATUS_DIR/step-$STEP"
        fi
        STEP=$((STEP + 1))
        continue
    fi
    if [ $(($(date +%s) - STARTED)) -ge "$TIMEOUT" ]; then
        echo "warning: the harness did not report ready within $TIMEOUT s; see $OUT/app.log" >&2
        RESULT=2
        break
    fi
    sleep 0.2
done
sleep "$SETTLE"
[ "$FRONT" -eq 1 ] || bring_to_front "$UDID"

# 5. Final screenshots, a contact sheet when there are several, and the app log of this launch.
screenshot_all "$UDID" "$OUT/$NAME" | tee -a "$SHOTS"
if [ "$(grep -c . "$SHOTS")" -gt 1 ]; then
    # shellcheck disable=SC2046 # one screenshot path per line, without spaces
    xcrun swift "$(dirname "$0")/contact_sheet.swift" "$OUT/$NAME-contact.png" --height 800 --columns 5 $(cat "$SHOTS") \
        || echo "warning: no contact sheet" >&2
fi
rm -f "$SHOTS"
xcrun simctl spawn "$UDID" log show --start "$LOG_START" --style compact \
    --predicate 'subsystem == "dev.watermelon.Fluxo"' > "$OUT/app.log" 2>/dev/null || true
if grep -q "failed:\|Unknown debug route\|Could not" "$OUT/app.log" 2>/dev/null; then
    echo "Harness problems (from $OUT/app.log):" >&2
    grep "failed:\|Unknown debug route\|Could not" "$OUT/app.log" | sed 's/^/  /' | head -10 >&2
fi
exit "$RESULT"
