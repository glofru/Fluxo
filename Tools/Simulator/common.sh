# Shared helpers of the Tools/Simulator scripts (sourced, not run).

BUNDLE_ID=dev.watermelon.Fluxo
SIM_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# One Debug build per worktree (/tmp/fluxo-dd/<worktree folder>-sim, the same folder as the gate simulator
# build of that worktree), shared by every run.
DERIVED_DATA=${FLUXO_SIM_DERIVED_DATA:-/tmp/fluxo-dd/$(basename "$SIM_ROOT")-sim}
APP_PATH=${FLUXO_SIM_APP:-$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Fluxo.app}
# Clones are always named with this prefix, so cleanup.sh can never delete another simulator.
CLONE_PREFIX=fluxo-

die() {
    echo "error: $*" >&2
    exit 1
}

# UDID of the available simulator named exactly $1 (empty if there is none, an error if there are several).
device_udid() {
    xcrun simctl list devices available -j | /usr/bin/python3 -I -c '
import json, sys
name = sys.argv[1]
matches = [device["udid"] for devices in json.load(sys.stdin)["devices"].values() for device in devices if device["name"] == name]
if len(matches) > 1:
    sys.exit("several simulators are named %r: %s" % (name, ", ".join(matches)))
print(matches[0] if matches else "")
' "$1"
}

# Booted, Shutdown, ...
device_state() {
    xcrun simctl list devices -j | /usr/bin/python3 -I -c '
import json, sys
udid = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["udid"] == udid:
            print(device["state"])
' "$1"
}

# Names of the integrated displays of a booted device, one per line ("LCD", and "LCD-1" on the iPhone Duo).
integrated_displays() {
    xcrun simctl io "$1" enumerate 2>/dev/null | awk '
        /^    \([0-9]+\) / { name = "" }
        /^        Name: / { name = $2 }
        /^        Screen Type: / { if ($3 == "Integrated" && name != "") print name }
    '
}

# Screenshots every integrated display of device $1 to $2-<display>.png, or $2.png when the device has one display.
screenshot_all() {
    udid=$1
    prefix=$2
    displays=$(integrated_displays "$udid")
    count=$(printf '%s\n' "$displays" | grep -c . || true)
    if [ "$count" -le 1 ]; then
        xcrun simctl io "$udid" screenshot "$prefix.png" > /dev/null 2>&1 && echo "$prefix.png"
        return
    fi
    for display in $displays; do
        if xcrun simctl io "$udid" screenshot --display="$display" "$prefix-$display.png" > /dev/null 2>&1; then
            echo "$prefix-$display.png"
        else
            echo "warning: no screenshot of display $display (it may be powered off)" >&2
        fi
    done
}

# True when Fluxo is running on device $1.
app_running() {
    xcrun simctl spawn "$1" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BUNDLE_ID\["
}

# Brings the running Fluxo to the front of device $1 without relaunching it (same process, same state;
# launch arguments are ignored). On a freshly booted clone of a busy Mac, SpringBoard sometimes finishes its
# first-boot work after the launch and screenshots then show the Home Screen while the app runs behind it.
# Does nothing when the app is not running, so it never starts it without the harness arguments.
bring_to_front() {
    if app_running "$1"; then
        xcrun simctl launch "$1" "$BUNDLE_ID" > /dev/null 2>&1 || true
        sleep 1
    fi
}

# Status directory of the debug harness inside the app's data container (see DebugHarness.swift).
status_directory() {
    container=$(xcrun simctl get_app_container "$1" "$BUNDLE_ID" data 2>/dev/null) || return 1
    echo "$container/tmp/FluxoDebug/Status"
}
