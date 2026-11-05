//
//  FluxoTranscoder.c
//  Fluxo
//
//  Converts the streams of an input that AVPlayer cannot decode from HLS (see FluxoTranscoder.h), with the
//  public libavcodec / libswscale / libswresample API of the bundled FFmpeg and VideoToolbox. Runs on the
//  engine thread (or the thread of fluxo_remux_convert_file) only.
//
//  Battery: audio conversion costs little (one decoder and an AAC encoder at the speed of the input). Video
//  conversion decodes in software (VP9 in hardware where the device can) and encodes with the hardware H.264
//  encoder in its power-efficient mode; on-demand inputs are read in bursts (the engine's read-ahead), so the
//  processors rest between them.
//

#include "FluxoTranscoder.h"

#include <TargetConditionals.h>
#include <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-html"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#include <libavcodec/bsf.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/hwcontext.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#pragma clang diagnostic pop

// Most audio streams of one input that are converted (each costs a decoder and an encoder while the input plays).
#define FLUXO_MAX_CONVERTED_AUDIO 4
// A converted audio stream whose input timestamps move this far from the samples produced so far starts again
// at the new time (a cut in a live stream, a damaged file).
#define FLUXO_AUDIO_RESYNC (AV_TIME_BASE / 5)
// Two key times this close are one (index and picture times are rescaled from the same time base).
#define FLUXO_KEY_EPSILON 1000
// Consecutive frames the video encoder may refuse before it is opened again (VideoToolbox invalidates its
// sessions when the app moves between the foreground and the background).
#define FLUXO_ENCODER_RETRIES 3
// A file conversion (FluxoStreamsOptions.complete) tries this many times, this far apart, to open a video encoder
// that is refused before it gives up (it then runs again later).
#define FLUXO_ENCODER_WAITS 20
#define FLUXO_ENCODER_WAIT_US 250000
// A picture whose time is this far behind the previous one's is a timestamp restart (a live source that starts
// its clock again, a restreamer that switches source, a spliced programme), not reordering jitter.
#define FLUXO_VIDEO_RESYNC (AV_TIME_BASE / 10)

typedef enum FluxoAction {
    FluxoActionCopy = 0,
    FluxoActionConvert = 1,
    FluxoActionDrop = 2,
} FluxoAction;

// Packets produced by a converter, waiting to be read.
typedef struct FluxoPacketQueue {
    AVPacket **items;
    int head;
    int count;
    int capacity;
} FluxoPacketQueue;

struct FluxoTranscoder {
    enum AVMediaType type;
    // Time base of the input stream: converted packets use it too.
    AVRational time_base;
    FluxoStreamsOptions options;
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    // The encoder received something since it was opened (a reset must open a fresh one).
    int encoder_used;
    // Codec parameters of the converted stream.
    AVCodecParameters *parameters;
    AVFrame *frame;
    AVFrame *converted;
    AVFrame *software;
    AVPacket *encoded;
    FluxoPacketQueue queue;

    // Video.
    AVBufferRef *hw_device;
    // Pixel aspect ratio of the picture (anamorphic DVD and DVB video), and the filter that writes it into the H.264
    // stream: VideoToolbox gives it to the format description only, which MPEG-TS segments do not carry.
    AVRational aspect;
    AVBSFContext *aspect_filter;
    struct SwsContext *scaler;
    enum AVPixelFormat encoder_format;
    int width;
    int height;
    AVRational frame_rate;
    int64_t bit_rate;
    int64_t last_pts;
    const int64_t *key_times;
    int key_count;
    // Next key time to place (-1: to be found from the next picture's time).
    int key_cursor;
    int64_t key_interval;
    int64_t last_key_time;
    int encoder_failures;
    // Input time (AV_TIME_BASE units) of the latest picture: the test refusals of FLUXO_TEST_REFUSE_ENCODER apply
    // to opening an encoder too, at that time (0 before the first picture).
    int64_t clock;
    uint8_t *line;
    size_t line_size;

    // Audio.
    // Output sample rate and channel layout (the encoder is opened again with them after a reset).
    int audio_rate;
    AVChannelLayout audio_layout;
    struct SwrContext *resampler;
    AVChannelLayout resampler_layout;
    enum AVSampleFormat resampler_format;
    int resampler_rate;
    AVAudioFifo *fifo;
    uint8_t **samples;
    int samples_capacity;
    // Time of the first sample in the FIFO, in 1 / sample rate units; AV_NOPTS_VALUE until the first frame.
    int64_t next_pts;
};

// MARK: - Device capabilities

static pthread_once_t fluxo_native_once = PTHREAD_ONCE_INIT;
static uint32_t fluxo_native_mask;
static int fluxo_force_all;
// Tests: input times (AV_TIME_BASE units) where the video encoder cannot be opened and refuses every picture, as
// VideoToolbox may do in the background.
static int64_t fluxo_refuse_start = AV_NOPTS_VALUE;
static int64_t fluxo_refuse_end = AV_NOPTS_VALUE;

static void fluxo_native_init(void) {
    uint32_t mask = 0;
#if TARGET_OS_OSX
    // The Mac's AVFoundation decodes MPEG-2 video, MP2 audio and 10-bit H.264 from HLS itself (checked on
    // macOS 26); iPhone and iPad do not. VP9 needs the supplemental decoder registered for VideoToolbox to decode it.
    mask |= FLUXO_NATIVE_MPEG2_VIDEO | FLUXO_NATIVE_H264_HIGH_BIT_DEPTH | FLUXO_NATIVE_MP2_AUDIO;
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
#endif
    // AV1 plays from fragmented MP4 HLS on devices with an AV1 decoder (iPhone 15 Pro, M3 and later). FFmpeg here
    // has no software AV1 decoder, so elsewhere AV1 cannot be played.
    if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
        mask |= FLUXO_NATIVE_AV1;
    }
    // Tests: FLUXO_NATIVE_CODECS=<mask> pretends to be another device (0: an iPhone without AV1), and
    // FLUXO_FORCE_TRANSCODE=1 converts every stream that can be decoded.
    const char *override = getenv("FLUXO_NATIVE_CODECS");
    if (override != NULL && override[0] != '\0') {
        mask = (uint32_t)strtoul(override, NULL, 0);
    }
    const char *force = getenv("FLUXO_FORCE_TRANSCODE");
    fluxo_force_all = force != NULL && strcmp(force, "1") == 0;
    // FLUXO_TEST_REFUSE_ENCODER=<start>:<end> (seconds of the input's timeline): the encoder refuses those pictures,
    // and cannot be opened meanwhile (a start of 0 also refuses the first encoder, opened before any picture).
    const char *refuse = getenv("FLUXO_TEST_REFUSE_ENCODER");
    double refuse_start = 0;
    double refuse_end = 0;
    if (refuse != NULL && sscanf(refuse, "%lf:%lf", &refuse_start, &refuse_end) == 2 && refuse_end > refuse_start && refuse_start >= 0) {
        fluxo_refuse_start = (int64_t)(refuse_start * AV_TIME_BASE);
        fluxo_refuse_end = (int64_t)(refuse_end * AV_TIME_BASE);
    }
    fluxo_native_mask = mask;
}

static int fluxo_test_refused(int64_t time) {
    pthread_once(&fluxo_native_once, fluxo_native_init);
    return fluxo_refuse_start != AV_NOPTS_VALUE && time >= fluxo_refuse_start && time < fluxo_refuse_end;
}

uint32_t fluxo_native_codecs(void) {
    pthread_once(&fluxo_native_once, fluxo_native_init);
    return fluxo_native_mask;
}

static int fluxo_force_conversion(void) {
    pthread_once(&fluxo_native_once, fluxo_native_init);
    return fluxo_force_all;
}

// MARK: - Decisions

