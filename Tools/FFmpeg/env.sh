# Sourced by the macOS tool scripts (after they set ROOT to the repository root).
#
# FFMPEG_CFLAGS / FFMPEG_LDFLAGS build C code against the macOS slice of the bundled
# Vendor/FFmpeg/FFmpeg.xcframework, exactly what the app links (rpath included, so the binary
# runs in place); FLUXO_ENGINE_SOURCES lists the C files of the remux engine.
#
# FFMPEG / FFPROBE are the ffmpeg and ffprobe command line programs the tests use to generate
# and inspect test streams (libx264 test patterns, decode checks). They are test-only tools and
# are not linked into anything: any recent build works, e.g. `brew install ffmpeg`. Override
# them with the FFMPEG / FFPROBE environment variables.

FFMPEG_XCFRAMEWORK=$ROOT/Vendor/FFmpeg/FFmpeg.xcframework
FFMPEG_MACOS_SLICE=$(find "$FFMPEG_XCFRAMEWORK" -maxdepth 1 -type d -name 'macos-*' | head -n 1)
if [ -z "$FFMPEG_MACOS_SLICE" ]; then
    echo "error: no macOS slice in $FFMPEG_XCFRAMEWORK (run Tools/FFmpeg/build-xcframework.sh)" >&2
    exit 1
fi
FFMPEG_CFLAGS="-I $ROOT/Vendor/FFmpeg/include"
# The engine's converter (FluxoTranscoder*.c) asks VideoToolbox what the device decodes.
FFMPEG_LDFLAGS="-F $FFMPEG_MACOS_SLICE -framework FFmpeg -Wl,-rpath,$FFMPEG_MACOS_SLICE -framework VideoToolbox -framework CoreMedia -framework CoreFoundation"
# The C sources of the remux engine (every .c file of its folder, which has no other), for the tools that build it.
FLUXO_ENGINE_SOURCES=$(echo "$ROOT"/Fluxo/Features/Player/Engine/*.c)

FFMPEG=${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}
FFPROBE=${FFPROBE:-$(command -v ffprobe || echo /opt/homebrew/bin/ffprobe)}
