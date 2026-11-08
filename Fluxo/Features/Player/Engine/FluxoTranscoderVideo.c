//
//  FluxoTranscoderVideo.c
//  Fluxo
//
//  Video conversion: decoding (VP9 in hardware where the device can), deinterlacing, and the H.264 encoder
//  of VideoToolbox with its key frames.
//
//  Part of the converter of the remux engine (FluxoTranscoder.c), see FluxoTranscoderInternal.h.
//

#include "FluxoTranscoderInternal.h"

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

int fluxo_video_open_encoder(FluxoTranscoder *t) {
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

int fluxo_video_open(FluxoTranscoder *t, AVFormatContext *input, AVStream *stream) {
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

int fluxo_video_encode(FluxoTranscoder *t, AVFrame *frame) {
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
