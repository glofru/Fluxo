//
//  FluxoTranscoder.h
//  Fluxo
//
//  Internal to the remux engine (FluxoRemuxEngine.c and the FluxoEngine*.c files); not exposed to Swift. Implemented by
//  FluxoTranscoder.c, FluxoTranscoderVideo.c and FluxoTranscoderAudio.c.
//
//  The engine copies the packets of the input when AVPlayer decodes their codec from HLS: H.264, HEVC and
//  (on devices with an AV1 decoder) AV1 video; AAC, AC-3, E-AC-3 and MP3 audio. Every other stream it can
//  decode is converted while it is read, so that what reaches the muxers is always playable:
//  - audio (DTS, Dolby TrueHD, FLAC, ALAC, Opus, Vorbis, MP2, PCM, WMA, AMR, ...) to AAC-LC, with FFmpeg's
//    own decoders and AAC encoder (at most 5.1 channels, at most 48 kHz);
//  - video (MPEG-2, MPEG-4 Part 2 / Xvid / DivX, VC-1 / WMV, VP8, VP9, Theora, Motion JPEG, and H.264 in the
//    profiles the system cannot decode, such as High 10) to 8-bit H.264 with VideoToolbox's (hardware) encoder,
//    VP9 decoded by VideoToolbox when the device can. Interlaced pictures are deinterlaced (a vertical blend).
//
//  The converted packets keep the stream's index and time base, and the timeline of the input: the rest of the
//  engine sees an input whose streams have other codec parameters (fluxo_stream_parameters). Key frames of
//  converted video are placed where the engine cuts segments (fluxo_streams_set_key_times), or at a regular
//  interval, so every segment starts with one.
//

#ifndef FLUXO_TRANSCODER_H
#define FLUXO_TRANSCODER_H

#include <stdint.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-html"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#pragma clang diagnostic pop

/// The input has video in a format that can neither be copied nor converted (see FluxoStreams.unsupported_codec).
#define FLUXO_ERROR_UNSUPPORTED_VIDEO FFERRTAG('F', 'X', 'U', 'V')
/// The input has audio only, in a format that can neither be copied nor converted.
#define FLUXO_ERROR_UNSUPPORTED_AUDIO FFERRTAG('F', 'X', 'U', 'A')
/// A conversion that keeps every picture (FluxoStreamsOptions.complete) found no video encoder for a few seconds
/// (VideoToolbox refuses to encode while the app is in the background). Same value as
/// FLUXO_REMUX_ERROR_ENCODER_UNAVAILABLE.
#define FLUXO_ERROR_ENCODER_UNAVAILABLE FFERRTAG('F', 'X', 'E', 'V')

typedef struct FluxoTranscoder FluxoTranscoder;

typedef struct FluxoStreamsOptions {
    /// Live input: converted video gets a key frame every `key_interval` seconds.
    int is_live;
    /// The output stores codec parameters in its header (MP4 files): converted video gets global extradata.
    int global_header;
    /// Seconds between the key frames of converted video when no key times are set.
    double key_interval;
    /// Every picture must be converted (a file conversion): when the video encoder is refused, the converter waits
    /// a few seconds for a new one, then fails with FLUXO_ERROR_ENCODER_UNAVAILABLE instead of leaving pictures out.
    int complete;
} FluxoStreamsOptions;

/// The streams of an input as the engine reads them: copied, converted or left out.
/// `input->opaque` points to it while it is open.
typedef struct FluxoStreams {
    AVFormatContext *input;
    /// One per input stream; NULL for streams that are copied (or left out).
    FluxoTranscoder **transcoders;
    unsigned int count;
    /// The input ended (or failed) and the converters are being drained; then `pending_error` is returned.
    int draining;
    int pending_error;
    /// Name of the codec of an unsupported video (FLUXO_ERROR_UNSUPPORTED_VIDEO / _AUDIO).
    char unsupported_codec[64];
    /// When set (after fluxo_streams_open), called with every packet read from the input before it is converted
    /// or returned: the engine moves the input's timestamps to its own timeline there (offset, MPEG-TS
    /// discontinuities), in the order the input gives them. Converted streams come out later than copied ones (the
    /// decoder and encoder hold some frames), so done on their output a timestamp jump would be seen at different
    /// moments on each stream.
    void (*adjust)(void *opaque, AVPacket *packet, const AVStream *stream);
    void *adjust_opaque;
} FluxoStreams;

/// Process-wide: what this device decodes from HLS besides the codecs every Apple device decodes. Read once.
uint32_t fluxo_native_codecs(void);
#define FLUXO_NATIVE_AV1 (1u << 0)
#define FLUXO_NATIVE_MPEG2_VIDEO (1u << 1)
#define FLUXO_NATIVE_H264_HIGH_BIT_DEPTH (1u << 2)
#define FLUXO_NATIVE_MP2_AUDIO (1u << 3)

/// Decides what happens to every stream of `input` (opened and probed) and creates the converters. Streams that
/// are left out are discarded (AVDISCARD_ALL). Returns FLUXO_ERROR_UNSUPPORTED_VIDEO when the input has video and
/// none of it can be played, FLUXO_ERROR_UNSUPPORTED_AUDIO when it has audio only and none of it can be played,
/// another negative error on failure, 0 otherwise.
int fluxo_streams_open(FluxoStreams *streams, AVFormatContext *input, const FluxoStreamsOptions *options);

/// Frees the converters. The input itself is not closed.
void fluxo_streams_close(FluxoStreams *streams);

/// Reads the next packet of the input: copied streams' packets as they are, converted streams' packets once
/// converted (same stream index, the stream's time base). At the end of the input the converters are drained
/// before the read error is returned. Like av_read_frame.
int fluxo_streams_read(FluxoStreams *streams, AVPacket *packet);

/// Drops what the converters hold: the input was repositioned (a seek).
void fluxo_streams_reset(FluxoStreams *streams);

/// Times (AV_TIME_BASE units, the input timeline, ascending) where converted video must have a key frame: the
/// first picture at or after each gets one. The array is not copied and must outlive the streams (or be replaced).
void fluxo_streams_set_key_times(FluxoStreams *streams, const int64_t *times, int count);

/// The codec parameters of stream `index` as the engine outputs it (the converter's for converted streams).
const AVCodecParameters *fluxo_stream_parameters(const AVFormatContext *input, unsigned int index);

/// Whether stream `index` of `input` is converted.
int fluxo_stream_is_converted(const AVFormatContext *input, unsigned int index);

/// Whether converted video currently produces nothing because its encoder is refused (VideoToolbox invalidates
/// encoding sessions while the app is in the background, e.g. in Picture in Picture). Segments are then cut on the
/// audio so that it keeps playing; the picture comes back with a key frame once an encoder opens again.
int fluxo_streams_video_stalled(const FluxoStreams *streams);

#endif /* FLUXO_TRANSCODER_H */
