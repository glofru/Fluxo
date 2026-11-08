//
//  FluxoTranscoderAudio.c
//  Fluxo
//
//  Audio conversion: decoding, resampling and the AAC-LC encoder.
//
//  Part of the converter of the remux engine (FluxoTranscoder.c), see FluxoTranscoderInternal.h.
//

#include "FluxoTranscoderInternal.h"

// MARK: - Audio

static const int fluxo_aac_rates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000};

int fluxo_audio_open_encoder(FluxoTranscoder *t, int sample_rate, const AVChannelLayout *layout) {
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

int fluxo_audio_open(FluxoTranscoder *t, AVStream *stream) {
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

int fluxo_audio_push(FluxoTranscoder *t, AVFrame *frame) {
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

int fluxo_audio_finish(FluxoTranscoder *t) {
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
