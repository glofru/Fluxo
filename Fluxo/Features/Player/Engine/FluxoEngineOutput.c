//
//  FluxoEngineOutput.c
//  Fluxo
//
//  The muxers fed with the copied packets of the input (FluxoOutput): stream mapping, ADTS to raw AAC, timestamps.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

// MARK: - Outputs

void fluxo_output_free(FluxoOutput *output) {
    if (output->context != NULL) {
        if (output->context->pb != NULL && !(output->context->oformat->flags & AVFMT_NOFILE)) {
            avio_closep(&output->context->pb);
        }
        avformat_free_context(output->context);
        output->context = NULL;
    }
    free(output->stream_map);
    output->stream_map = NULL;
    output->stream_map_size = 0;
    if (output->filters != NULL) {
        for (unsigned int i = 0; i < output->filter_count; i++) {
            av_bsf_free(&output->filters[i]);
        }
        free(output->filters);
        output->filters = NULL;
    }
    output->filter_count = 0;
    output->convert_adts = 0;
    free(output->last_dts);
    output->last_dts = NULL;
    output->header_written = 0;
    output->video_index = -1;
    output->wait_keyframe = 0;
}

// Whether `output` copies `stream`, the `audio_ordinal`-th supported audio stream of its input when it is audio.
static int fluxo_output_selects(const FluxoOutput *output, const AVStream *stream, int audio_ordinal) {
    if (!fluxo_is_stream_supported(stream)) {
        return 0;
    }
    if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
        return !output->exclude_video;
    }
    if (output->audio_selection < 0) {
        return 0;
    }
    return output->audio_selection == 0 || output->audio_selection == audio_ordinal + 1;
}

// Maps the streams of `input` to the existing output streams with the same media type and codec.
// Returns the number of mapped streams or a negative error.
int fluxo_output_map_input(FluxoOutput *output, AVFormatContext *input) {
    int *map = realloc(output->stream_map, sizeof(int) * (input->nb_streams > 0 ? input->nb_streams : 1));
    if (map == NULL) {
        return AVERROR(ENOMEM);
    }
    output->stream_map = map;
    output->stream_map_size = input->nb_streams;

    unsigned int output_count = output->context->nb_streams;
    char *used = calloc(output_count > 0 ? output_count : 1, 1);
    if (used == NULL) {
        return AVERROR(ENOMEM);
    }

    int mapped = 0;
    int audio_ordinal = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        map[i] = -1;
        AVStream *in_stream = input->streams[i];
        int is_audio = fluxo_is_stream_supported(in_stream) && in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO;
        int selected = fluxo_output_selects(output, in_stream, audio_ordinal);
        if (is_audio) {
            audio_ordinal++;
        }
        if (!selected) {
            continue;
        }
        const AVCodecParameters *in_par = fluxo_stream_parameters(input, i);
        for (unsigned int j = 0; j < output_count; j++) {
            AVCodecParameters *out_par = output->context->streams[j]->codecpar;
            if (!used[j] && out_par->codec_type == in_par->codec_type && out_par->codec_id == in_par->codec_id) {
                used[j] = 1;
                map[i] = (int)j;
                mapped++;
                break;
            }
        }
    }
    free(used);
    return mapped;
}

// Allocates an output of `format_name` with a copy of the streams `output` selects (by default the first video
// stream and every audio stream). The file itself is not opened.
int fluxo_output_prepare(FluxoOutput *output, AVFormatContext *input, const char *format_name, const char *path) {
    output->video_index = -1;
    int ret = avformat_alloc_output_context2(&output->context, NULL, format_name, path);
    if (ret < 0 || output->context == NULL) {
        return ret < 0 ? ret : AVERROR_UNKNOWN;
    }
    // Outputs are local files and intentionally have no interrupt callback: after a cancellation
    // the trailer must still be written so that segments and recordings are finalized cleanly.

    int is_mp4 = strcmp(output->context->oformat->name, "mp4") == 0 || strcmp(output->context->oformat->name, "mov") == 0;
    int audio_ordinal = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        AVStream *in_stream = input->streams[i];
        int is_audio = fluxo_is_stream_supported(in_stream) && in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO;
        int selected = fluxo_output_selects(output, in_stream, audio_ordinal);
        if (is_audio) {
            audio_ordinal++;
        }
        if (!selected) {
            continue;
        }
        // HLS players expect a single video rendition per variant.
        if (in_stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && output->video_index >= 0) {
            continue;
        }
        // The parameters of what is written: a converted stream's (AAC, H.264), otherwise the input's.
        const AVCodecParameters *in_par = fluxo_stream_parameters(input, i);
        // A codec the container cannot carry would fail the whole header: leave that stream out.
        if (is_mp4 && avformat_query_codec(output->context->oformat, in_par->codec_id, FF_COMPLIANCE_NORMAL) != 1) {
            continue;
        }
        AVStream *out_stream = avformat_new_stream(output->context, NULL);
        if (out_stream == NULL) {
            return AVERROR(ENOMEM);
        }
        ret = avcodec_parameters_copy(out_stream->codecpar, in_par);
        if (ret < 0) {
            return ret;
        }
        out_stream->codecpar->codec_tag = 0;
        if (is_mp4 && in_par->codec_id == AV_CODEC_ID_HEVC) {
            // AVFoundation only plays HEVC in MP4 with the hvc1 sample entry.
            out_stream->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
        }
        out_stream->time_base = in_stream->time_base;
        if (in_stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            output->video_index = out_stream->index;
        }
    }

    if (output->context->nb_streams == 0) {
        return AVERROR_STREAM_NOT_FOUND;
    }
    output->last_dts = malloc(sizeof(int64_t) * output->context->nb_streams);
    if (output->last_dts == NULL) {
        return AVERROR(ENOMEM);
    }
    for (unsigned int j = 0; j < output->context->nb_streams; j++) {
        output->last_dts[j] = AV_NOPTS_VALUE;
    }
    output->wait_keyframe = output->video_index >= 0;

    ret = fluxo_output_map_input(output, input);
    return ret < 0 ? ret : 0;
}

