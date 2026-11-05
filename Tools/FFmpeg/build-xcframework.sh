#!/bin/sh
# Builds Vendor/FFmpeg/FFmpeg.xcframework: a minimal, LGPL-only, remux-oriented FFmpeg for the
# Fluxo remux engine (Fluxo/Features/Player/Engine), from a pinned and checksummed release tarball.
#
# Output (replaces the previous contents of Vendor/FFmpeg):
#   FFmpeg.xcframework   one dynamic framework ("FFmpeg") per platform, with libavformat, libavcodec,
#                        libswscale, libswresample and libavutil linked into a single dylib that exports
#                        only the public av* / sw* symbols. Slices: iOS arm64, iOS Simulator arm64 +
#                        x86_64, macOS arm64 + x86_64.
#   include/             the public libavformat / libavcodec / libswscale / libswresample / libavutil
#                        headers (identical for every slice; the script checks it).
#   BUILD_INFO.txt       version, tarball checksum and the exact configure flags.
#
# Usage:
#   Tools/FFmpeg/build-xcframework.sh
# Environment:
#   WORK=/tmp/fluxo-ffmpeg-build   scratch directory (download, sources, objects)
#   JOBS=<n>                        parallel make jobs (default: number of CPUs)
#   SLICES="ios-arm64 ..."          subset of slices to build (default: all of them)
#
# Requirements: Xcode command line tools (clang, lipo, xcodebuild) and curl. No Homebrew packages
# are used: pkg-config lookups are disabled and every external library is off except the system
# zlib, Secure Transport (the TLS backend for https on Apple platforms) and VideoToolbox (the
# system's video decoders and encoders).
#
# License: the configuration below never passes --enable-gpl, --enable-version3 or
# --enable-nonfree, so the result is LGPL v2.1 or later. It is linked dynamically, so the framework
# can be replaced by the user (LGPL section 6). The license text is copied into each framework.
set -eu

FFMPEG_VERSION=9.0.2
# SHA-256 of https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz (also recorded by Homebrew's ffmpeg formula).
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
# FFmpeg release signing key (https://ffmpeg.org/download.html#releases). Checked when gpg is available.
FFMPEG_SIGNING_KEY=FCF986EA15E6E293A5644F10B4322F04D67658D8

IOS_MIN=26.0
MACOS_MIN=26.0
FRAMEWORK_VERSION=$FFMPEG_VERSION
BUNDLE_ID=dev.watermelon.FFmpeg

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/Vendor/FFmpeg
WORK=${WORK:-/tmp/fluxo-ffmpeg-build}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
SLICES=${SLICES:-"ios-arm64 iossim-arm64 iossim-x86_64 macos-arm64 macos-x86_64"}

# Deterministic archives (no member timestamps) and no stray pkg-config / Homebrew lookups.
export ZERO_AR_DATE=1
export PKG_CONFIG_LIBDIR=/nonexistent
unset PKG_CONFIG_PATH CFLAGS CPPFLAGS LDFLAGS 2>/dev/null || true

log() { printf '\n==> %s\n' "$*"; }

# MARK: - Components