// H.264 that VideoToolbox decodes: 8-bit 4:2:0 (and 10-bit 4:2:0 on the Mac).
static int fluxo_h264_is_native(const AVCodecParameters *par, uint32_t native) {
    switch (par->profile) {
    case AV_PROFILE_H264_HIGH_422:
    case AV_PROFILE_H264_HIGH_422_INTRA:
    case AV_PROFILE_H264_HIGH_444:
    case AV_PROFILE_H264_HIGH_444_PREDICTIVE:
    case AV_PROFILE_H264_HIGH_444_INTRA:
    case AV_PROFILE_H264_CAVLC_444:
        return 0;
    case AV_PROFILE_H264_HIGH_10:
    case AV_PROFILE_H264_HIGH_10_INTRA:
        return (native & FLUXO_NATIVE_H264_HIGH_BIT_DEPTH) != 0;
    default:
        break;
    }
    const AVPixFmtDescriptor *descriptor = par->format >= 0 ? av_pix_fmt_desc_get((enum AVPixelFormat)par->format) : NULL;
    if (descriptor == NULL) {
        return 1;
    }
    if (descriptor->log2_chroma_w != 1 || descriptor->log2_chroma_h != 1) {
        return 0;
    }
    return descriptor->comp[0].depth <= 8 || (native & FLUXO_NATIVE_H264_HIGH_BIT_DEPTH) != 0;
}

// `no_presentation_times`: the container stores decoding times only (AVI). Video with B-frames then has no
// presentation times to copy (MPEG-TS and MP4 need them); decoding finds them.
static FluxoAction fluxo_video_action(const AVCodecParameters *par, uint32_t native, int force, int no_presentation_times) {
    int decodable = avcodec_find_decoder(par->codec_id) != NULL;
    int reordered = no_presentation_times && par->video_delay > 0;
    if (!force) {
        switch (par->codec_id) {
        case AV_CODEC_ID_H264:
            if ((fluxo_h264_is_native(par, native) && !reordered) || !decodable) {
                return FluxoActionCopy;
            }
            return FluxoActionConvert;
        case AV_CODEC_ID_HEVC:
            return reordered && decodable ? FluxoActionConvert : FluxoActionCopy;
        case AV_CODEC_ID_AV1:
            return (native & FLUXO_NATIVE_AV1) ? FluxoActionCopy : FluxoActionDrop;
        case AV_CODEC_ID_MPEG1VIDEO:
        case AV_CODEC_ID_MPEG2VIDEO:
            if (native & FLUXO_NATIVE_MPEG2_VIDEO) {
                return FluxoActionCopy;
            }
            break;
        default:
            break;
        }
    } else if (par->codec_id == AV_CODEC_ID_AV1) {
        return (native & FLUXO_NATIVE_AV1) ? FluxoActionCopy : FluxoActionDrop;
    }
    // Everything else (VP9 included: AVPlayer does not decode it from HLS, even where VideoToolbox can) is
    // converted when FFmpeg can decode it.
    return decodable && par->codec_id != AV_CODEC_ID_NONE ? FluxoActionConvert : FluxoActionDrop;
}

// `file_output`: an MP4 file (fluxo_remux_convert_file) rather than HLS segments. AVFoundation does not list MPEG
// audio (MP3, MP2) stored in MP4 at all (checked on macOS 26), so there it is converted too.
static FluxoAction fluxo_audio_action(const AVCodecParameters *par, uint32_t native, int force, int file_output) {
    int decodable = avcodec_find_decoder(par->codec_id) != NULL && par->codec_id != AV_CODEC_ID_NONE;
    if (!force) {
        switch (par->codec_id) {
        case AV_CODEC_ID_AAC:
            // HLS carries AAC-LC and HE-AAC; the old Main and LTP profiles are converted.
            if ((par->profile == AV_PROFILE_AAC_MAIN || par->profile == AV_PROFILE_AAC_LTP || par->profile == AV_PROFILE_AAC_SSR) && decodable) {
                return FluxoActionConvert;
            }
            return FluxoActionCopy;
        case AV_CODEC_ID_AC3:
        case AV_CODEC_ID_EAC3:
            return FluxoActionCopy;
        case AV_CODEC_ID_MP3:
            if (!file_output || !decodable) {
                return FluxoActionCopy;
            }
            break;
        case AV_CODEC_ID_MP2:
            if ((native & FLUXO_NATIVE_MP2_AUDIO) && !file_output) {
                return FluxoActionCopy;
            }
            break;
        default:
            break;
        }
    }
    return decodable ? FluxoActionConvert : FluxoActionDrop;
}

// MARK: - Packet queue

static int fluxo_queue_push(FluxoPacketQueue *queue, AVPacket *packet) {
    if (queue->head > 0 && queue->head + queue->count == queue->capacity) {
        memmove(queue->items, queue->items + queue->head, sizeof(AVPacket *) * (size_t)queue->count);
        queue->head = 0;
    }
    if (queue->count == queue->capacity) {
        int capacity = queue->capacity > 0 ? queue->capacity * 2 : 16;
        AVPacket **items = realloc(queue->items, sizeof(AVPacket *) * (size_t)capacity);
        if (items == NULL) {
            return AVERROR(ENOMEM);
        }
        queue->items = items;
        queue->capacity = capacity;
    }
    AVPacket *copy = av_packet_alloc();
    if (copy == NULL) {
        return AVERROR(ENOMEM);
    }
    av_packet_move_ref(copy, packet);
    queue->items[queue->head + queue->count] = copy;
    queue->count++;
    return 0;
}

static int fluxo_queue_pop(FluxoPacketQueue *queue, AVPacket *packet) {
    if (queue->count == 0) {
        return 0;
    }
    AVPacket *item = queue->items[queue->head];
    av_packet_move_ref(packet, item);
    av_packet_free(&item);
    queue->head++;
    queue->count--;
    if (queue->count == 0) {
        queue->head = 0;
    }
    return 1;
}

static void fluxo_queue_clear(FluxoPacketQueue *queue) {
    for (int i = 0; i < queue->count; i++) {
        av_packet_free(&queue->items[queue->head + i]);
    }
    queue->head = 0;
    queue->count = 0;
}

static void fluxo_queue_free(FluxoPacketQueue *queue) {
    fluxo_queue_clear(queue);
    free(queue->items);
    queue->items = NULL;
    queue->capacity = 0;
}

// Writes the pixel aspect ratio into the SPS of an encoded H.264 packet (h264_metadata). Returns 1 when the packet
// is ready, 0 when it should be skipped.
static int fluxo_filter_aspect(FluxoTranscoder *t) {
    if (t->aspect_filter == NULL) {
        return 1;
    }
    if (av_bsf_send_packet(t->aspect_filter, t->encoded) < 0) {
        av_packet_unref(t->encoded);
        return 0;
    }
    // One packet in, one packet out (the filter edits parameter sets in place).
    return av_bsf_receive_packet(t->aspect_filter, t->encoded) >= 0;
}

// Moves the encoder's packets (in `from` units) to the queue, in the stream's time base.
static int fluxo_drain_encoder(FluxoTranscoder *t, AVRational from) {
    for (;;) {
        int ret = avcodec_receive_packet(t->encoder, t->encoded);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return 0;
        }
        if (ret < 0) {
            return ret;
        }
        if (!fluxo_filter_aspect(t)) {
            continue;
        }
        av_packet_rescale_ts(t->encoded, from, t->time_base);
        t->encoded->pos = -1;
        ret = fluxo_queue_push(&t->queue, t->encoded);
        av_packet_unref(t->encoded);
        if (ret < 0) {
            return ret;
        }
    }
}

// MARK: - Video

