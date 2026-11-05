#!/bin/sh
# Format matrix, macOS: plays one test file for every common container / video codec / audio codec combination
# the way the app does (VODCheck: PlaybackRoute, AVPlayer directly or through the remux engine with its
# converter, the loopback server) and checks each: playback starts with real video frames (not black) and audio
# (an enabled audio track; for the engine, sound in its segments), seeking works (skip, scrub, skip back), and it
# resumes at a saved position. The media are generated with ffmpeg (Tools/FFmpeg/env.sh) and served on 127.0.0.1
# only (vod_server.py); VC-1 and Theora, which ffmpeg cannot encode, come from FFmpeg's public sample files
# (samples.ffmpeg.org) when SAMPLES points to a folder with them (see fetch_samples).
#
#   Tools/EngineSmokeTest/run_formats.sh                 every case
#   Tools/EngineSmokeTest/run_formats.sh mkv dts         cases whose name contains one of the words
#   IPHONE=1 Tools/EngineSmokeTest/run_formats.sh        decides like an iPhone (FLUXO_NATIVE_CODECS=0: MPEG-2
#                                                        video, MP2 audio and 10-bit H.264 are converted, AV1 is not
#                                                        decoded)
#   MEDIA_ONLY=1 Tools/EngineSmokeTest/run_formats.sh    only generates the media (for Tools/Simulator/format-matrix.sh)
#
# The summary lists, for every case, the route (direct: AVPlayer; remux: the engine), the formats AVPlayer
# decodes (video / audio four-character codes: converted streams show as avc1 / aac) and the result.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/Tools/FFmpeg/env.sh"
PORT=${PORT:-18940}
CHECK_PORT=${CHECK_PORT:-19333}
MEDIA=${MEDIA:-/tmp/fluxo-format-media}
WORK=${WORK:-/tmp/fluxo-format-check}
SAMPLES=${SAMPLES:-/tmp/fluxo-format-samples}
D=${DURATION:-120}
mkdir -p "$MEDIA" "$WORK"
if [ "${IPHONE:-0}" = 1 ]; then
    export FLUXO_NATIVE_CODECS=0
fi
export FFMPEG

# MARK: Media
q="-hide_banner -loglevel error -y -nostdin"
gen() { # name args...: writes $MEDIA/<name> unless it exists
    out=$MEDIA/$1
    shift
    [ -f "$out" ] && return 0
    echo "[formats] generating $(basename "$out")"
    # shellcheck disable=SC2086
    "$FFMPEG" $q "$@" "$out.part.$(echo "$out" | sed 's/.*\.//')" && mv "$out.part.$(echo "$out" | sed 's/.*\.//')" "$out"
}