# Only what the engine reaches: it opens arbitrary IPTV inputs (MPEG-TS over HTTP(S) above all,
# plus HLS, FLV/RTMP, RTSP/RTP and UDP, and plain files), copies their audio / video packets into
# MPEG-TS / fragmented MP4 segments and recordings, and converts recordings to MP4. Streams AVPlayer
# cannot decode are converted (Fluxo/Features/Player/Engine/FluxoTranscoder.c): audio to AAC with
# FFmpeg's own decoders and AAC encoder, video to H.264 with VideoToolbox's hardware encoder.
# webvtt: the HLS demuxer probes every rendition of a master playlist while it opens it, subtitle
# playlists included, and fails the whole open when no demuxer recognises their WebVTT segments.
# Containers of movies and episodes: Matroska / WebM, AVI, ASF (WMV), Ogg, MPEG-PS (VOB), MP4 / MOV / 3GP.
# mpegvideo and m4v: the MPEG-PS demuxer identifies its video streams by probing them with the elementary stream
# demuxers (without these, MPEG-2 video is taken for MP3 audio).
DEMUXERS="mpegts hls webvtt mov flv live_flv matroska mpegps rtsp sdp rtp aac loas ac3 eac3 mp3 h264 hevc \
avi asf ogg wav mpegvideo m4v"
MUXERS="mpegts mp4 mov"
PROTOCOLS="file http https httpproxy tcp tls udp rtp rtmp rtmps rtmpt crypto data"
PARSERS="h264 hevc aac aac_latm ac3 mpegaudio mpegvideo mpeg4video opus \
dca mlp flac vorbis vp8 vp9 av1 vc1 h263 mjpeg"
# avformat_find_stream_info decodes the first frames to fill in the stream parameters (pixel and
# sample formats, reorder delay); without a decoder it waits for the whole analyzeduration of a live
# input (3 s) before it gives up on that stream. mp2 and mpeg2video are the audio and video codecs
# of many DVB-derived IPTV channels.
# The other decoders feed the transcoder. Video (re-encoded to H.264): MPEG-1/2, MPEG-4 Part 2
# (Xvid, DivX, and Microsoft's MPEG-4 variants), H.263 and Sorenson Spark (old FLV), VC-1 and WMV 7/8/9,
# VP8, VP9, Theora, Motion JPEG; H.264 itself for the profiles VideoToolbox cannot decode (High 10,
# 4:2:2). Audio (re-encoded to AAC): DTS, Dolby TrueHD / MLP, FLAC, ALAC, Opus, Vorbis, MP2 / MP1, WMA,
# AMR, Nellymoser, ADPCM and the PCM variants of WAV, AVI, MOV, Blu-ray and DVD.
DECODERS="h264 hevc aac aac_latm ac3 eac3 mp3 mp2 mpeg2video \
mpeg1video mpeg4 msmpeg4v1 msmpeg4v2 msmpeg4v3 h263 h263p flv vc1 wmv1 wmv2 wmv3 vp8 vp9 theora mjpeg \
mp1 dca truehd mlp flac alac opus vorbis wmav1 wmav2 wmapro amrnb amrwb nellymoser adpcm_ima_wav adpcm_ms \
pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be pcm_f32le pcm_f32be pcm_u8 pcm_alaw pcm_mulaw \
pcm_bluray pcm_dvd"
# AAC: FFmpeg's own encoder (LGPL). H.264: VideoToolbox (the hardware encoder of the device).
ENCODERS="aac h264_videotoolbox"
# VP9 is decoded by VideoToolbox when the device has a VP9 decoder (FFmpeg's decoder otherwise).
HWACCELS="vp9_videotoolbox"
# Inserted automatically by the muxers: ADTS -> MP4 AAC, and length-prefixed -> Annex B H.264 /
# HEVC when an MP4, FLV or Matroska input is written to MPEG-TS. extract_extradata is used by
# avformat_find_stream_info. (The VP9 decoder selects vp9_superframe_split itself.) h264_metadata writes the pixel
# aspect ratio of converted anamorphic video into its SPS (VideoToolbox does not).
BSFS="aac_adtstoasc h264_mp4toannexb hevc_mp4toannexb extract_extradata h264_metadata"

join_enable() { # kind list
    for c in $2; do printf ' --enable-%s=%s' "$1" "$c"; done
}

CONFIGURE_FLAGS="--disable-everything --disable-autodetect --disable-programs --disable-doc \
--disable-avdevice --disable-avfilter --enable-swscale --enable-swresample \
--enable-static --disable-shared --enable-pic --disable-debug \
--enable-pthreads --enable-zlib --enable-securetransport --enable-videotoolbox --enable-network \
$(join_enable demuxer "$DEMUXERS")$(join_enable muxer "$MUXERS")$(join_enable protocol "$PROTOCOLS")\
$(join_enable parser "$PARSERS")$(join_enable decoder "$DECODERS")$(join_enable encoder "$ENCODERS")\
$(join_enable hwaccel "$HWACCELS")$(join_enable bsf "$BSFS")"