static enum AVPixelFormat fluxo_get_format(AVCodecContext *context, const enum AVPixelFormat *formats) {
    const enum AVPixelFormat *format;
    if (context->hw_device_ctx != NULL) {
        for (format = formats; *format != AV_PIX_FMT_NONE; format++) {
            if (*format == AV_PIX_FMT_VIDEOTOOLBOX) {
                return *format;
            }
        }
    }
    // Software decoding: the first format that is not a hardware one.
    for (format = formats; *format != AV_PIX_FMT_NONE; format++) {
        const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(*format);
        if (descriptor != NULL && !(descriptor->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
            return *format;
        }
    }
    return AV_PIX_FMT_NONE;
}

// Average bit rate of converted video: about 0.12 bit per pixel (H.264 at that rate looks like a good copy of the
// SD and HD sources these codecs carry), 1.5 to 16 Mbit/s.
static int64_t fluxo_video_bit_rate(int width, int height, AVRational frame_rate) {
    double fps = frame_rate.num > 0 && frame_rate.den > 0 ? av_q2d(frame_rate) : 25;
    if (fps > 60) {
        fps = 60;
    }
    double bits = (double)width * height * fps * 0.12;
    if (bits < 1500000) {
        bits = 1500000;
    }
    if (bits > 16000000) {
        bits = 16000000;
    }
    return (int64_t)bits;
}

static int fluxo_video_open_encoder(FluxoTranscoder *t) {
    const AVCodec *codec = avcodec_find_encoder_by_name("h264_videotoolbox");
    if (codec == NULL) {
        return AVERROR_ENCODER_NOT_FOUND;
    }
    if (fluxo_test_refused(t->clock)) {
        return AVERROR_EXTERNAL;
    }
    AVCodecContext *encoder = avcodec_alloc_context3(codec);
    if (encoder == NULL) {
        return AVERROR(ENOMEM);
    }
    const AVCodecContext *decoder = t->decoder;
    encoder->width = t->width;
    encoder->height = t->height;
    encoder->pix_fmt = t->encoder_format;
    encoder->time_base = t->time_base;
    if (t->frame_rate.num > 0 && t->frame_rate.den > 0) {
        encoder->framerate = t->frame_rate;
    }
    encoder->sample_aspect_ratio = t->aspect;
    // 8-bit SDR output: the colors of an HDR or wide-gamut source are not kept (there is no tone mapping).
    int wide = decoder->color_primaries == AVCOL_PRI_BT2020 || decoder->color_trc == AVCOL_TRC_SMPTE2084 ||
               decoder->color_trc == AVCOL_TRC_ARIB_STD_B67;
    encoder->color_primaries = wide ? AVCOL_PRI_BT709 : decoder->color_primaries;
    encoder->color_trc = wide ? AVCOL_TRC_BT709 : decoder->color_trc;
    encoder->colorspace = wide || decoder->colorspace == AVCOL_SPC_BT2020_NCL ? AVCOL_SPC_BT709 : decoder->colorspace;
    encoder->color_range = AVCOL_RANGE_MPEG;
    encoder->bit_rate = t->bit_rate;
    // Key frames are placed by the converter (pict_type I); this only bounds the distance between two.
    double fps = t->frame_rate.num > 0 && t->frame_rate.den > 0 ? av_q2d(t->frame_rate) : 25;
    encoder->gop_size = (int)(fps * 12) > 1 ? (int)(fps * 12) : 1;
    // No B-frames: decoding times equal presentation times (segment cuts stay exact) and the encoder adds no delay.
    encoder->max_b_frames = 0;
    encoder->profile = AV_PROFILE_H264_HIGH;
    if (t->options.global_header) {
        encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    AVDictionary *options = NULL;
    // The software encoder only where there is no hardware one (the Simulator).
    av_dict_set(&options, "allow_sw", "1", 0);
    av_dict_set(&options, "realtime", t->options.is_live ? "1" : "0", 0);
    av_dict_set(&options, "power_efficient", "1", 0);
    int ret = avcodec_open2(encoder, codec, &options);
    av_dict_free(&options);
    if (ret < 0) {
        avcodec_free_context(&encoder);
        return ret;
    }
    t->encoder = encoder;
    t->encoder_used = 0;
    if (t->parameters->codec_id == AV_CODEC_ID_NONE) {
        ret = avcodec_parameters_from_context(t->parameters, encoder);
        if (ret < 0) {
            return ret;
        }
        t->parameters->codec_tag = 0;
    }
    av_bsf_free(&t->aspect_filter);
    const AVBitStreamFilter *metadata = av_bsf_get_by_name("h264_metadata");
    if (t->aspect.num > 0 && t->aspect.den > 0 && t->aspect.num != t->aspect.den && metadata != NULL &&
        av_bsf_alloc(metadata, &t->aspect_filter) >= 0) {
        // Without it the picture shows with square pixels (a 16:9 DVB channel squeezed to 5:4).
        int filter_ret = avcodec_parameters_from_context(t->aspect_filter->par_in, encoder);
        t->aspect_filter->time_base_in = encoder->time_base;
        if (filter_ret >= 0) {
            filter_ret = av_opt_set_q(t->aspect_filter->priv_data, "sample_aspect_ratio", t->aspect, 0);
        }
        if (filter_ret >= 0) {
            filter_ret = av_bsf_init(t->aspect_filter);
        }
        if (filter_ret >= 0 && t->options.global_header) {
            // MP4 files store the SPS in their header: the filtered one.
            filter_ret = avcodec_parameters_copy(t->parameters, t->aspect_filter->par_out);
            t->parameters->codec_tag = 0;
        }
        if (filter_ret < 0) {
            av_bsf_free(&t->aspect_filter);
        }
    }
    return 0;
}

static int fluxo_video_reopen(FluxoTranscoder *t, AVFrame *picture, int refused);

// The parameters of the converted stream while no encoder could be opened yet: H.264 of the picture's size,
// which MPEG-TS segments carry without a header (the parameter sets come in the stream).
static void fluxo_video_describe(FluxoTranscoder *t) {
    AVCodecParameters *par = t->parameters;
    const AVCodecContext *decoder = t->decoder;
    par->codec_type = AVMEDIA_TYPE_VIDEO;
    par->codec_id = AV_CODEC_ID_H264;
    par->codec_tag = 0;
    par->format = t->encoder_format;
    par->width = t->width;
    par->height = t->height;
    par->profile = AV_PROFILE_H264_HIGH;
    par->level = AV_LEVEL_UNKNOWN;
    par->sample_aspect_ratio = t->aspect;
    par->field_order = AV_FIELD_PROGRESSIVE;
    par->video_delay = 0;
    par->bit_rate = t->bit_rate;
    if (t->frame_rate.num > 0 && t->frame_rate.den > 0) {
        par->framerate = t->frame_rate;
    }
    // As fluxo_video_open_encoder sets them.
    int wide = decoder->color_primaries == AVCOL_PRI_BT2020 || decoder->color_trc == AVCOL_TRC_SMPTE2084 ||
               decoder->color_trc == AVCOL_TRC_ARIB_STD_B67;
    par->color_primaries = wide ? AVCOL_PRI_BT709 : decoder->color_primaries;
    par->color_trc = wide ? AVCOL_TRC_BT709 : decoder->color_trc;
    par->color_space = wide || decoder->colorspace == AVCOL_SPC_BT2020_NCL ? AVCOL_SPC_BT709 : decoder->colorspace;
    par->color_range = AVCOL_RANGE_MPEG;
}

// The first encoder of a converted video stream. The system may refuse one while the app is in the background
// (with a global header, VideoToolbox encodes a picture as it opens). That is not a video that cannot be played:
// - a file conversion waits a little for one (fluxo_video_reopen), then fails with FLUXO_ERROR_ENCODER_UNAVAILABLE
//   so that the download keeps its original and is converted again later;
// - playback keeps the stream converted without an encoder: fluxo_video_encode tries again as pictures come,
//   and meanwhile the engine cuts the segments on the audio (fluxo_streams_video_stalled), as when a session is
//   refused later.
static int fluxo_video_open_first_encoder(FluxoTranscoder *t) {
    int ret = fluxo_video_open_encoder(t);
    if (ret >= 0 || ret == AVERROR(ENOMEM) || ret == AVERROR_ENCODER_NOT_FOUND) {
        return ret;
    }
    avcodec_free_context(&t->encoder);
    if (t->options.complete || t->options.global_header) {
        // A header needs the encoder's parameter sets: no output can be described without it.
        ret = fluxo_video_reopen(t, NULL, 0);
        return ret == 0 || ret == AVERROR(ENOMEM) ? ret : FLUXO_ERROR_ENCODER_UNAVAILABLE;
    }
    fluxo_video_describe(t);
    return 0;
}

static int fluxo_video_open(FluxoTranscoder *t, AVFormatContext *input, AVStream *stream) {
    const AVCodecParameters *par = stream->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (codec == NULL) {
        return AVERROR_DECODER_NOT_FOUND;
    }
    t->decoder = avcodec_alloc_context3(codec);
    if (t->decoder == NULL) {
        return AVERROR(ENOMEM);
    }
    int ret = avcodec_parameters_to_context(t->decoder, par);
    if (ret < 0) {
        return ret;
    }
    t->decoder->pkt_timebase = stream->time_base;
    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    t->decoder->thread_count = cpus > 4 ? 4 : (cpus > 0 ? (int)cpus : 1);
    t->decoder->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    t->decoder->get_format = fluxo_get_format;
    // Pictures the decoder knows are damaged (references missing after a seek) are not shown.
    t->decoder->flags &= ~AV_CODEC_FLAG_OUTPUT_CORRUPT;
    int hardware = 0;
    if (par->codec_id == AV_CODEC_ID_VP9 && VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9) &&
        av_hwdevice_ctx_create(&t->hw_device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0) {
        t->decoder->hw_device_ctx = av_buffer_ref(t->hw_device);
        // Hardware decoding runs on one thread (FFmpeg falls back to software when VideoToolbox refuses the stream).
        t->decoder->thread_count = 1;
        hardware = t->decoder->hw_device_ctx != NULL;
    }
    ret = avcodec_open2(t->decoder, codec, NULL);
    if (ret < 0) {
        return ret;
    }
    // Even dimensions (4:2:0), at least 16 pixels.
    t->width = (par->width > 16 ? par->width : 16) & ~1;
    t->height = (par->height > 16 ? par->height : 16) & ~1;
    // The encoder takes the decoder's pictures as they are when it can (NV12 from VideoToolbox, planar 4:2:0 from
    // most software decoders); anything else is converted (sws).
    t->encoder_format = hardware || par->format == AV_PIX_FMT_NV12 ? AV_PIX_FMT_NV12 : AV_PIX_FMT_YUV420P;
    t->frame_rate = av_guess_frame_rate(input, stream, NULL);
    // The container's (Matroska display size) or the stream's own.
    t->aspect = av_guess_sample_aspect_ratio(input, stream, NULL);
    if (t->aspect.num <= 0 || t->aspect.den <= 0) {
        t->aspect = (AVRational){1, 1};
    }
    t->bit_rate = fluxo_video_bit_rate(t->width, t->height, t->frame_rate);
    t->last_pts = AV_NOPTS_VALUE;
    t->last_key_time = AV_NOPTS_VALUE;
    t->key_cursor = -1;
    t->key_interval = (int64_t)((t->options.key_interval > 0 ? t->options.key_interval : 4) * AV_TIME_BASE);
    t->software = av_frame_alloc();
    if (t->software == NULL) {
        return AVERROR(ENOMEM);
    }
    return fluxo_video_open_first_encoder(t);
}

// Vertical [1 2 1] blend of one 8-bit plane: removes the combing of interlaced pictures at the cost of some
// vertical detail, for little work (the frames AVPlayer gets are progressive H.264).
static int fluxo_blend_plane(FluxoTranscoder *t, uint8_t *data, int linesize, int width, int height) {
    if (height < 3 || width <= 0) {
        return 0;
    }
    if (t->line_size < (size_t)width) {
        uint8_t *line = realloc(t->line, (size_t)width);
        if (line == NULL) {
            return AVERROR(ENOMEM);
        }
        t->line = line;
        t->line_size = (size_t)width;
    }
    uint8_t *previous = t->line;
    memcpy(previous, data, (size_t)width);
    for (int y = 1; y < height - 1; y++) {
        uint8_t *row = data + (ptrdiff_t)y * linesize;
        const uint8_t *next = row + linesize;
        for (int x = 0; x < width; x++) {
            uint8_t current = row[x];
            row[x] = (uint8_t)((previous[x] + 2 * current + next[x] + 2) >> 2);
            previous[x] = current;
        }
    }
    return 0;
}

static int fluxo_deinterlace(FluxoTranscoder *t, AVFrame *frame) {
    int ret = 0;
    if (frame->format == AV_PIX_FMT_NV12) {
        ret = fluxo_blend_plane(t, frame->data[0], frame->linesize[0], frame->width, frame->height);
        if (ret >= 0) {
            ret = fluxo_blend_plane(t, frame->data[1], frame->linesize[1], frame->width, (frame->height + 1) / 2);
        }
    } else if (frame->format == AV_PIX_FMT_YUV420P) {
        ret = fluxo_blend_plane(t, frame->data[0], frame->linesize[0], frame->width, frame->height);
        for (int plane = 1; plane < 3 && ret >= 0; plane++) {
            ret = fluxo_blend_plane(t, frame->data[plane], frame->linesize[plane], (frame->width + 1) / 2, (frame->height + 1) / 2);
        }
    }
    frame->flags &= ~(AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_TOP_FIELD_FIRST);
    return ret;
}

// Whether the picture at `time` (AV_TIME_BASE units, input timeline) must be a key frame.
static int fluxo_video_wants_key(FluxoTranscoder *t, int64_t time) {
    int key = t->last_key_time == AV_NOPTS_VALUE;
    if (t->key_times != NULL && t->key_count > 0) {
        if (t->key_cursor < 0) {
            // After a reset: the first key time after this picture is the next cut.
            int low = 0;
            int high = t->key_count;
            while (low < high) {
                int middle = (low + high) / 2;
                if (t->key_times[middle] <= time + FLUXO_KEY_EPSILON) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }
            t->key_cursor = low;
            key = 1;
        }
        while (t->key_cursor < t->key_count && t->key_times[t->key_cursor] <= time + FLUXO_KEY_EPSILON) {
            t->key_cursor++;
            key = 1;
        }
    } else if (t->last_key_time != AV_NOPTS_VALUE && (time - t->last_key_time >= t->key_interval || time < t->last_key_time)) {
        key = 1;
    }
    if (key) {
        t->last_key_time = time;
    }
    return key;
}

// Opens a new video encoder. A file conversion waits a little for one (FLUXO_ENCODER_WAITS); there, `picture`
// (when not NULL) must also be taken by it. Returns 0, FLUXO_ERROR_ENCODER_UNAVAILABLE (a file conversion) or
// another negative value.
static int fluxo_video_reopen(FluxoTranscoder *t, AVFrame *picture, int refused) {
    int attempts = t->options.complete ? FLUXO_ENCODER_WAITS : 1;
    for (int attempt = 0; attempt < attempts; attempt++) {
        if (attempt > 0) {
            usleep(FLUXO_ENCODER_WAIT_US);
        }
        avcodec_free_context(&t->encoder);
        int ret = fluxo_video_open_encoder(t);
        if (ret == AVERROR(ENOMEM)) {
            return ret;
        }
        if (ret < 0) {
            continue;
        }
        if (picture == NULL) {
            return 0;
        }
        // A new encoder starts with a key frame.
        picture->pict_type = AV_PICTURE_TYPE_I;
        ret = refused ? AVERROR_EXTERNAL : avcodec_send_frame(t->encoder, picture);
        if (ret >= 0) {
            return 0;
        }
    }
    return t->options.complete ? FLUXO_ERROR_ENCODER_UNAVAILABLE : -1;
}

// A timestamp restart: what the encoder holds is written out with the old times, and a new encoder starts the new
// timeline with a key frame. The pictures keep their real times, so the engine sees the same jump on the video as
// on the audio (copied, or converted: fluxo_audio_push starts again at the new time) and moves both alike.
// `time`: the new picture's (AV_TIME_BASE units). Live, the key frames go on at their interval from the last one
// before the restart (the engine joins the two timelines): segments keep their duration.
static int fluxo_video_restart(FluxoTranscoder *t, int64_t time) {
    int64_t since_key = AV_NOPTS_VALUE;
    if (t->key_times == NULL && t->last_key_time != AV_NOPTS_VALUE && t->last_pts != AV_NOPTS_VALUE) {
        int64_t step = t->frame_rate.num > 0 && t->frame_rate.den > 0 ? av_rescale_q(1, av_inv_q(t->frame_rate), AV_TIME_BASE_Q) : 0;
        since_key = av_rescale_q(t->last_pts, t->time_base, AV_TIME_BASE_Q) - t->last_key_time + step;
        if (since_key < 0) {
            since_key = AV_NOPTS_VALUE;
        }
    }
    if (t->encoder != NULL) {
        if (t->encoder_used && avcodec_send_frame(t->encoder, NULL) >= 0) {
            int ret = fluxo_drain_encoder(t, t->encoder->time_base);
            if (ret == AVERROR(ENOMEM)) {
                return ret;
            }
        }
        avcodec_free_context(&t->encoder);
    }
    t->last_pts = AV_NOPTS_VALUE;
    t->last_key_time = since_key != AV_NOPTS_VALUE ? time - since_key : AV_NOPTS_VALUE;
    t->key_cursor = -1;
    t->encoder_failures = 0;
    return fluxo_video_reopen(t, NULL, 0);
}

static int fluxo_video_encode(FluxoTranscoder *t, AVFrame *frame) {
    int64_t frame_pts = frame->best_effort_timestamp != AV_NOPTS_VALUE ? frame->best_effort_timestamp : frame->pts;
    if (frame_pts != AV_NOPTS_VALUE) {
        t->clock = av_rescale_q(frame_pts, t->time_base, AV_TIME_BASE_Q);
    }
    if (t->encoder == NULL) {
        // No encoder (opening one failed after a reset, a restart or a refused session): tried again on the first
        // pictures, then about once a second, like a refused session below.
        if (!t->options.complete && ++t->encoder_failures > FLUXO_ENCODER_RETRIES && t->encoder_failures % 25 != 0) {
            return 0;
        }
        int ret = fluxo_video_reopen(t, NULL, 0);
        if (ret < 0) {
            return ret == AVERROR(ENOMEM) || ret == FLUXO_ERROR_ENCODER_UNAVAILABLE ? ret : 0;
        }
        t->last_key_time = AV_NOPTS_VALUE;
    }
    AVFrame *picture = frame;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        av_frame_unref(t->software);
        int ret = av_hwframe_transfer_data(t->software, frame, 0);
        if (ret < 0) {
            return 0;
        }
        av_frame_copy_props(t->software, frame);
        picture = t->software;
    }

    int64_t pts = frame->best_effort_timestamp != AV_NOPTS_VALUE ? frame->best_effort_timestamp : frame->pts;
    if (pts == AV_NOPTS_VALUE) {
        if (t->last_pts == AV_NOPTS_VALUE) {
            return 0;
        }
        int64_t step = t->frame_rate.num > 0 ? av_rescale_q(1, av_inv_q(t->frame_rate), t->time_base) : 1;
        pts = t->last_pts + (step > 0 ? step : 1);
    }
    if (t->last_pts != AV_NOPTS_VALUE && pts <= t->last_pts) {
        int64_t behind = av_rescale_q(t->last_pts - pts, t->time_base, AV_TIME_BASE_Q);
        if (behind > FLUXO_VIDEO_RESYNC) {
            int ret = fluxo_video_restart(t, av_rescale_q(pts, t->time_base, AV_TIME_BASE_Q));
            if (ret == AVERROR(ENOMEM) || ret == FLUXO_ERROR_ENCODER_UNAVAILABLE) {
                return ret;
            }
            if (t->encoder == NULL) {
                return 0;
            }
        } else {
            // Jitter (a damaged stream, rounded times): the picture follows the previous one.
            pts = t->last_pts + 1;
        }
    }

    // Another pixel format or size (a stream that changes resolution), full-range or wide-gamut pictures: converted
    // to what the encoder was opened with (8-bit 4:2:0, limited range, BT.709 for HDR sources).
    int wide = picture->color_primaries == AVCOL_PRI_BT2020 || picture->color_trc == AVCOL_TRC_SMPTE2084 ||
               picture->color_trc == AVCOL_TRC_ARIB_STD_B67;
    if (picture->format != t->encoder_format || picture->width != t->width || picture->height != t->height ||
        picture->color_range == AVCOL_RANGE_JPEG || wide) {
        if (t->scaler == NULL) {
            t->scaler = sws_alloc_context();
            if (t->scaler == NULL) {
                return AVERROR(ENOMEM);
            }
            t->scaler->flags = SWS_BILINEAR;
        }
        av_frame_unref(t->converted);
        av_frame_copy_props(t->converted, picture);
        t->converted->format = t->encoder_format;
        t->converted->width = t->width;
        t->converted->height = t->height;
        t->converted->color_range = AVCOL_RANGE_MPEG;
        t->converted->color_primaries = t->encoder->color_primaries;
        t->converted->color_trc = t->encoder->color_trc;
        t->converted->colorspace = t->encoder->colorspace;
        if (sws_scale_frame(t->scaler, t->converted, picture) < 0) {
            return 0;
        }
        picture = t->converted;
    }
    if (picture->flags & AV_FRAME_FLAG_INTERLACED) {
        if (picture != t->converted) {
            av_frame_unref(t->converted);
            int ret = av_frame_ref(t->converted, picture);
            if (ret < 0) {
                return ret;
            }
            picture = t->converted;
        }
        // The decoder may still use its picture as a reference (and the scaler may pass planes through): blend a
        // copy of its own.
        int ret = av_frame_make_writable(picture);
        if (ret >= 0) {
            ret = fluxo_deinterlace(t, picture);
        }
        if (ret < 0) {
            return ret;
        }
    }

    int64_t time = av_rescale_q(pts, t->time_base, AV_TIME_BASE_Q);
    t->clock = time;
    picture->pts = pts;
    // A new encoder starts with a key frame (after a restart, outside the interval of the others).
    picture->pict_type = fluxo_video_wants_key(t, time) || !t->encoder_used ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;

    int refused = fluxo_test_refused(time);
    int ret = refused ? AVERROR_EXTERNAL : avcodec_send_frame(t->encoder, picture);
    if (ret < 0 && ret != AVERROR(EAGAIN)) {
        // A session VideoToolbox invalidated: a new encoder starts with a key frame. While playing, after a few
        // failures in a row the pictures are dropped, and a new encoder is tried about once a second; a file
        // conversion waits for one instead (fluxo_video_reopen).
        if (!t->options.complete && ++t->encoder_failures > FLUXO_ENCODER_RETRIES && t->encoder_failures % 25 != 0) {
            return 0;
        }
        t->last_key_time = time;
        ret = fluxo_video_reopen(t, picture, refused);
        if (ret < 0) {
            return ret == AVERROR(ENOMEM) || ret == FLUXO_ERROR_ENCODER_UNAVAILABLE ? ret : 0;
        }
    }
    t->encoder_failures = 0;
    t->encoder_used = 1;
    t->last_pts = pts;
    return fluxo_drain_encoder(t, t->encoder->time_base);
}

// MARK: - Audio

static const int fluxo_aac_rates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000};