make_media() {
    V="-f lavfi -i testsrc=size=640x360:rate=25:duration=$D"
    V576="-f lavfi -i testsrc=size=720x576:rate=25:duration=$D"
    A="-f lavfi -i sine=frequency=440:sample_rate=48000:duration=$D"
    H264="-c:v libx264 -preset veryfast -g 50 -keyint_min 25 -b:v 800k -pix_fmt yuv420p"
    HEVC="-c:v libx265 -preset ultrafast -x265-params keyint=60:min-keyint=24:log-level=error -b:v 600k -pix_fmt yuv420p"
    AAC="-c:a aac -b:a 128k"
    SIX="-ac 6"
    # shellcheck disable=SC2086
    {
    # MP4 / M4V / MOV / 3GP (AVPlayer plays them directly; what it cannot decode moves to the engine).
    gen mp4-h264-aac.mp4 $V $A $H264 $AAC -movflags +faststart
    gen m4v-h264-aac.m4v $V $A $H264 $AAC -f mp4
    gen mov-h264-alac.mov $V $A $H264 -c:a alac
    gen mov-mpeg4-aac.mov $V $A -c:v mpeg4 -vtag mp4v -qscale:v 4 -bf 2 -g 50 $AAC
    # MPEG-4 Part 2 Simple Profile (no B-frames) at SD: iPhone and iPad decode it, so it plays directly there too.
    gen mp4-mpeg4sp-aac.mp4 $V $A -c:v mpeg4 -vtag mp4v -qscale:v 4 -bf 0 -g 50 $AAC
    gen mp4-h264-ac3.mp4 $V $A $H264 -c:a ac3 -b:a 192k
    gen mp4-hevc-eac3.mp4 $V $A $HEVC -tag:v hvc1 -c:a eac3 -b:a 192k
    gen mp4-hev1-aac.mp4 $V $A $HEVC -tag:v hev1 $AAC
    gen mp4-h264-dts.mp4 $V $A $H264 -c:a dca -strict -2 $SIX -b:a 768k
    gen mp4-h264-opus.mp4 $V $A $H264 -c:a libopus -b:a 96k
    gen mp4-h264-flac.mp4 $V $A $H264 -c:a flac
    gen 3gp-h263-aac.3gp -f lavfi -i "testsrc=size=352x288:rate=25:duration=$D" $A -c:v h263 -b:v 600k -g 50 -c:a aac -b:a 64k -ac 1 -ar 22050
    # Matroska: every audio codec of web and disc releases, H.264 8 / 10-bit, HEVC (HDR10), AV1, VP9, MPEG-2, MPEG-4.
    gen mkv-h264-aac.mkv $V $A $H264 $AAC
    gen mkv-h264-ac3.mkv $V $A $H264 -c:a ac3 $SIX -b:a 384k
    gen mkv-h264-eac3.mkv $V $A $H264 -c:a eac3 $SIX -b:a 384k
    gen mkv-h264-dts.mkv $V $A $H264 -c:a dca -strict -2 $SIX -b:a 768k
    gen mkv-hevc-dts.mkv $V $A $HEVC -c:a dca -strict -2 $SIX -b:a 768k
    gen mkv-h264-truehd.mkv $V $A $H264 -c:a truehd -strict -2 -ac 2
    gen mkv-h264-flac.mkv $V $A $H264 -c:a flac
    gen mkv-h264-opus.mkv $V $A $H264 -c:a libopus -b:a 96k
    gen mkv-h264-vorbis.mkv $V $A $H264 -c:a vorbis -strict -2 -ac 2
    gen mkv-h264-pcm.mkv $V $A $H264 -c:a pcm_s16le
    gen mkv-h264-mp2.mkv $V $A $H264 -c:a mp2 -b:a 192k
    gen mkv-h264-alac.mkv $V $A $H264 -c:a alac
    gen mkv-h26410-aac.mkv $V $A -c:v libx264 -preset veryfast -g 50 -b:v 800k -pix_fmt yuv420p10le -profile:v high10 $AAC
    gen mkv-hevc10-hdr10-eac3.mkv $V $A -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -b:v 800k \
        -x265-params "keyint=50:log-level=error:hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
        -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -c:a eac3 -b:a 192k
    gen mkv-av1-opus.mkv $V $A -c:v libsvtav1 -preset 10 -g 50 -svtav1-params "lp=2" -c:a libopus -b:a 96k
    gen mkv-vp9-opus.mkv $V $A -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 800k -g 50 -c:a libopus -b:a 96k
    gen mkv-mpeg2-ac3.mkv $V576 $A -c:v mpeg2video -b:v 3M -g 12 -c:a ac3 -b:a 192k
    gen mkv-xvid-mp3.mkv $V $A -c:v mpeg4 -vtag xvid -qscale:v 4 -bf 2 -g 250 -c:a libmp3lame -b:a 128k
    # WebM.
    gen webm-vp9-opus.webm $V $A -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 800k -g 50 -c:a libopus -b:a 96k
    gen webm-vp8-vorbis.webm $V $A -c:v libvpx -deadline realtime -cpu-used 8 -b:v 800k -g 50 -c:a vorbis -strict -2 -ac 2
    gen webm-av1-opus.webm $V $A -c:v libsvtav1 -preset 10 -g 50 -svtav1-params "lp=2" -c:a libopus -b:a 96k
    # AVI: Xvid / DivX 3 / H.264 / Motion JPEG.
    gen avi-xvid-mp3.avi $V $A -c:v mpeg4 -vtag XVID -qscale:v 4 -bf 2 -g 250 -c:a libmp3lame -b:a 128k
    gen avi-divx3-mp3.avi $V $A -c:v msmpeg4 -vtag DIV3 -b:v 1200k -g 50 -c:a libmp3lame -b:a 128k
    gen avi-h264-ac3.avi $V $A $H264 -c:a ac3 -b:a 192k
    gen avi-mjpeg-pcm.avi $V $A -c:v mjpeg -q:v 6 -c:a pcm_s16le
    # MPEG transport streams: IPTV (H.264 / AAC, LATM), DVB SD (MPEG-2 / MP2, interlaced), Blu-ray M2TS (DTS, TrueHD).
    gen ts-h264-aac.ts $V $A $H264 $AAC -f mpegts
    gen ts-h264-latm.ts $V $A $H264 $AAC -mpegts_flags latm -f mpegts
    gen ts-mpeg2-mp2.ts $V576 $A -c:v mpeg2video -b:v 3M -g 12 -c:a mp2 -b:a 192k -f mpegts
    gen ts-mpeg2i-mp2.ts $V576 $A -c:v mpeg2video -b:v 4M -g 12 -flags +ildct+ilme -top 1 -c:a mp2 -b:a 192k -f mpegts
    gen ts-hevc-eac3.ts $V $A $HEVC -c:a eac3 -b:a 192k -f mpegts
    gen m2ts-h264-dts.m2ts $V $A $H264 -c:a dca -strict -2 $SIX -b:a 768k -f mpegts -mpegts_m2ts_mode 1
    gen m2ts-h264-truehd.m2ts $V $A $H264 -c:a truehd -strict -2 -ac 2 -f mpegts -mpegts_m2ts_mode 1
    gen mts-h264-ac3.mts $V $A $H264 -c:a ac3 -b:a 192k -f mpegts -mpegts_m2ts_mode 1
    # FLV: H.264 / AAC and the old Sorenson Spark / MP3.
    gen flv-h264-aac.flv $V $A $H264 $AAC
    gen flv-flv1-mp3.flv $V $A -c:v flv -b:v 1M -g 50 -c:a libmp3lame -b:a 128k -ar 44100
    # Windows Media (ASF).
    gen wmv-wmv2-wma2.wmv $V $A -c:v wmv2 -b:v 1500k -g 50 -c:a wmav2 -b:a 128k
    # MPEG program streams (DVD).
    gen mpg-mpeg2-mp2.mpg $V576 $A -c:v mpeg2video -b:v 3M -g 12 -c:a mp2 -b:a 192k -f mpeg
    gen vob-mpeg2-ac3.vob $V576 $A -c:v mpeg2video -b:v 4M -g 12 -c:a ac3 -b:a 192k -f vob
    # Ogg / Opus audio only.
    gen ogg-vorbis.ogg $A -c:a vorbis -strict -2 -ac 2
    gen opus-audio.opus $A -c:a libopus -b:a 96k
    # Several audio tracks (DTS default, AC-3) and text subtitles (SubRip, ASS) in Matroska.
    if [ ! -f "$MEDIA/mkv-tracks-dts-ac3-srt-ass.mkv" ]; then
        : > "$WORK/cues.srt"
        n=1
        t=5
        while [ "$t" -lt "$D" ]; do
            printf '%d\n%02d:%02d:%02d,000 --> %02d:%02d:%02d,000\nCue at %d s\n\n' "$n" $((t / 3600)) $((t / 60 % 60)) $((t % 60)) \
                $(((t + 4) / 3600)) $(((t + 4) / 60 % 60)) $(((t + 4) % 60)) "$t" >> "$WORK/cues.srt"
            n=$((n + 1))
            t=$((t + 10))
        done
        gen mkv-tracks-dts-ac3-srt-ass.mkv $V $A -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=$D" -i "$WORK/cues.srt" -i "$WORK/cues.srt" \
            -map 0:v -map 1:a -map 2:a -map 3 -map 4 $H264 -c:a:0 dca -strict -2 -ac:a:0 6 -b:a:0 768k -c:a:1 ac3 -b:a:1 192k -c:s:0 srt -c:s:1 ass \
            -metadata:s:a:0 language=eng -metadata:s:a:1 language=ita -metadata:s:s:0 language=eng -metadata:s:s:1 language=ita \
            -disposition:a:0 default -disposition:a:1 0 -disposition:s:0 0 -disposition:s:1 0
    fi
    # HLS (AVPlayer).
    if [ ! -f "$MEDIA/hls/index.m3u8" ]; then
        mkdir -p "$MEDIA/hls"
        "$FFMPEG" $q -i "$MEDIA/ts-h264-aac.ts" -c copy -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_filename "$MEDIA/hls/seg-%04d.ts" "$MEDIA/hls/index.m3u8"
    fi
    }
    # Xtream Codes ids (extensionless, .ts) for some of them.
    ln -sf mkv-h264-dts.mkv "$MEDIA/4001.mkv"
    ln -sf avi-xvid-mp3.avi "$MEDIA/4002.avi"
    ln -sf ts-mpeg2-mp2.ts "$MEDIA/4003.ts"
    # Downloaded samples: VC-1 (ASF; interlaced 1080i with DTS 5.1 in M2TS, as on Blu-ray) and Theora / Vorbis (Ogg).
    for sample in Test_1440x576_WVC1_6Mbps.wmv vc1-interlaced-bframes.m2ts Sahara.ogg; do
        found=$(find "$SAMPLES" -name "$sample" -type f 2>/dev/null | head -n 1 || true)
        [ -n "$found" ] && ln -sf "$found" "$MEDIA/sample-$sample"
    done
    return 0
}