# MARK: - Source

fetch_source() {
    mkdir -p "$WORK/download"
    tarball=$WORK/download/ffmpeg-$FFMPEG_VERSION.tar.xz
    if [ ! -f "$tarball" ]; then
        log "Downloading FFmpeg $FFMPEG_VERSION"
        curl --fail --location --proto '=https' --tlsv1.2 -o "$tarball.part" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
        mv "$tarball.part" "$tarball"
    fi
    actual=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
    if [ "$actual" != "$FFMPEG_SHA256" ]; then
        echo "error: checksum mismatch for $tarball: $actual" >&2
        exit 1
    fi
    echo "SHA-256 verified: $actual"

    if command -v gpg > /dev/null 2>&1; then
        curl --fail --location --proto '=https' --tlsv1.2 -s -o "$tarball.asc" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz.asc"
        gnupghome=$(mktemp -d "$WORK/gnupg.XXXXXX")
        GNUPGHOME=$gnupghome gpg --batch --quiet --keyserver hkps://keyserver.ubuntu.com --recv-keys "$FFMPEG_SIGNING_KEY"
        GNUPGHOME=$gnupghome gpg --batch --verify "$tarball.asc" "$tarball"
        rm -rf "$gnupghome"
    else
        echo "note: gpg is not installed, the release signature was not checked (the pinned SHA-256 was)."
    fi

    SRC=$WORK/src/ffmpeg-$FFMPEG_VERSION
    rm -rf "$WORK/src"
    mkdir -p "$WORK/src"
    tar -xJf "$tarball" -C "$WORK/src"
}

# MARK: - Slices

# Sets SDK, ARCH, TRIPLE and PLATFORM for a slice name.
slice_info() {
    case "$1" in
        ios-arm64)     SDK=iphoneos;        ARCH=arm64;  TRIPLE=arm64-apple-ios$IOS_MIN;              PLATFORM=ios ;;
        iossim-arm64)  SDK=iphonesimulator; ARCH=arm64;  TRIPLE=arm64-apple-ios$IOS_MIN-simulator;    PLATFORM=iossim ;;
        iossim-x86_64) SDK=iphonesimulator; ARCH=x86_64; TRIPLE=x86_64-apple-ios$IOS_MIN-simulator;   PLATFORM=iossim ;;
        macos-arm64)   SDK=macosx;          ARCH=arm64;  TRIPLE=arm64-apple-macos$MACOS_MIN;          PLATFORM=macos ;;
        macos-x86_64)  SDK=macosx;          ARCH=x86_64; TRIPLE=x86_64-apple-macos$MACOS_MIN;         PLATFORM=macos ;;
        *) echo "error: unknown slice $1" >&2; exit 1 ;;
    esac
}