static int fluxo_audio_open_encoder(FluxoTranscoder *t, int sample_rate, const AVChannelLayout *layout) {
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (codec == NULL) {
        return AVERROR_ENCODER_NOT_FOUND;
    }
    AVCodecContext *encoder = avcodec_alloc_context3(codec);
    if (encoder == NULL) {
        return AVERROR(ENOMEM);
    }
    encoder->sample_fmt = AV_SAMPLE_FMT_FLTP;
    encoder->sample_rate = sample_rate;
    int ret = av_channel_layout_copy(&encoder->ch_layout, layout);
    if (ret < 0) {
        avcodec_free_context(&encoder);
        return ret;
    }
    int channels = layout->nb_channels;
    encoder->bit_rate = channels <= 1 ? 96000 : channels == 2 ? 192000 : 384000;
    encoder->time_base = (AVRational){1, sample_rate};
    encoder->profile = AV_PROFILE_AAC_LOW;
    // The AudioSpecificConfig is needed by MP4 outputs; MPEG-TS outputs make ADTS headers from it.
    encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    AVDictionary *options = NULL;
    // The fast coder costs a fraction of the default one, for a difference that is hard to hear at these rates.
    av_dict_set(&options, "aac_coder", "fast", 0);
    ret = avcodec_open2(encoder, codec, &options);
    av_dict_free(&options);
    if (ret < 0) {
        avcodec_free_context(&encoder);
        return ret;
    }
    t->encoder = encoder;
    t->encoder_used = 0;
    if (t->parameters->codec_id == AV_CODEC_ID_NONE) {
        ret = avcodec_parameters_from_context(t->parameters, encoder);
        if (ret < 0) {
            return ret;
        }
        t->parameters->codec_tag = 0;
    }
    return 0;
}

