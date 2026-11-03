#!/bin/zsh
# Renders the app icon (Fluxo/AppIcon.icon) in every appearance with Icon Composer's ictool.
#
# Usage: Design/Icon/render_previews.sh [output-directory]   (default: /tmp/fluxo-icon-previews)
set -euo pipefail

root=${0:A:h:h:h}
icon="$root/Fluxo/AppIcon.icon"
out=${1:-/tmp/fluxo-icon-previews}
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x $ictool ]] || ictool=$(xcrun -f ictool)
mkdir -p "$out"

render() { # platform rendition file [extra arguments]
  local platform=$1 rendition=$2 file=$3; shift 3
  "$ictool" "$icon" --export-image --output-file "$out/$file" --platform "$platform" \
    --rendition "$rendition" --width 1024 --height 1024 --scale 1 "$@" > /dev/null
  print "$out/$file"
}

for rendition in Default Dark ClearLight ClearDark; do
  render iOS $rendition "ios-$rendition.png"
done
for rendition in TintedLight TintedDark; do
  render iOS $rendition "ios-$rendition.png" --tint-color 0.6 --tint-strength 0.75
done
render macOS Default macos-Default.png
render macOS Dark macos-Dark.png
