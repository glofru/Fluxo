#!/bin/sh
# Checks that Settings › About › Acknowledgements (Fluxo/App/Legal/LegalInfo.swift) lists the versions that ship:
# the Swift packages of Package.resolved and the FFmpeg version and tarball SHA-256 of Vendor/FFmpeg/BUILD_INFO.txt,
# that every bundled license text exists and matches its source, and that the notices of the open-source software
# inside the Google Cast SDK (Licenses/GoogleCast-OSS.json) are those of the SDK in Package.resolved.
# Run it after updating a package or rebuilding FFmpeg (and in CI).
#
# Usage: Tools/Legal/check-acknowledgements.sh [SourcePackages directory]
#   With the SourcePackages directory of a build (<derivedDataPath>/SourcePackages; default: the newest
#   ~/Library/Developer/Xcode/DerivedData/Fluxo-*/SourcePackages), the Cast SDK notices are also extracted again from
#   the SDK and compared byte for byte.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INFO=$ROOT/Fluxo/App/Legal/LegalInfo.swift
RESOLVED=$ROOT/Fluxo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
BUILD_INFO=$ROOT/Vendor/FFmpeg/BUILD_INFO.txt
status=0

# The version the acknowledgements give a component: the `version:` line after its `id:`.
listed_version() { # id
    awk -v id="\"$1\"" '$1 == "id:" && $2 == id"," { found = 1 } found && $1 == "version:" { gsub(/[",]/, "", $2); print $2; exit }' "$INFO"
}

check() { # what expected actual
    if [ "$2" = "$3" ]; then
        echo "ok: $1 $2"
    else
        echo "error: $1 is $2, but LegalInfo.swift says '$3'" >&2
        status=1
    fi
}

resolved_version() { # identity
    python3 -I -c 'import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
print(next(p["state"].get("version", "") for p in pins if p["identity"] == sys.argv[2]))' "$RESOLVED" "$1"
}

check FlyingFox "$(resolved_version flyingfox)" "$(listed_version flyingfox)"
check "Google Cast SDK" "$(resolved_version google-cast-ios-sdk)" "$(listed_version googlecast)"
check GTMSessionFetcher "$(resolved_version gtm-session-fetcher)" "$(listed_version gtmsessionfetcher)"

ffmpeg_version=$(sed -n 's/^FFmpeg \([0-9.]*\) .*/\1/p' "$BUILD_INFO")
ffmpeg_sha=$(sed -n 's/^SHA-256: //p' "$BUILD_INFO")
check FFmpeg "$ffmpeg_version" "$(sed -n 's/.*static let ffmpegVersion = "\(.*\)"/\1/p' "$INFO")"
check "FFmpeg tarball SHA-256" "$ffmpeg_sha" "$(sed -n 's/.*static let ffmpegTarballSHA256 = "\(.*\)"/\1/p' "$INFO")"
tarball=$ROOT/Vendor/FFmpeg/source/ffmpeg-$ffmpeg_version.tar.xz
if [ -f "$tarball" ] && [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$ffmpeg_sha" ]; then
    echo "ok: source offer $tarball"
else
    echo "error: the FFmpeg source tarball $tarball is missing or does not match BUILD_INFO.txt" >&2
    status=1
fi

for resource in $(grep -o 'resource: "[^"]*"' "$INFO" | sed 's/resource: "\(.*\)"/\1/' | sort -u); do
    if [ -f "$ROOT/Fluxo/App/Legal/Licenses/$resource.txt" ]; then
        echo "ok: license text $resource.txt"
    else
        echo "error: Fluxo/App/Legal/Licenses/$resource.txt is missing" >&2
        status=1
    fi
done
cmp -s "$ROOT/LICENSE" "$ROOT/Fluxo/App/Legal/Licenses/License-Fluxo-MIT.txt" || { echo "error: License-Fluxo-MIT.txt differs from LICENSE" >&2; status=1; }
cmp -s "$ROOT/Vendor/FFmpeg/LICENSE" "$ROOT/Fluxo/App/Legal/Licenses/License-LGPL-2.1.txt" || { echo "error: License-LGPL-2.1.txt differs from Vendor/FFmpeg/LICENSE" >&2; status=1; }
cmp -s "$ROOT/Vendor/FFmpeg/LICENSE.md" "$ROOT/Fluxo/App/Legal/Licenses/License-FFmpeg-Overview.txt" || { echo "error: License-FFmpeg-Overview.txt differs from Vendor/FFmpeg/LICENSE.md" >&2; status=1; }

# The IJG notice (License-IJG.txt) is needed while the FFmpeg source has the libjpeg DCT files.
if [ -f "$tarball" ] && tar -xOf "$tarball" "ffmpeg-$ffmpeg_version/libavcodec/jrevdct.c" 2>/dev/null | grep -q "Independent JPEG Group"; then
    grep -q "based in part on the work of the Independent JPEG Group" "$ROOT/Fluxo/App/Legal/Licenses/License-IJG.txt" \
        && echo "ok: IJG notice (libavcodec/jrevdct.c)" \
        || { echo "error: License-IJG.txt lacks the credit the IJG license asks for" >&2; status=1; }
fi

# The Google Cast SDK's open-source notices.
CAST_JSON=$ROOT/Fluxo/App/Legal/Licenses/GoogleCast-OSS.json
cast_version=$(resolved_version google-cast-ios-sdk)
check "Google Cast SDK notices (GoogleCast-OSS.json)" "$cast_version" "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["sdkVersion"])' "$CAST_JSON")"
source_packages=${1:-$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Fluxo-*/SourcePackages 2>/dev/null | head -1 || true)}
if [ -n "$source_packages" ] && [ -f "$source_packages/workspace-state.json" ]; then
    fresh=$(mktemp -t fluxo-cast-oss)
    if "$ROOT/Tools/Legal/extract-googlecast-licenses.sh" "$source_packages" "$fresh" >/dev/null && cmp -s "$fresh" "$CAST_JSON"; then
        echo "ok: GoogleCast-OSS.json matches the SDK's OpenSourceLicenses in $source_packages"
    else
        echo "error: GoogleCast-OSS.json is not what the SDK in $source_packages ships; run Tools/Legal/extract-googlecast-licenses.sh $source_packages" >&2
        status=1
    fi
    rm -f "$fresh"
else
    echo "warning: no SourcePackages directory: GoogleCast-OSS.json checked against the version only (pass <derivedDataPath>/SourcePackages to compare the texts)" >&2
fi
exit $status
