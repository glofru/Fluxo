#!/bin/sh
# Sets the build number (CFBundleVersion) of the app and its extension for an App Store or TestFlight upload.
# Every upload needs a new, higher build number for the same version (MARKETING_VERSION).
#
#   Tools/Release/set-build-number.sh            # the number of commits on HEAD (always grows on main)
#   Tools/Release/set-build-number.sh 42         # an explicit number, e.g. the CI run number
#
# It runs agvtool (the project uses VERSIONING_SYSTEM = apple-generic), which writes CURRENT_PROJECT_VERSION into
# project.pbxproj. A CI job that does not want to change the project can pass the number to xcodebuild instead:
#   xcodebuild archive … CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
NUMBER=${1:-$(git -C "$ROOT" rev-list --count HEAD)}
case "$NUMBER" in
    ''|*[!0-9.]*) echo "error: the build number must be digits and dots, not '$NUMBER'" >&2; exit 1 ;;
esac
cd "$ROOT"
xcrun agvtool new-version -all "$NUMBER" > /dev/null
echo "Build number: $(xcrun agvtool what-version -terse)"