# FFmpeg's public sample files (https://samples.ffmpeg.org) for what ffmpeg cannot encode. Each in a folder of its own.
fetch_samples() {
    for path in V-codecs/WVC1/Test_1440x576_WVC1_6Mbps.wmv V-codecs/WVC1/vc1-interlaced-bframes.m2ts V-codecs/Theora/Sahara.ogg; do
        name=$(basename "$path")
        dir=$SAMPLES/$(echo "$name" | tr '.' '_')
        [ -f "$dir/$name" ] && continue
        mkdir -p "$dir"
        curl --fail --silent --location --proto '=https' --max-time 300 -o "$dir/$name" "https://samples.ffmpeg.org/$path" || rm -f "$dir/$name"
    done
}

# MARK: Run
. "$ROOT/Tools/EngineSmokeTest/vodcheck.sh"

cleanup() {
    # (Never "kill 0": that is the whole process group.)
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

[ "${FETCH:-1}" = 1 ] && fetch_samples
make_media
# MEDIA_ONLY=1: only the media (Tools/Simulator/format-matrix.sh plays them in the app).
[ "${MEDIA_ONLY:-0}" = 1 ] && exit 0
build_check

python3 -I "$ROOT/Tools/EngineSmokeTest/vod_server.py" --root "$MEDIA" --port "$PORT" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | grep -q "127.0.0.1:$PORT" || { echo "error: the media server is not listening on 127.0.0.1:$PORT" >&2; exit 1; }

B=http://127.0.0.1:$PORT
M=$B/movie/user/pass
# name|url|kind|scenario|expects (a: audio, v: video)
CASES="
mp4-h264-aac|$M/mp4-h264-aac.mp4|movie|quick|av
m4v-h264-aac|$M/m4v-h264-aac.m4v|movie|quick|av
mov-h264-alac|$M/mov-h264-alac.mov|movie|quick|av
mov-mpeg4-aac|$M/mov-mpeg4-aac.mov|movie|quick|av
mp4-mpeg4sp-aac|$M/mp4-mpeg4sp-aac.mp4|movie|quick|av
mp4-h264-ac3|$M/mp4-h264-ac3.mp4|movie|quick|av
mp4-hevc-eac3|$M/mp4-hevc-eac3.mp4|movie|quick|av
mp4-hev1-aac|$M/mp4-hev1-aac.mp4|movie|quick|av
mp4-h264-dts|$M/mp4-h264-dts.mp4|movie|quick|av
mp4-h264-opus|$M/mp4-h264-opus.mp4|movie|quick|av
mp4-h264-flac|$M/mp4-h264-flac.mp4|movie|quick|av
3gp-h263-aac|$M/3gp-h263-aac.3gp|movie|quick|av
mkv-h264-aac|$M/mkv-h264-aac.mkv|movie|quick|av
mkv-h264-ac3|$M/mkv-h264-ac3.mkv|movie|quick|av
mkv-h264-eac3|$M/mkv-h264-eac3.mkv|movie|quick|av
mkv-h264-dts|$M/mkv-h264-dts.mkv|movie|quick|av
mkv-hevc-dts|$B/series/user/pass/mkv-hevc-dts.mkv|series|quick|av
mkv-h264-truehd|$M/mkv-h264-truehd.mkv|movie|quick|av
mkv-h264-flac|$M/mkv-h264-flac.mkv|movie|quick|av
mkv-h264-opus|$M/mkv-h264-opus.mkv|movie|quick|av
mkv-h264-vorbis|$M/mkv-h264-vorbis.mkv|movie|quick|av
mkv-h264-pcm|$M/mkv-h264-pcm.mkv|movie|quick|av
mkv-h264-mp2|$M/mkv-h264-mp2.mkv|movie|quick|av
mkv-h264-alac|$M/mkv-h264-alac.mkv|movie|quick|av
mkv-h26410-aac|$M/mkv-h26410-aac.mkv|movie|quick|av
mkv-hevc10-hdr10-eac3|$M/mkv-hevc10-hdr10-eac3.mkv|movie|quick|av
mkv-av1-opus|$M/mkv-av1-opus.mkv|movie|quick|av
mkv-vp9-opus|$M/mkv-vp9-opus.mkv|movie|quick|av
mkv-mpeg2-ac3|$M/mkv-mpeg2-ac3.mkv|movie|quick|av
mkv-xvid-mp3|$M/mkv-xvid-mp3.mkv|movie|quick|av
mkv-tracks-dts-ac3-srt-ass|$M/mkv-tracks-dts-ac3-srt-ass.mkv|movie|quick|av
webm-vp9-opus|$M/webm-vp9-opus.webm|movie|quick|av
webm-vp8-vorbis|$M/webm-vp8-vorbis.webm|movie|quick|av
webm-av1-opus|$M/webm-av1-opus.webm|movie|quick|av
avi-xvid-mp3|$M/avi-xvid-mp3.avi|movie|quick|av
avi-divx3-mp3|$M/avi-divx3-mp3.avi|movie|quick|av
avi-h264-ac3|$M/avi-h264-ac3.avi|movie|quick|av
avi-mjpeg-pcm|$M/avi-mjpeg-pcm.avi|movie|quick|av
ts-h264-aac|$M/ts-h264-aac.ts|movie|quick|av
ts-h264-latm|$M/ts-h264-latm.ts|movie|quick|av
ts-mpeg2-mp2|$M/ts-mpeg2-mp2.ts|movie|quick|av
ts-mpeg2i-mp2|$M/ts-mpeg2i-mp2.ts|movie|quick|av
ts-hevc-eac3|$M/ts-hevc-eac3.ts|movie|quick|av
m2ts-h264-dts|$M/m2ts-h264-dts.m2ts|movie|quick|av
m2ts-h264-truehd|$M/m2ts-h264-truehd.m2ts|movie|quick|av
mts-h264-ac3|$M/mts-h264-ac3.mts|movie|quick|av
flv-h264-aac|$M/flv-h264-aac.flv|movie|quick|av
flv-flv1-mp3|$M/flv-flv1-mp3.flv|movie|quick|av
wmv-wmv2-wma2|$M/wmv-wmv2-wma2.wmv|movie|quick|av
mpg-mpeg2-mp2|$M/mpg-mpeg2-mp2.mpg|movie|quick|av
vob-mpeg2-ac3|$M/vob-mpeg2-ac3.vob|movie|quick|av
ogg-vorbis|$M/ogg-vorbis.ogg|movie|quick|a
opus-audio|$M/opus-audio.opus|movie|quick|a
hls-h264-aac|$B/hls/index.m3u8|movie|quick|av
xtream-extensionless-dts|$M/4001|movie|quick|av
xtream-avi|$M/4002.avi|movie|quick|av
php-xvid|$B/play.php?stream=avi-xvid-mp3.avi|movie|quick|av
sample-wmv-vc1|$M/sample-Test_1440x576_WVC1_6Mbps.wmv|movie|quick|v
sample-m2ts-vc1i-dts|$M/sample-vc1-interlaced-bframes.m2ts|movie|short|av
sample-ogv-theora-vorbis|$M/sample-Sahara.ogg|movie|short|av
live-ts-mpeg2-mp2|$B/slow/440/live/user/pass/ts-mpeg2-mp2.ts|live|live|av
live-ts-h264-latm|$B/slow/130/live/user/pass/ts-h264-latm.ts|live|live|av
live-ts-h264-aac|$B/slow/130/live/user/pass/ts-h264-aac.ts|live|live|av
"
passed=0
failed=0
skipped=0
summary=""
for line in $CASES; do
    name=$(echo "$line" | cut -d'|' -f1)
    url=$(echo "$line" | cut -d'|' -f2)
    kind=$(echo "$line" | cut -d'|' -f3)
    scenario=$(echo "$line" | cut -d'|' -f4)
    expects=$(echo "$line" | cut -d'|' -f5)
    if [ $# -gt 0 ]; then
        match=0
        for word in "$@"; do
            case $name in *"$word"*) match=1 ;; esac
        done
        [ $match -eq 1 ] || continue
    fi
    file=$(echo "$url" | sed -e 's|.*/||' -e 's|.*stream=||')
    case $name in
        hls-*) ;;
        *) if [ ! -e "$MEDIA/$file" ] && ! ls "$MEDIA/$file".* > /dev/null 2>&1; then
               skipped=$((skipped + 1))
               summary="$summary
