#!/bin/sh
# Shuts down and deletes the clones whose names start with the given prefixes. Only names starting with
# "fluxo-" are accepted, so the simulators you use yourself are never touched.
#
#   Tools/Simulator/cleanup.sh fluxo-mykey-       every clone of one key
#   Tools/Simulator/cleanup.sh fluxo-mykey-1      one clone
#   Tools/Simulator/cleanup.sh --list             list every fluxo- clone
set -eu
. "$(dirname "$0")/common.sh"

list_clones() {
    xcrun simctl list devices -j | /usr/bin/python3 -I -c '
import json, sys
prefix = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["name"].startswith(prefix):
            print(device["udid"], device["state"], device["name"], sep="\t")
' "$1"
}

[ $# -ge 1 ] || die "usage: $0 <fluxo-prefix>... | --list"
if [ "$1" = "--list" ]; then
    list_clones "$CLONE_PREFIX"
    exit 0
fi
for prefix in "$@"; do
    case "$prefix" in
    "$CLONE_PREFIX"?*) ;;
    *) die "refusing \"$prefix\": prefixes must start with $CLONE_PREFIX and be longer" ;;
    esac
done
for prefix in "$@"; do
    list_clones "$prefix" | while IFS="$(printf '\t')" read -r udid state name; do
        echo "Deleting $name ($udid, $state)"
        [ "$state" = "Shutdown" ] || xcrun simctl shutdown "$udid" > /dev/null 2>&1 || true
        xcrun simctl delete "$udid"
    done
done
