#!/bin/bash
# Captures the app screens of the App Store screenshots from a simulator, with the Debug harness and the `store` seed
# (invented channels, titles and artwork only), a clean status bar (9:41, full signal and battery) and the demo
# footage of demo-footage.sh (start it first). One launch per screen; the captures go to <out>/<screen>.png.
#
#   Design/AppStore/Scripts/capture.sh <iphone|ipad|tv> <clone> <language> <out> [screen…]
#
#   <clone>     a kept simulator clone named fluxo-… (Tools/Simulator/run.sh --keep), e.g. an iPhone 17 Pro Max for the
#               6.9" screenshots, an iPad Pro 13-inch (M5) for the 13" ones, an Apple TV 4K for the TV ones
#   <language>  en or it (the app's language and locale)
#   [screen…]   only these screens (default: all of the platform)
#
# Build the Debug app first (Tools/Simulator/build.sh, with --platform tvos for Apple TV). The first screen installs it
# on the clone; the next ones relaunch it. Screens use the dark appearance, as the screenshots do.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
platform=${1:?usage: capture.sh <iphone|ipad|tv> <clone> <language> <out> [screen…]}
clone=${2:?clone}
language=${3:?language}
out=${4:?out}
shift 4
footage=${FLUXO_FOOTAGE_URL:-http://127.0.0.1:18960}
curl -sf "$footage/hls/live.m3u8" > /dev/null || { echo "error: start demo-footage.sh first ($footage)" >&2; exit 1; }
mkdir -p "$out"
# One date on the iPad's status bar for every screen of a run (the day it starts, even past midnight), at 9:41 PM:
# the evening the screens show (the iPhone shows "9:41"), and the app in the evening wherever and whenever it runs
# (FLUXO_SIM_TZ, a time zone where it is about 9 PM: the guide, Search and For You Tonight show its time), as
# capture-mac.sh does with FLUXO_MAC_TZ.
# (simctl takes an ISO 8601 date with milliseconds and the offset, e.g. 2026-11-08T21:41:00.000-07:00.) simctl of
# Xcode 27.2 writes the date of such an override in English whatever the system's language ("Sun 8 Nov" on an Italian
# iPad), so on the Italian iPad (whose system is Italian, see below) the override is the time alone, as Italian writes
# it, and the iPad shows its own date, in Italian ("Dom 8 nov"): the day of the capture (do not run it past midnight).
if [ -z "${FLUXO_SIM_STATUS_TIME:-}" ] && [ "$platform:$language" = ipad:it ]; then
    FLUXO_SIM_STATUS_TIME=21:41
fi
export FLUXO_SIM_STATUS_TIME=${FLUXO_SIM_STATUS_TIME:-$(date +%Y-%m-%dT21:41:00.000%z | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/')}
[ -z "${FLUXO_SIM_TZ:-}" ] || export SIMCTL_CHILD_TZ="$FLUXO_SIM_TZ"

# Routes shared by the screens: a guide, a movie and an episode half watched, the featured rotation whose first page
# is The Lantern Protocol.
base="seed-guide;progress:Orbit S01E02;progress:Crimson Signal"
featured="featured-seed:6"
# The player: Wildframe through the engine (raw MPEG-TS, as IPTV live channels play), a minute and a half of
# time-shift and then a skip a minute back, so its timeline and Go Live show what time-shift does.
timeshift="wait:90;skip:-60;wait:2"
# (The timeline then reads about -0:45, not -1:00: it counts behind the live point, the end of the stream less
# AVPlayer's recommended live offset (AVPlayerViewModel.liveOffset), while the skip counts from where playback was,
# about 15 s nearer the end than that point.)
# A request in the screenshot's language, for Smart Results (Apple Intelligence, or the built-in rules without it).
query="sports tonight"
[ "$language" != it ] || query="sport stasera"

# name|route|path prefix of the footage server (its throttle)|more launch arguments
screens_touch=(
    "home|$base;home;$featured;wait:12||"
    "guide|$base;guide;wait:10||"
    "series|$base;series:Orbit;wait:2||"
    "library|download:The Silent Harbor;download-wait:180;download:Crimson Signal;download-progress:0.4;pause-download:Crimson Signal;library;wait:1|/slow/40000|"
    "search|$base;search:$query;wait:10||"
    "player|$base;player:Wildframe;wait:6;orientation:landscape;wait:3;fill:on;$timeshift;player-controls:show;wait:1||"
    "cast|$base;player:Wildframe;wait:5;fill:on;player-controls:show;wait:1;cast-picker;wait:3;cast:Living Room;wait:4||-FluxoDebugCast simulated"
    # Over Home at the same featured page in every language.
    "privacy|home;$featured;wait:4;cloud-privacy;wait:1||"
    "about|settings-section:about;wait:1||"
    "credits|acknowledgements;wait:2||"
    "license|acknowledgements:fluxo;wait:2||"
    "siri|||"
)
screens_tv=(
    "home|$base;home;$featured;wait:10;focus:hero;featured-page:0;wait:1||"
    "guide|$base;tab:guide;wait:8;focus:guide-now;wait:2||"
    "series|$base;series:Orbit;wait:3;focus:episode:S1 E2;wait:2||"
    "movies|$base;tab:movies;wait:4||"
    "foryou|$base;home;$featured;wait:10;home-section:continueWatching;wait:2||"
    "search|$base;search:$query;wait:10||"
    "player|$base;player:Wildframe;wait:8;tv-panel:guide;wait:2||"
    "voice|settings-siri;wait:1;focus:siri-voice-search;wait:2||"
    "credits|acknowledgements;wait:3||"
    "license|acknowledgements:fluxo;wait:3||"
)
# iPad: the player turned, with the guide in its side panel. iPadOS ignores the app's own rotation requests, so the
# gesture tests turn the device (XCUITest) and leave it turned for this launch.
screens_ipad=("${screens_touch[@]}")
screens_ipad[5]="player|$base;side-panel:guide;player:Wildframe;wait:6;$timeshift;player-controls:show;wait:1||"
# iPad: the device picker, not connected: the iPad's form sheet leaves the player's note visible, and connected to a
# receiver the note says that the demo footage (127.0.0.1) only plays on this device. The iPhone's sheet covers it.
# Northwind Sports (HLS): under the picker the iPad's sheet says that raw MPEG-TS channels (Wildframe) may not play on
# a Chromecast.
screens_ipad[6]="cast|$base;player:Northwind Sports;wait:5;fill:on;player-controls:show;wait:1;cast-picker;wait:3||-FluxoDebugCast simulated"
# The iPad's status bar shows the date, in the system's language: the clone's own language and region follow the
# screenshot's (run.sh --system-locale, which restarts the clone when they change). The iPhone's shows only the time,
# so its clone stays in English (see README.md for its Siri screenshot).
system=()
[ "$platform" != ipad ] || { system=(--system-locale en_US); [ "$language" != it ] || system=(--system-locale it_IT); }
case "$platform" in
iphone) screens=("${screens_touch[@]}") ;;
ipad) screens=("${screens_ipad[@]}") ;;
tv) screens=("${screens_tv[@]}") ;;
*) echo "error: unknown platform $platform" >&2; exit 2 ;;
esac

