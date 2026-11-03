#!/bin/sh
# Screenshots every display of a booted clone (kept with run.sh --keep).
#
#   Tools/Simulator/shot.sh fluxo-mykey-1 [out-prefix]
#
# The default prefix is /tmp/fluxo-shots/<clone>/shot-<time>; the iPhone Duo gets one file per display.
# With --front, a running Fluxo is brought to the front first (see bring_to_front in common.sh).
set -eu
. "$(dirname "$0")/common.sh"

FRONT=0
if [ "${1:-}" = "--front" ]; then
    FRONT=1
    shift
fi
[ $# -ge 1 ] || die "usage: $0 [--front] <clone> [out-prefix]"
UDID=$(device_udid "$1")
[ -n "$UDID" ] || die "no simulator named $1"
[ "$(device_state "$UDID")" = "Booted" ] || die "$1 is not booted"
PREFIX=${2:-/tmp/fluxo-shots/$1/shot-$(date +%H%M%S)}
mkdir -p "$(dirname "$PREFIX")"
[ "$FRONT" -eq 0 ] || bring_to_front "$UDID"
screenshot_all "$UDID" "$PREFIX"