// Converts an ADTS packet of output stream `index` in place. Returns 1 when `scratch` holds the converted
// packet (the first one carries the AudioSpecificConfig as new extradata), 0 when it must be skipped.
static int fluxo_output_convert_adts(FluxoOutput *output, int index, AVPacket *scratch) {
    unsigned int count = output->context->nb_streams;
    if (output->filters == NULL) {
        output->filters = calloc(count, sizeof(AVBSFContext *));
        if (output->filters == NULL) {
            return AVERROR(ENOMEM);
        }
        output->filter_count = count;
    }
    AVBSFContext *filter = output->filters[index];
    if (filter == NULL) {
        const AVBitStreamFilter *definition = av_bsf_get_by_name("aac_adtstoasc");
        if (definition == NULL) {
            return AVERROR_BSF_NOT_FOUND;
        }
        int ret = av_bsf_alloc(definition, &filter);
        if (ret < 0) {
            return ret;
        }
        AVStream *stream = output->context->streams[index];
        ret = avcodec_parameters_copy(filter->par_in, stream->codecpar);
        if (ret >= 0) {
            filter->time_base_in = stream->time_base;
            ret = av_bsf_init(filter);
        }
        if (ret < 0) {
            av_bsf_free(&filter);
            return ret;
        }
        output->filters[index] = filter;
    }
    int ret = av_bsf_send_packet(filter, scratch);
    if (ret < 0) {
        // A damaged frame: drop it, not the stream.
        return 0;
    }
    ret = av_bsf_receive_packet(filter, scratch);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        return 0;
    }
    if (ret < 0) {
        return 0;
    }
    scratch->stream_index = index;
    return 1;
}

// Copies `packet` (input time base, already adjusted) into `scratch` for `output`.
// Returns 1 when `scratch` must be written, 0 when the packet is skipped, a negative value on errors.
int fluxo_output_prepare_packet(FluxoOutput *output, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    if (!output->header_written || packet->stream_index < 0 || (unsigned int)packet->stream_index >= output->stream_map_size) {
        return 0;
    }
    int out_index = output->stream_map[packet->stream_index];
    if (out_index < 0) {
        return 0;
    }
    if (output->wait_keyframe) {
        if (out_index != output->video_index || !(packet->flags & AV_PKT_FLAG_KEY)) {
            return 0;
        }
        output->wait_keyframe = 0;
    }
    AVStream *out_stream = output->context->streams[out_index];

    int ret = av_packet_ref(scratch, packet);
    if (ret < 0) {
        return ret;
    }
    scratch->stream_index = out_index;
    av_packet_rescale_ts(scratch, in_stream->time_base, out_stream->time_base);
    scratch->pos = -1;

    if (output->convert_adts && out_stream->codecpar->codec_id == AV_CODEC_ID_AAC && scratch->size > 2 &&
        scratch->data[0] == 0xff && (scratch->data[1] & 0xf0) == 0xf0) {
        ret = fluxo_output_convert_adts(output, out_index, scratch);
        if (ret <= 0) {
            av_packet_unref(scratch);
            return ret;
        }
    }

    // Muxers reject non monotonic DTS; drop late packets and nudge duplicates.
    int64_t last = output->last_dts[out_index];
    if (scratch->dts != AV_NOPTS_VALUE && last != AV_NOPTS_VALUE) {
        if (scratch->dts < last) {
            av_packet_unref(scratch);
            return 0;
        }
        if (scratch->dts == last) {
            scratch->dts = last + 1;
            if (scratch->pts != AV_NOPTS_VALUE && scratch->pts < scratch->dts) {
                scratch->pts = scratch->dts;
            }
        }
    }
    return 1;
}

// Writes a packet prepared by fluxo_output_prepare_packet. `scratch` is always reset.
int fluxo_output_commit(FluxoOutput *output, AVPacket *scratch) {
    if (scratch->dts != AV_NOPTS_VALUE) {
        output->last_dts[scratch->stream_index] = scratch->dts;
    }
    // The input is already interleaved by the demuxer, so packets are written directly. This keeps
    // the HLS segment boundaries exact (no packet waits in an interleaving queue).
    int ret = av_write_frame(output->context, scratch);
    av_packet_unref(scratch);
    if (ret == AVERROR(EINVAL)) {
        // Invalid timestamps on a single packet should not stop a live stream.
        return 0;
    }
    return ret < 0 ? ret : 0;
}

int64_t fluxo_packet_time(const AVPacket *packet, const AVStream *stream) {
    int64_t ts = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    if (ts == AV_NOPTS_VALUE) {
        return AV_NOPTS_VALUE;
    }
    return av_rescale_q(ts, stream->time_base, AV_TIME_BASE_Q);
}