# Turns an iPad clone (portrait or landscape) with the gesture tests' layout screenshot, kept turned.
turn() {
    TEST_RUNNER_FLUXO_LAYOUT_SHOTS="turn|$1|dark|home" TEST_RUNNER_FLUXO_LAYOUT_KEEP_ORIENTATION=1 \
        FLUXO_SHOTS="$out/.turn" "$ROOT/Tools/Simulator/gesture-tests.sh" "$clone" \
        -only-testing:GestureTests/GestureTests/testLayoutScreenshots > "$out/.turn.log" 2>&1 \
        || echo "warning: could not turn the device to $1 (see $out/.turn.log)" >&2
}

# iPad: Full Screen Apps (Settings › Multitasking & Gestures), so the screens show no resize grabber in the corner
# (windowed apps, the Simulator's default). The gesture tests set it in Settings (in English, so before the system
# turns Italian); the clone keeps it.
if [ "$platform" = ipad ]; then
    udid=$(xcrun simctl list devices -j | python3 -I -c 'import json,sys; print(next((d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"] == sys.argv[1]), ""))' "$clone")
    if [ "$(xcrun simctl spawn "$udid" defaults read com.apple.springboard SBMedusaMultitaskingEnabled 2>/dev/null || true)" != 0 ]; then
        "$ROOT/Tools/Simulator/run.sh" --clone "$clone" --keep --seed none --system-locale en_US --out "$out/.run-setup" \
            --route "wait:1" > "$out/.run-setup.log" 2>&1 || true
        FLUXO_SHOTS="$out/.full-screen" "$ROOT/Tools/Simulator/gesture-tests.sh" "$clone" \
            -only-testing:GestureTests/GestureTests/testFullScreenAppsMode > "$out/.full-screen.log" 2>&1 \
            || echo "warning: could not turn on Full Screen Apps (see $out/.full-screen.log)" >&2
    fi
