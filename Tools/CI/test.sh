#!/bin/bash
# Runs the unit tests (FluxoTests, Swift Testing, through the scheme's test plan Fluxo.xctestplan) on a simulator clone
# of its own, deleted at the end, so it never touches a simulator someone uses. The test host is the Debug app,
# launched with the debug harness's in-memory library (see the test plan's arguments).
#
#   Tools/CI/test.sh [ios|mac] [derived data folder]
#
# ios (default): an iPhone simulator of the newest installed iOS runtime (FLUXO_TEST_DEVICE="iPhone 17e" picks one by
# name; FLUXO_TEST_CLONE_NAME names the clone). mac: on this Mac. The result bundle goes to $LOG_DIR/test-<platform>.xcresult.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
platform="${1:-ios}"
derived="${2:-/tmp/fluxo-dd/ci-test-$platform}"
log_dir="${LOG_DIR:-/tmp/fluxo-logs}"
mkdir -p "$log_dir"
log="$log_dir/test-$platform.log"
result="$log_dir/test-$platform.xcresult"
rm -rf "$result"

clone=""
cleanup() {
    if [ -n "$clone" ]; then
        xcrun simctl shutdown "$clone" > /dev/null 2>&1 || true
        xcrun simctl delete "$clone" > /dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

case "$platform" in
    ios)
        # The newest available iOS runtime's iPhone (by name when asked), cloned.
        source_udid=$(xcrun simctl list devices available --json | python3 -I -c '
import json, os, re, sys
wanted = os.environ.get("FLUXO_TEST_DEVICE", "")
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(match.group(1)), int(match.group(2))) if match else None
runtimes = sorted((r for r in devices if version(r)), key=version, reverse=True)
for runtime in runtimes:
    for device in devices[runtime]:
        if device["state"] == "Shutdown" and (device["name"] == wanted if wanted else device["name"].startswith("iPhone")):
            print(device["udid"]); sys.exit(0)
sys.exit(1)') || { echo "error: no shut-down iPhone simulator to clone (FLUXO_TEST_DEVICE=${FLUXO_TEST_DEVICE:-any})" >&2; exit 1; }
        clone=$(xcrun simctl clone "$source_udid" "${FLUXO_TEST_CLONE_NAME:-fluxo-ci-test-$$}")
        destination="id=$clone"
        ;;
    mac)
        destination="platform=macOS"
        ;;
    *)
        echo "error: unknown platform $platform" >&2
        exit 2
        ;;
esac

echo "== unit tests on $platform ($destination)"
status=0
xcodebuild -project "$ROOT/Fluxo.xcodeproj" -scheme Fluxo -destination "$destination" -derivedDataPath "$derived" \
    -resultBundlePath "$result" CODE_SIGNING_ALLOWED=NO test > "$log" 2>&1 || status=$?
grep -E '✘|recorded an issue|^/.*: error: |Test run with|\*\* TEST (SUCCEEDED|FAILED|EXECUTE SUCCEEDED|EXECUTE FAILED) \*\*' "$log" | head -n 200 || true
if [ "$status" -ne 0 ]; then
    tail -n 40 "$log"
fi
exit "$status"
