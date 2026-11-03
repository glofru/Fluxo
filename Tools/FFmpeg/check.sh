#!/bin/sh
# Checks the macOS slice of Vendor/FFmpeg/FFmpeg.xcframework: version, LGPL license, the
# components the remux engine needs, and that the URLs given as arguments open and probe.
#
#   Tools/FFmpeg/check.sh                                   # components only
#   Tools/FFmpeg/check.sh https://example.com/stream.m3u8   # also opens (https: Secure Transport)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/Tools/FFmpeg/env.sh"
WORK=$(mktemp -d /tmp/fluxo-ffmpeg-check.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
BIN=$WORK/check_framework

# shellcheck disable=SC2086 # FFMPEG_CFLAGS / FFMPEG_LDFLAGS are lists of words.
clang -O1 -Wall -Wextra -o "$BIN" $FFMPEG_CFLAGS "$ROOT/Tools/FFmpeg/check_framework.c" $FFMPEG_LDFLAGS

otool -L "$BIN" | grep -q /opt/homebrew && { echo "error: the checker links Homebrew" >&2; exit 1; }
"$BIN" "$@"
