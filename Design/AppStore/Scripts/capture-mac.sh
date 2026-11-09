#!/bin/bash
# Captures the Mac screens of the App Store screenshots: the Debug Mac app with the harness on the `store` seed
# (an in-memory library: the real one, its settings and its Spotlight entries are never touched), one launch per
# screen, its windows captured one by one and composed on a 1440 x 900 pt desktop (mac_desktop.swift). Needs the
# demo footage (demo-footage.sh start) and Screen Recording permission for the terminal.
#
#   Design/AppStore/Scripts/capture-mac.sh <language> <out> [screen…]
#
# The Debug app is built ad hoc signed, so it runs with its sandbox (FLUXO_MAC_APP overrides the path):
#   xcodebuild -project Fluxo.xcodeproj -scheme Fluxo -configuration Debug -destination 'platform=macOS' \
#       -derivedDataPath /tmp/fluxo-dd/<worktree folder>-macdebug CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
#       DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build
# It shares the sandbox container with a Fluxo you may run: quit that one first (the script refuses otherwise).
#
# The guide and Search show the Mac's time (the menu bar's clock is drawn at 9:41): FLUXO_MAC_TZ runs the app in
# another time zone (`TZ`), so the screens show an evening wherever and whenever they are captured, e.g.
# FLUXO_MAC_TZ=Etc/GMT+12 at 1:45 AM in Vancouver (UTC-7) shows 8:45 PM.
#
# Each capture is taken with Fluxo the frontmost app, so its windows look active (coloured window buttons, accent
# selections): run it with the screen unlocked, and leave the Mac alone while it runs. With the screen locked the app
# cannot come to the front and the script stops; FLUXO_MAC_ALLOW_INACTIVE=1 captures anyway (drafts only: the windows
# then look inactive).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
language=${1:?usage: capture-mac.sh <language> <out> [screen…]}
out=${2:?out}
shift 2
app=${FLUXO_MAC_APP:-/tmp/fluxo-dd/$(basename "$ROOT")-macdebug/Build/Products/Debug/Fluxo.app}
footage=${FLUXO_FOOTAGE_URL:-http://127.0.0.1:18960}
wallpaper=${FLUXO_WALLPAPER:-${FLUXO_FOOTAGE_DIR:-/tmp/fluxo-appstore-footage}/dusk.png}
status="$HOME/Library/Containers/dev.watermelon.Fluxo/Data/tmp/FluxoDebug/Status"
[ -d "$app" ] || { echo "error: no app at $app (see the build command above)" >&2; exit 1; }
[ -f "$wallpaper" ] || { echo "error: no wallpaper at $wallpaper (demo-footage.sh start draws it)" >&2; exit 1; }
curl -sf "$footage/hls/live.m3u8" > /dev/null || { echo "error: start demo-footage.sh first ($footage)" >&2; exit 1; }
if pgrep -f "Fluxo.app/Contents/MacOS/Fluxo" | while read -r pid; do ps -o command= -p "$pid"; done | grep -qv "$app"; then
    echo "error: another Fluxo is running; quit it first (the debug app shares its container)" >&2
    exit 1
fi
mkdir -p "$out"

base="seed-guide;progress:Orbit S01E02;progress:Crimson Signal"
query="sports tonight"
[ "$language" != it ] || query="sport stasera"
# name|route|path prefix of the footage server|window size (default 1280x780; Search's results fill a shorter one)
screens=(
    "home|$base;home;featured-seed:2;featured-page:2;wait:10|"
    "guide|$base;guide;wait:10|"
    "series|$base;series:Orbit;wait:3|"
    "recordings|library;wait:2|"
    "downloads|download:The Silent Harbor;download-wait:180;download:Crimson Signal;download-progress:0.4;pause-download:Crimson Signal;downloads;wait:2|/slow/40000"
    "search|$base;search:$query;wait:10||1280x620"
    # Wildframe through the engine: a minute and a half of time-shift, then a skip a minute back (as capture.sh).
    "player|$base;player:Wildframe;wait:8;wait:90;skip:-60;wait:2;player-controls:show;wait:1|"
    # Siri & Shortcuts, from its second phrase: the first one's example is a real channel.
    "siri|$base;home;wait:3;settings-section:siri-whats-on;wait:2|"
    # The Mac has no iCloud sync yet, so its privacy screen is Settings › About (Diagnostic Reports, Privacy Policy).
    "about|$base;home;wait:3;settings-section:about;wait:2|"
    "credits|acknowledgements;wait:3|"
)

env_args=()
[ -z "${FLUXO_MAC_TZ:-}" ] || env_args=(--env "TZ=$FLUXO_MAC_TZ")

bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")

# Brings Fluxo to the front; false when it cannot be (the screen is locked, or another app keeps the focus).
activate() {
    osascript -e "tell application id \"$bundle\" to activate" > /dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        lsappinfo info -only bundleid "$(lsappinfo front)" | grep -q "\"$bundle\"" && return 0
        sleep 0.25
    done
    return 1
}

quit() {
    pkill -f "$app/Contents/MacOS/Fluxo" 2> /dev/null || true
    for _ in $(seq 1 40); do pgrep -f "$app/Contents/MacOS/Fluxo" > /dev/null || return 0; sleep 0.25; done
}
trap quit EXIT

for entry in "${screens[@]}"; do
    IFS='|' read -r name route prefix size <<< "$entry"
    if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then
        continue
    fi
    echo "== mac $language $name" >&2
    quit
    rm -rf "$status"
    open -n ${env_args[@]+"${env_args[@]}"} "$app" --args -ApplePersistenceIgnoreState YES -AppleLanguages "($language)" -AppleLocale "$language" \
        -FluxoDebugStore memory -FluxoDebugSeed store -FluxoDebugAppearance dark -FluxoDebugTestStreamURL "$footage$prefix" \
        -FluxoDebugRoute "window-size:${size:-1280x780};$route"
    started=$(date +%s)
    until [ -f "$status/ready" ]; do
        if [ $(($(date +%s) - started)) -ge 300 ]; then
            echo "warning: $name did not report ready" >&2
            break
        fi
        sleep 0.5
    done
    if ! activate; then
        if [ "${FLUXO_MAC_ALLOW_INACTIVE:-0}" != 1 ]; then
            echo "error: Fluxo is not the frontmost app (is the screen locked?); its windows would look inactive" >&2
            exit 1
        fi
        echo "warning: Fluxo is not the frontmost app: $name is captured with inactive windows" >&2
    fi
    sleep 1.5
    work="$out/.run-$name"
    rm -rf "$work"
    mkdir -p "$work"
    layers=()
    while read -r id x y w h; do
        screencapture -x -o -l"$id" "$work/$id.png"
        layers+=("$work/$id.png:$x,$y,$w,$h")
    done < <(xcrun swift "$HERE/mac_desktop.swift" list)
    [ ${#layers[@]} -gt 0 ] || { echo "warning: no Fluxo window for $name" >&2; continue; }
    xcrun swift "$HERE/mac_desktop.swift" compose "$out/$name.png" "$wallpaper" "$language" "${layers[@]}"
done
