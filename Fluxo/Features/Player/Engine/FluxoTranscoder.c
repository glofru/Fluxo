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
//  The video and audio converters are in FluxoTranscoderVideo.c and FluxoTranscoderAudio.c; the three files
//  share FluxoTranscoderInternal.h.
//

#include "FluxoTranscoderInternal.h"

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

int fluxo_test_refused(int64_t time) {
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
int fluxo_drain_encoder(FluxoTranscoder *t, AVRational from) {
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