static int fluxo_audio_open(FluxoTranscoder *t, AVStream *stream) {
    const AVCodecParameters *par = stream->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (codec == NULL) {
        return AVERROR_DECODER_NOT_FOUND;
    }
    t->decoder = avcodec_alloc_context3(codec);
    if (t->decoder == NULL) {
        return AVERROR(ENOMEM);
    }
    int ret = avcodec_parameters_to_context(t->decoder, par);
    if (ret < 0) {
        return ret;
    }
    t->decoder->pkt_timebase = stream->time_base;
    ret = avcodec_open2(t->decoder, codec, NULL);
    if (ret < 0) {
        return ret;
    }
    // Mono and stereo stay so; three or four channels become stereo, five or more 5.1 (what HLS players and
    // AirPlay receivers take as AAC). 5.1 with back surrounds: AAC's channel configuration 6, which ADTS (MPEG-TS
    // segments) can signal; other 5.1 layouts need a program config element ADTS cannot carry.
    int channels = par->ch_layout.nb_channels > 0 ? par->ch_layout.nb_channels : 2;
    AVChannelLayout layout = channels == 1 ? (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO
                           : channels >= 5 ? (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1_BACK : (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
    int sample_rate = 48000;
    for (size_t i = 0; i < sizeof(fluxo_aac_rates) / sizeof(*fluxo_aac_rates); i++) {
        if (par->sample_rate == fluxo_aac_rates[i] && par->sample_rate <= 48000) {
            sample_rate = par->sample_rate;
        }
    }
    t->fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, layout.nb_channels, 4096);
    if (t->fifo == NULL) {
        return AVERROR(ENOMEM);
    }
    t->next_pts = AV_NOPTS_VALUE;
    t->audio_rate = sample_rate;
    ret = av_channel_layout_copy(&t->audio_layout, &layout);
    if (ret < 0) {
        return ret;
    }
    return fluxo_audio_open_encoder(t, sample_rate, &layout);
}

// Encodes `count` samples from the FIFO (a full frame, or the last partial one).
static int fluxo_audio_encode_samples(FluxoTranscoder *t, int count) {
    AVCodecContext *encoder = t->encoder;
    av_frame_unref(t->converted);
    t->converted->nb_samples = count;
    t->converted->format = encoder->sample_fmt;
    t->converted->sample_rate = encoder->sample_rate;
    int ret = av_channel_layout_copy(&t->converted->ch_layout, &encoder->ch_layout);
    if (ret >= 0) {
        ret = av_frame_get_buffer(t->converted, 0);
    }
    if (ret < 0) {
        return ret;
    }
    if (av_audio_fifo_read(t->fifo, (void **)t->converted->data, count) < count) {
        return AVERROR_BUG;
    }
    t->converted->pts = t->next_pts;
    t->next_pts += count;
    ret = avcodec_send_frame(encoder, t->converted);
    if (ret < 0) {
        return 0;
    }
    t->encoder_used = 1;
    return fluxo_drain_encoder(t, encoder->time_base);
}

static int fluxo_audio_encode_ready(FluxoTranscoder *t) {
    int frame_size = t->encoder->frame_size > 0 ? t->encoder->frame_size : 1024;
    while (av_audio_fifo_size(t->fifo) >= frame_size) {
        int ret = fluxo_audio_encode_samples(t, frame_size);
        if (ret < 0) {
            return ret;
        }
    }
    return 0;
}

// Resamples `count` samples of `data` (NULL: what the resampler holds) into the FIFO.
static int fluxo_audio_resample(FluxoTranscoder *t, const uint8_t **data, int count) {
    int capacity = swr_get_out_samples(t->resampler, count);
    if (capacity <= 0) {
        return 0;
    }
    if (capacity > t->samples_capacity) {
        if (t->samples != NULL) {
            av_freep(&t->samples[0]);
            av_freep(&t->samples);
        }
        t->samples_capacity = 0;
        int ret = av_samples_alloc_array_and_samples(&t->samples, NULL, t->encoder->ch_layout.nb_channels, capacity, AV_SAMPLE_FMT_FLTP, 0);
        if (ret < 0) {
            return ret;
        }
        t->samples_capacity = capacity;
    }
    int produced = swr_convert(t->resampler, t->samples, capacity, data, count);
    if (produced < 0) {
        return 0;
    }
    if (produced > 0 && av_audio_fifo_write(t->fifo, (void **)t->samples, produced) < produced) {
        return AVERROR(ENOMEM);
    }
    return 0;
}

static int fluxo_audio_push(FluxoTranscoder *t, AVFrame *frame) {
    if (t->encoder == NULL && fluxo_audio_open_encoder(t, t->audio_rate, &t->audio_layout) < 0) {
        return 0;
    }
    AVCodecContext *encoder = t->encoder;
    AVChannelLayout layout = {0};
    if (frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || frame->ch_layout.nb_channels == 0) {
        av_channel_layout_default(&layout, frame->ch_layout.nb_channels > 0 ? frame->ch_layout.nb_channels : t->decoder->ch_layout.nb_channels);
    } else if (av_channel_layout_copy(&layout, &frame->ch_layout) < 0) {
        return AVERROR(ENOMEM);
    }
    if (layout.nb_channels <= 0 || frame->sample_rate <= 0) {
        av_channel_layout_uninit(&layout);
        return 0;
    }
    if (t->resampler == NULL || av_channel_layout_compare(&layout, &t->resampler_layout) != 0 ||
        frame->format != t->resampler_format || frame->sample_rate != t->resampler_rate) {
        swr_free(&t->resampler);
        int ret = swr_alloc_set_opts2(&t->resampler, &encoder->ch_layout, encoder->sample_fmt, encoder->sample_rate, &layout,
                                      (enum AVSampleFormat)frame->format, frame->sample_rate, 0, NULL);
        if (ret >= 0) {
            ret = swr_init(t->resampler);
        }
        if (ret < 0) {
            swr_free(&t->resampler);
            av_channel_layout_uninit(&layout);
            return 0;
        }
        av_channel_layout_uninit(&t->resampler_layout);
        av_channel_layout_copy(&t->resampler_layout, &layout);
        t->resampler_format = (enum AVSampleFormat)frame->format;
        t->resampler_rate = frame->sample_rate;
    }
    av_channel_layout_uninit(&layout);

    int64_t pts = frame->best_effort_timestamp != AV_NOPTS_VALUE ? frame->best_effort_timestamp : frame->pts;
    if (pts != AV_NOPTS_VALUE) {
        int64_t time = av_rescale_q(pts, t->time_base, encoder->time_base);
        int64_t expected = t->next_pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE
            : t->next_pts + av_audio_fifo_size(t->fifo) + swr_get_delay(t->resampler, encoder->sample_rate);
        int64_t tolerance = av_rescale_q(FLUXO_AUDIO_RESYNC, AV_TIME_BASE_Q, encoder->time_base);
        if (expected == AV_NOPTS_VALUE || time - expected > tolerance || expected - time > tolerance) {
            // The first frame, or a jump: the samples produced from here start at this frame's time.
            av_audio_fifo_reset(t->fifo);
            swr_init(t->resampler);
            t->next_pts = time;
        }
    } else if (t->next_pts == AV_NOPTS_VALUE) {
        return 0;
    }
    int ret = fluxo_audio_resample(t, (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (ret < 0) {
        return ret;
    }
    return fluxo_audio_encode_ready(t);
}

static int fluxo_audio_finish(FluxoTranscoder *t) {
    if (t->encoder == NULL) {
        return 0;
    }
    if (t->resampler != NULL && t->next_pts != AV_NOPTS_VALUE) {
        int ret = fluxo_audio_resample(t, NULL, 0);
        if (ret >= 0) {
            ret = fluxo_audio_encode_ready(t);
        }
        int left = av_audio_fifo_size(t->fifo);
        if (ret >= 0 && left > 0) {
            ret = fluxo_audio_encode_samples(t, left);
        }
        if (ret < 0) {
            return ret;
        }
    }
    if (avcodec_send_frame(t->encoder, NULL) < 0) {
        return 0;
    }
    return fluxo_drain_encoder(t, t->encoder->time_base);
}

// MARK: - Converter

static void fluxo_transcoder_free(FluxoTranscoder **pointer) {
    FluxoTranscoder *t = *pointer;
    if (t == NULL) {
        return;
    }
    avcodec_free_context(&t->decoder);
    avcodec_free_context(&t->encoder);
    avcodec_parameters_free(&t->parameters);
    av_buffer_unref(&t->hw_device);
    av_bsf_free(&t->aspect_filter);
    av_frame_free(&t->frame);
    av_frame_free(&t->converted);
    av_frame_free(&t->software);
    av_packet_free(&t->encoded);
    fluxo_queue_free(&t->queue);
    sws_freeContext(t->scaler);
    free(t->line);
    swr_free(&t->resampler);
    av_channel_layout_uninit(&t->resampler_layout);
    av_channel_layout_uninit(&t->audio_layout);
    av_audio_fifo_free(t->fifo);
    if (t->samples != NULL) {
        av_freep(&t->samples[0]);
        av_freep(&t->samples);
    }
    free(t);
    *pointer = NULL;
}

static int fluxo_transcoder_create(FluxoTranscoder **result, AVFormatContext *input, AVStream *stream, const FluxoStreamsOptions *options) {
    FluxoTranscoder *t = calloc(1, sizeof(FluxoTranscoder));
    if (t == NULL) {
        return AVERROR(ENOMEM);
    }
    t->type = stream->codecpar->codec_type;
    t->time_base = stream->time_base;
    t->options = *options;
    t->parameters = avcodec_parameters_alloc();
    t->frame = av_frame_alloc();
    t->converted = av_frame_alloc();
    t->encoded = av_packet_alloc();
    int ret = t->parameters != NULL && t->frame != NULL && t->converted != NULL && t->encoded != NULL ? 0 : AVERROR(ENOMEM);
    if (ret >= 0) {
        ret = t->type == AVMEDIA_TYPE_VIDEO ? fluxo_video_open(t, input, stream) : fluxo_audio_open(t, stream);
    }
    if (ret < 0) {
        fluxo_transcoder_free(&t);
        return ret;
    }
    *result = t;
    return 0;
}

// Feeds one input packet (NULL: the input ended, drain everything).
static int fluxo_transcoder_send(FluxoTranscoder *t, const AVPacket *packet) {
    int ret = avcodec_send_packet(t->decoder, packet);
    if (ret < 0 && packet != NULL) {
        // A damaged packet: the stream goes on without it.
        return 0;
    }
    for (;;) {
        ret = avcodec_receive_frame(t->decoder, t->frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            // A picture or audio frame that failed to decode.
            if (ret == AVERROR(ENOMEM)) {
                return ret;
            }
            continue;
        }
        ret = t->type == AVMEDIA_TYPE_VIDEO ? fluxo_video_encode(t, t->frame) : fluxo_audio_push(t, t->frame);
        av_frame_unref(t->frame);
        if (ret == AVERROR(ENOMEM) || ret == FLUXO_ERROR_ENCODER_UNAVAILABLE) {
            return ret;
        }
    }
    if (packet == NULL) {
        if (t->type == AVMEDIA_TYPE_VIDEO) {
            if (t->encoder != NULL && avcodec_send_frame(t->encoder, NULL) >= 0) {
                fluxo_drain_encoder(t, t->encoder->time_base);
            }
        } else {
            fluxo_audio_finish(t);
        }
    }
    return 0;
}

static void fluxo_transcoder_reset(FluxoTranscoder *t) {
    fluxo_queue_clear(&t->queue);
    avcodec_flush_buffers(t->decoder);
    // Neither encoder can be flushed and reused: a fresh one starts the new position (with a key frame).
    if (t->encoder_used || t->encoder == NULL) {
        avcodec_free_context(&t->encoder);
        if (t->type == AVMEDIA_TYPE_VIDEO) {
            fluxo_video_open_encoder(t);
        } else {
            fluxo_audio_open_encoder(t, t->audio_rate, &t->audio_layout);
        }
    }
    t->last_pts = AV_NOPTS_VALUE;
    t->last_key_time = AV_NOPTS_VALUE;
    t->key_cursor = -1;
    t->encoder_failures = 0;
    if (t->fifo != NULL) {
        av_audio_fifo_reset(t->fifo);
    }
    swr_free(&t->resampler);
    t->next_pts = AV_NOPTS_VALUE;
}

// MARK: - Streams

// The usual name of the codecs a player meets most, for messages (FFmpeg's long names read like "Alliance for Open
// Media AV1"); NULL for the others.
static const char *fluxo_codec_common_name(enum AVCodecID codec_id) {
    switch (codec_id) {
    case AV_CODEC_ID_AV1: return "AV1";
    case AV_CODEC_ID_VP8: return "VP8";
    case AV_CODEC_ID_VP9: return "VP9";
    case AV_CODEC_ID_HEVC: return "HEVC";
    case AV_CODEC_ID_H264: return "H.264";
    case AV_CODEC_ID_H263: return "H.263";
    case AV_CODEC_ID_MPEG1VIDEO: return "MPEG-1";
    case AV_CODEC_ID_MPEG2VIDEO: return "MPEG-2";
    case AV_CODEC_ID_MPEG4: return "MPEG-4 Part 2";
    case AV_CODEC_ID_VC1: return "VC-1";
    case AV_CODEC_ID_WMV1: return "WMV 7";
    case AV_CODEC_ID_WMV2: return "WMV 8";
    case AV_CODEC_ID_WMV3: return "WMV 9";
    case AV_CODEC_ID_THEORA: return "Theora";
    case AV_CODEC_ID_PRORES: return "ProRes";
    case AV_CODEC_ID_VVC: return "H.266 (VVC)";
    case AV_CODEC_ID_DTS: return "DTS";
    case AV_CODEC_ID_TRUEHD: return "Dolby TrueHD";
    case AV_CODEC_ID_AC3: return "Dolby Digital";
    case AV_CODEC_ID_EAC3: return "Dolby Digital Plus";
    case AV_CODEC_ID_AC4: return "Dolby AC-4";
    case AV_CODEC_ID_OPUS: return "Opus";
    case AV_CODEC_ID_VORBIS: return "Vorbis";
    case AV_CODEC_ID_FLAC: return "FLAC";
    case AV_CODEC_ID_MP2: return "MP2";
    case AV_CODEC_ID_MP3: return "MP3";
    case AV_CODEC_ID_WMAV1: return "WMA 1";
    case AV_CODEC_ID_WMAV2: return "WMA 2";
    case AV_CODEC_ID_WMAPRO: return "WMA Pro";
    case AV_CODEC_ID_WMALOSSLESS: return "WMA Lossless";
    default: return NULL;
    }
}

static void fluxo_codec_label(const AVCodecParameters *par, char *buffer, size_t size) {
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(par->codec_id);
    const char *common = fluxo_codec_common_name(par->codec_id);
    if (common != NULL) {
        snprintf(buffer, size, "%s", common);
    } else if (descriptor != NULL && descriptor->long_name != NULL) {
        snprintf(buffer, size, "%s", descriptor->long_name);
    } else if (descriptor != NULL) {
        snprintf(buffer, size, "%s", descriptor->name);
    } else {
        char tag[AV_FOURCC_MAX_STRING_SIZE] = {0};
        av_fourcc_make_string(tag, par->codec_tag);
        snprintf(buffer, size, "%s", par->codec_tag != 0 ? tag : "unknown");
    }
}

static int fluxo_is_media_stream(const AVStream *stream, enum AVMediaType type) {
    return stream->codecpar->codec_type == type && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC);
}

int fluxo_streams_open(FluxoStreams *streams, AVFormatContext *input, const FluxoStreamsOptions *options) {
    memset(streams, 0, sizeof(*streams));
    streams->input = input;
    streams->count = input->nb_streams;
    streams->transcoders = calloc(input->nb_streams > 0 ? input->nb_streams : 1, sizeof(FluxoTranscoder *));
    if (streams->transcoders == NULL) {
        return AVERROR(ENOMEM);
    }
    input->opaque = streams;
    uint32_t native = fluxo_native_codecs();
    int force = fluxo_force_conversion();

    // Video: the first stream that can be played (copied or converted) is the one the outputs take; the others
    // are left out.
    int no_presentation_times = strcmp(input->iformat->name, "avi") == 0;
    int video_streams = 0;
    int video_found = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        AVStream *stream = input->streams[i];
        if (!fluxo_is_media_stream(stream, AVMEDIA_TYPE_VIDEO)) {
            continue;
        }
        video_streams++;
        FluxoAction action = video_found ? FluxoActionDrop : fluxo_video_action(stream->codecpar, native, force, no_presentation_times);
        if (action == FluxoActionConvert) {
            int ret = fluxo_transcoder_create(&streams->transcoders[i], input, stream, options);
            if (ret == AVERROR(ENOMEM) || ret == FLUXO_ERROR_ENCODER_UNAVAILABLE) {
                // No memory, or a file conversion whose encoder is refused for now (the app in the background):
                // not a format that cannot be played.
                return ret;
            }
            action = ret < 0 ? FluxoActionDrop : FluxoActionConvert;
        }
        if (action == FluxoActionDrop) {
            if (!video_found && streams->unsupported_codec[0] == '\0') {
                fluxo_codec_label(stream->codecpar, streams->unsupported_codec, sizeof(streams->unsupported_codec));
            }
            stream->discard = AVDISCARD_ALL;
        } else {
            video_found = 1;
        }
    }
    if (video_streams > 0 && !video_found) {
        return FLUXO_ERROR_UNSUPPORTED_VIDEO;
    }
    if (video_found) {
        streams->unsupported_codec[0] = '\0';
    }

    // Audio: the default track's conversion first, then the others in order, at most FLUXO_MAX_CONVERTED_AUDIO.
    int audio_streams = 0;
    int audio_found = 0;
    int converted = 0;
    char first_audio[64] = {0};
    for (int pass = 0; pass < 2; pass++) {
        for (unsigned int i = 0; i < input->nb_streams; i++) {
            AVStream *stream = input->streams[i];
            if (!fluxo_is_media_stream(stream, AVMEDIA_TYPE_AUDIO)) {
                continue;
            }
            int is_default = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;
            if ((pass == 0) != is_default) {
                continue;
            }
            audio_streams++;
            FluxoAction action = fluxo_audio_action(stream->codecpar, native, force, options->global_header);
            if (stream->codecpar->sample_rate <= 0 || stream->codecpar->ch_layout.nb_channels <= 0) {
                // Nothing of it was read while probing (an empty PID, the AC-3 core announced next to a TrueHD
                // track): muxers refuse an audio stream without a sample rate, and the whole output would fail.
                action = FluxoActionDrop;
            }
            if (action == FluxoActionConvert) {
                int ret = converted < FLUXO_MAX_CONVERTED_AUDIO ? fluxo_transcoder_create(&streams->transcoders[i], input, stream, options)
                                                                : AVERROR(ERANGE);
                if (ret == AVERROR(ENOMEM)) {
                    return ret;
                }
                action = ret < 0 ? FluxoActionDrop : FluxoActionConvert;
                converted += ret >= 0;
            }
            if (action == FluxoActionDrop) {
                if (first_audio[0] == '\0') {
                    fluxo_codec_label(stream->codecpar, first_audio, sizeof(first_audio));
                }
                stream->discard = AVDISCARD_ALL;
            } else {
                audio_found = 1;
            }
        }
    }
    if (video_streams == 0 && audio_streams > 0 && !audio_found) {
        snprintf(streams->unsupported_codec, sizeof(streams->unsupported_codec), "%s", first_audio);
        return FLUXO_ERROR_UNSUPPORTED_AUDIO;
    }
    return 0;
}

void fluxo_streams_close(FluxoStreams *streams) {
    if (streams->transcoders != NULL) {
        for (unsigned int i = 0; i < streams->count; i++) {
            fluxo_transcoder_free(&streams->transcoders[i]);
        }
        free(streams->transcoders);
    }
    if (streams->input != NULL && streams->input->opaque == streams) {
        streams->input->opaque = NULL;
    }
    streams->transcoders = NULL;
    streams->count = 0;
    streams->input = NULL;
    streams->draining = 0;
    streams->pending_error = 0;
}

int fluxo_streams_read(FluxoStreams *streams, AVPacket *packet) {
    AVFormatContext *input = streams->input;
    for (;;) {
        if (streams->transcoders != NULL) {
            for (unsigned int i = 0; i < streams->count; i++) {
                FluxoTranscoder *t = streams->transcoders[i];
                if (t != NULL && fluxo_queue_pop(&t->queue, packet)) {
                    packet->stream_index = (int)i;
                    return 0;
                }
            }
        }
        if (streams->draining) {
            return streams->pending_error;
        }
        int ret = av_read_frame(input, packet);
        if (ret < 0) {
            if (ret == AVERROR(EAGAIN) || streams->transcoders == NULL) {
                return ret;
            }
            // The end (or a failure) of the input: what the converters hold comes first.
            int any = 0;
            for (unsigned int i = 0; i < streams->count; i++) {
                if (streams->transcoders[i] != NULL) {
                    int drained = fluxo_transcoder_send(streams->transcoders[i], NULL);
                    if (drained == AVERROR(ENOMEM) || drained == FLUXO_ERROR_ENCODER_UNAVAILABLE) {
                        return drained;
                    }
                    any = 1;
                }
            }
            if (!any) {
                return ret;
            }
            streams->draining = 1;
            streams->pending_error = ret;
            continue;
        }
        unsigned int index = (unsigned int)packet->stream_index;
        if (streams->adjust != NULL && packet->stream_index >= 0 && index < input->nb_streams) {
            streams->adjust(streams->adjust_opaque, packet, input->streams[index]);
        }
        if (packet->stream_index >= 0 && index < streams->count && streams->transcoders != NULL && streams->transcoders[index] != NULL) {
            ret = fluxo_transcoder_send(streams->transcoders[index], packet);
            av_packet_unref(packet);
            if (ret < 0) {
                return ret;
            }
            continue;
        }
        return 0;
    }
}

void fluxo_streams_reset(FluxoStreams *streams) {
    if (streams->transcoders != NULL) {
        for (unsigned int i = 0; i < streams->count; i++) {
            if (streams->transcoders[i] != NULL) {
                fluxo_transcoder_reset(streams->transcoders[i]);
            }
        }
    }
    streams->draining = 0;
    streams->pending_error = 0;
}

void fluxo_streams_set_key_times(FluxoStreams *streams, const int64_t *times, int count) {
    if (streams->transcoders == NULL) {
        return;
    }
    for (unsigned int i = 0; i < streams->count; i++) {
        FluxoTranscoder *t = streams->transcoders[i];
        if (t != NULL && t->type == AVMEDIA_TYPE_VIDEO) {
            t->key_times = times;
            t->key_count = count;
            t->key_cursor = -1;
        }
    }
}

static const FluxoStreams *fluxo_streams_of(const AVFormatContext *input) {
    const FluxoStreams *streams = input != NULL ? input->opaque : NULL;
    return streams != NULL && streams->input == input ? streams : NULL;
}

const AVCodecParameters *fluxo_stream_parameters(const AVFormatContext *input, unsigned int index) {
    const FluxoStreams *streams = fluxo_streams_of(input);
    if (streams != NULL && streams->transcoders != NULL && index < streams->count && streams->transcoders[index] != NULL) {
        return streams->transcoders[index]->parameters;
    }
    return input->streams[index]->codecpar;
}

int fluxo_stream_is_converted(const AVFormatContext *input, unsigned int index) {
    const FluxoStreams *streams = fluxo_streams_of(input);
    return streams != NULL && streams->transcoders != NULL && index < streams->count && streams->transcoders[index] != NULL;
}

int fluxo_streams_video_stalled(const FluxoStreams *streams) {
    if (streams == NULL || streams->transcoders == NULL) {
        return 0;
    }
    for (unsigned int i = 0; i < streams->count; i++) {
        const FluxoTranscoder *t = streams->transcoders[i];
        if (t != NULL && t->type == AVMEDIA_TYPE_VIDEO) {
            return t->encoder_failures > FLUXO_ENCODER_RETRIES;
        }
    }
    return 0;
}