fi

install=()
for entry in "${screens[@]}"; do
    IFS='|' read -r name route prefix more <<< "$entry"
    if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then
        continue
    fi
    echo "== $platform $language $name" >&2
    if [ "$name" = siri ]; then
        # The system side: the Shortcuts app runs Fluxo's What's On and shows its answer (SiriTests).
        rm -rf "$out/.run-siri"
        # The Shortcuts app follows the simulator's language: set it first (see README.md, "Italian").
        whats_on="What's On"
        [ "$language" != it ] || whats_on="Cosa c’è in onda"
        FLUXO_SEED=store FLUXO_WHATS_ON="$whats_on" FLUXO_SHOTS="$out/.run-siri" "$ROOT/Tools/Simulator/siri-tests.sh" "$clone" \
            -only-testing:SiriTests/SiriTests/testWhatsOnResultScreenshot > "$out/.run-siri.log" 2>&1 || true
        # English: What's On's answer. Other languages: Fluxo's App Shortcuts (on the iOS 27.2 Simulator the answer's
        # sheet stays in English whatever the simulator's language).
        siri_shot=03-whats-on-result
        [ "$language" = en ] || siri_shot=02-fluxo-app-shortcuts
        if [ -f "$out/.run-siri/$siri_shot.png" ]; then
            cp "$out/.run-siri/$siri_shot.png" "$out/siri.png"
        else
            echo "warning: no $siri_shot screenshot (see $out/.run-siri.log)" >&2
        fi
        continue
    fi
    appearance=(--appearance dark)
    steps=()
    # shellcheck disable=SC2206 # the launch arguments of a screen are words without spaces
    extra=(-FluxoDebugTestStreamURL "$footage$prefix" $more)
    if [ "$platform" = tv ]; then
        # tvOS: no system appearance to set; a screenshot after the last step, since bringing the app to the front for
        # the final one closes the player's panels and transport bar.
        appearance=()
        extra+=(-FluxoDebugAppearance dark)
        steps=(--step-shots)
    fi
    [ "$platform:$name" != ipad:player ] || turn landscape
    FLUXO_SIM_BATTERY_STATE=discharging "$ROOT/Tools/Simulator/run.sh" --clone "$clone" --seed store --keep \
        ${install[@]+"${install[@]}"} ${system[@]+"${system[@]}"} ${appearance[@]+"${appearance[@]}"} ${steps[@]+"${steps[@]}"} --language "$language" --timeout 300 --settle 1 \
        --out "$out/.run-$name" --route "$route" -- "${extra[@]}" > "$out/.run-$name.log" 2>&1 \
        || echo "warning: $name did not report ready (see $out/.run-$name.log)" >&2
    grep -A3 "Harness problems" "$out/.run-$name.log" >&2 || true
    if [ ${#steps[@]} -gt 0 ]; then
        last=$(find "$out/.run-$name" -name 'shot-step*.png' ! -name '*-contact.png' | sed 's/.*shot-step\([0-9]*\).*/\1 &/' | sort -n | tail -1 | cut -d' ' -f2)
        cp "$last" "$out/$name.png"
    else
        shots=("$out/.run-$name"/shot*.png)
        cp "${shots[0]}" "$out/$name.png"
    fi
    [ "$platform:$name" != ipad:player ] || turn portrait
    install=(--no-install)
done