build_slice() {
    slice_info "$1"
    sysroot=$(xcrun --sdk "$SDK" --show-sdk-path)
    cc=$(xcrun --sdk "$SDK" -f clang)
    build=$WORK/build/$1
    prefix=$WORK/install/$1
    rm -rf "$build" "$prefix"
    mkdir -p "$build"

    case "$ARCH" in
        arm64) ffarch=aarch64; asm_flags="" ;;
        # nasm is not part of Xcode; the C fallbacks are fine for packet copying and probing.
        x86_64) ffarch=x86_64; asm_flags="--disable-x86asm" ;;
    esac

    log "Configuring $1 ($TRIPLE)"
    # shellcheck disable=SC2086 # CONFIGURE_FLAGS is a list of words on purpose.
    (cd "$build" && "$SRC/configure" \
        --prefix="$prefix" \
        --enable-cross-compile --target-os=darwin --arch="$ffarch" \
        --cc="$cc" --sysroot="$sysroot" \
        --ar="$(xcrun -f ar)" --nm="$(xcrun -f nm)" --ranlib="$(xcrun -f ranlib)" --strip="$(xcrun -f strip)" \
        --pkg-config=false \
        --extra-cflags="-target $TRIPLE" --extra-ldflags="-target $TRIPLE" \
        $asm_flags $CONFIGURE_FLAGS > "$build/configure.out" 2>&1) || {
        tail -n 40 "$build/config.log" >&2
        exit 1
    }
    # https must stay available: configure silently drops Secure Transport if its check fails.
    for required in CONFIG_SECURETRANSPORT CONFIG_ZLIB CONFIG_VIDEOTOOLBOX; do
        grep -q "^#define $required 1" "$build/config.h" || { echo "error: $required is off in $1" >&2; exit 1; }
    done
    for required in CONFIG_HTTPS_PROTOCOL CONFIG_TLS_PROTOCOL CONFIG_MPEGTS_DEMUXER CONFIG_MPEGTS_MUXER CONFIG_MP4_MUXER \
        CONFIG_AAC_ENCODER CONFIG_H264_VIDEOTOOLBOX_ENCODER CONFIG_VP9_VIDEOTOOLBOX_HWACCEL CONFIG_DCA_DECODER; do
        grep -q "^#define $required 1" "$build/config_components.h" || { echo "error: $required is off in $1" >&2; exit 1; }
    done

    log "Building $1"
    make -C "$build" -j"$JOBS" > "$build/make.out" 2>&1 || { tail -n 40 "$build/make.out" >&2; exit 1; }
    make -C "$build" install > "$build/install.out" 2>&1

    # One dylib for the five libraries. Only the public API is exported (the av_, avio_, avcodec_,
    # avformat_, avutil_, avsubtitle_, swr_ and sws_ prefixes; not the internal avpriv_ and ff_
    # functions), so the linker strips every internal function the enabled components never reach.
    if [ "$PLATFORM" = macos ]; then
        install_name=@rpath/FFmpeg.framework/Versions/A/FFmpeg
    else
        install_name=@rpath/FFmpeg.framework/FFmpeg
    fi
    printf '%s\n' '_av_*' '_avio_*' '_avcodec_*' '_avformat_*' '_avutil_*' '_avsubtitle_*' '_swr_*' '_swresample_*' '_sws_*' '_swscale_*' > "$build/exports.txt"
    # System libraries the static libraries need, from their pkg-config files ("-framework X" stays
    # one word pair, duplicates are dropped).
    extra_libs=$(sed -n 's/^Libs: //p' "$prefix/lib/pkgconfig/libavformat.pc" "$prefix/lib/pkgconfig/libavcodec.pc" "$prefix/lib/pkgconfig/libavutil.pc" \
        "$prefix/lib/pkgconfig/libswscale.pc" "$prefix/lib/pkgconfig/libswresample.pc" \
        | awk '{ for (i = 1; i <= NF; i++) { w = $i; if (w == "-framework") { w = w " " $(++i) }
                 if (w ~ /^-L/ || w ~ /^-lav/ || w ~ /^-lsw/ || seen[w]++) continue; printf "%s ", w } }')
    # shellcheck disable=SC2086 # extra_libs is a list of linker words.
    "$cc" -target "$TRIPLE" -isysroot "$sysroot" -dynamiclib \
        -install_name "$install_name" \
        -compatibility_version 9.0.0 -current_version "$FFMPEG_VERSION" \
        -Wl,-all_load "$prefix/lib/libavformat.a" "$prefix/lib/libavcodec.a" "$prefix/lib/libswscale.a" "$prefix/lib/libswresample.a" \
        "$prefix/lib/libavutil.a" \
        -Wl,-exported_symbols_list,"$build/exports.txt" -Wl,-dead_strip -Wl,-dead_strip_dylibs -Wl,-x \
        $extra_libs -o "$build/FFmpeg"
}

# MARK: - Frameworks

write_info_plist() { # path platform-name min-os-key min-os
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>FFmpeg</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>FFmpeg</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$FRAMEWORK_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$FRAMEWORK_VERSION</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$2</string>
	</array>
	<key>$3</key>
	<string>$4</string>
	<key>NSHumanReadableCopyright</key>
	<string>FFmpeg $FFMPEG_VERSION, LGPL v2.1 or later. https://ffmpeg.org</string>
</dict>
</plist>
EOF
}