SKIP $name (no media)"
               continue
           fi ;;
    esac
    echo "=== $name ($kind) $url"
    case $expects in *a*) ea=1 ;; *) ea=0 ;; esac
    case $expects in *v*) ev=1 ;; *) ev=0 ;; esac
    # The Blu-ray sample is a night sky: any frame counts.
    case $name in sample-m2ts-*) brightness=1 ;; *) brightness=20 ;; esac
    if SCENARIO=$scenario EXPECT_AUDIO=$ea EXPECT_VIDEO=$ev MIN_BRIGHTNESS=$brightness "$CHECK" "$url" "$kind" > "$WORK/$name.log" 2>&1; then
        passed=$((passed + 1))
        result=PASS
    else
        failed=$((failed + 1))
        result=FAIL
    fi
    grep -E '^\[check\] (route|formats|master|tracks|AVPlayer cannot|.*=> |result)' "$WORK/$name.log" | sed 's/^/    /'
    route=$(sed -n 's/^\[check\] result [A-Z]* route=\([^ ]*\).*/\1/p' "$WORK/$name.log" | tail -n 1)
    formats=$(sed -n 's/^\[check\] formats \(.*\) segment-audio.*/\1/p' "$WORK/$name.log" | head -n 1)
    summary="$summary
$result $name route=$route $formats"
done
echo "--- summary (logs in $WORK)$summary"
echo "passed=$passed failed=$failed skipped=$skipped"
[ "$failed" -eq 0 ]
