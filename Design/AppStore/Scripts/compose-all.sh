#!/bin/bash
# Composes every App Store screenshot set into Design/AppStore/<platform>/<locale>/ from the captures of capture.sh and
# capture-mac.sh, kept in <captures>/<platform>-<language>/ (iphone-en, ipad-it, mac-en, tv-it…).
#
#   FIGCRAFT_CLI=/path/to/figcraft-cli Design/AppStore/Scripts/compose-all.sh <captures> [platform…]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
captures=${1:?usage: compose-all.sh <captures folder> [iphone|ipad|mac|tv…]}
shift
platforms=("$@")
[ ${#platforms[@]} -gt 0 ] || platforms=(iphone ipad mac tv)
for platform in "${platforms[@]}"; do
    case "$platform" in
    iphone) folder=iPhone ;;
    ipad) folder=iPad ;;
    mac) folder=Mac ;;
    tv) folder=AppleTV ;;
    *) echo "error: unknown platform $platform" >&2; exit 2 ;;
    esac
    for language in en it; do
        locale=$language
        [ "$language" != en ] || locale=en-US
        out="$HERE/../$folder/$locale"
        rm -f "$out"/*.png "$out"/*.figcraft
        python3 -I "$HERE/compose.py" "$platform" "$language" "$captures/$platform-$language" "$out"
    done
done