# Creates the framework of a platform from the dylibs of its slices.
make_framework() { # platform
    dir=$WORK/frameworks/$1/FFmpeg.framework
    rm -rf "$WORK/frameworks/$1"
    binaries=""
    for slice in $SLICES; do
        slice_info "$slice"
        [ "$PLATFORM" = "$1" ] && binaries="$binaries $WORK/build/$slice/FFmpeg"
    done
    [ -n "$binaries" ] || return 0

    case "$1" in
        macos)
            mkdir -p "$dir/Versions/A/Resources"
            # shellcheck disable=SC2086
            lipo -create $binaries -output "$dir/Versions/A/FFmpeg"
            write_info_plist "$dir/Versions/A/Resources/Info.plist" MacOSX LSMinimumSystemVersion "$MACOS_MIN"
            cp "$SRC/COPYING.LGPLv2.1" "$dir/Versions/A/Resources/LICENSE"
            ln -s A "$dir/Versions/Current"
            ln -s Versions/Current/FFmpeg "$dir/FFmpeg"
            ln -s Versions/Current/Resources "$dir/Resources"
            ;;
        ios | iossim)
            mkdir -p "$dir"
            # shellcheck disable=SC2086
            lipo -create $binaries -output "$dir/FFmpeg"
            if [ "$1" = ios ]; then platform_name=iPhoneOS; else platform_name=iPhoneSimulator; fi
            write_info_plist "$dir/Info.plist" "$platform_name" MinimumOSVersion "$IOS_MIN"
            cp "$SRC/COPYING.LGPLv2.1" "$dir/LICENSE"
            ;;
    esac
    # Ad-hoc signature so that the binaries load as they are (smoke tests, the simulator); Xcode
    # signs them again with the app's identity when it embeds them.
    codesign --force --sign - --timestamp=none "$dir" > /dev/null
    FRAMEWORK_ARGS="$FRAMEWORK_ARGS -framework $dir"
}

# MARK: - Main

fetch_source
for slice in $SLICES; do
    build_slice "$slice"
done

log "Checking that every slice has the same public headers"
first=""
for slice in $SLICES; do
    if [ -z "$first" ]; then
        first=$slice
    else
        diff -r "$WORK/install/$first/include" "$WORK/install/$slice/include" > /dev/null || {
            echo "error: public headers of $slice differ from $first" >&2
            exit 1
        }
    fi
done

log "Creating FFmpeg.xcframework"
FRAMEWORK_ARGS=""
for platform in ios iossim macos; do
    make_framework "$platform"
done
rm -rf "$OUT/FFmpeg.xcframework" "$OUT/include"
mkdir -p "$OUT"
# shellcheck disable=SC2086
xcodebuild -create-xcframework $FRAMEWORK_ARGS -output "$OUT/FFmpeg.xcframework" > /dev/null
cp -R "$WORK/install/$first/include" "$OUT/include"
cp "$SRC/COPYING.LGPLv2.1" "$OUT/LICENSE"

{
    echo "FFmpeg $FFMPEG_VERSION (https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz)"
    echo "SHA-256: $FFMPEG_SHA256"
    echo "License: LGPL v2.1 or later (no GPL, version3 or nonfree components)"
    echo "Built by: Tools/FFmpeg/build-xcframework.sh with $(xcodebuild -version | tr '\n' ' ')"
    echo "Slices: $SLICES (iOS $IOS_MIN, macOS $MACOS_MIN)"
    echo
    echo "Configure flags (plus per-slice toolchain flags):"
    echo "$CONFIGURE_FLAGS" | tr ' ' '\n' | grep -v '^$' | sed 's/^/  /'
} > "$OUT/BUILD_INFO.txt"

log "Done"
du -sh "$OUT/FFmpeg.xcframework"
find "$OUT/FFmpeg.xcframework" -name FFmpeg -type f -exec lipo -info {} \;
