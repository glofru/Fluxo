#!/bin/bash
# Makes the Xcode of the given version the active one (CI), or fails with what the Mac has.
#
#   Tools/CI/select-xcode.sh 27.2
#
# Looks in /Applications for Xcode_<version>.app (GitHub's images), Xcode-<version>.app, Xcode.app, Xcode-beta.app and
# any other Xcode*.app, and takes the first whose version is <version> (27.2 matches 27.2 and 27.2.x). FLUXO_XCODE_PATH
# names one directly. Uses sudo xcode-select when it can, DEVELOPER_DIR (exported to later steps on GitHub) otherwise.
set -euo pipefail

wanted="${1:?usage: Tools/CI/select-xcode.sh <version>}"

version_of() { # Xcode.app
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2> /dev/null || true
}

candidates=()
if [ -n "${FLUXO_XCODE_PATH:-}" ]; then
    candidates+=("$FLUXO_XCODE_PATH")
fi
candidates+=("/Applications/Xcode_$wanted.app" "/Applications/Xcode-$wanted.app" /Applications/Xcode.app /Applications/Xcode-beta.app)
for app in /Applications/Xcode*.app; do
    candidates+=("$app")
done

for app in "${candidates[@]}"; do
    [ -d "$app" ] || continue
    version=$(version_of "$app")
    if [ "$version" = "$wanted" ] || [[ "$version" == "$wanted".* ]]; then
        developer="$app/Contents/Developer"
        if sudo -n xcode-select -s "$developer" 2> /dev/null; then
            echo "Selected $app (Xcode $version) with xcode-select"
        else
            echo "Using $app (Xcode $version) through DEVELOPER_DIR"
        fi
        export DEVELOPER_DIR="$developer"
        if [ -n "${GITHUB_ENV:-}" ]; then
            echo "DEVELOPER_DIR=$developer" >> "$GITHUB_ENV"
        fi
        xcodebuild -version
        exit 0
    fi
done

echo "error: no Xcode $wanted on this Mac. Installed:" >&2
for app in /Applications/Xcode*.app; do
    [ -d "$app" ] && echo "  $app: $(version_of "$app")" >&2
done
echo "See docs/ci.md: GitHub's xcode-27 image, or a self-hosted runner with Xcode $wanted." >&2
exit 1
