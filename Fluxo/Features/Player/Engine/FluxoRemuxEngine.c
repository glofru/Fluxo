//
//  FluxoRemuxEngine.c
//  Fluxo
//
//  Uses only libavformat/libavcodec/libavutil API that is common to FFmpeg 6
//  (bundled iOS frameworks) and FFmpeg 8 (Homebrew on macOS).
//

#include "FluxoRemuxEngine.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// FFmpeg's public headers trigger documentation warnings that are not ours to fix.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-html"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#pragma clang diagnostic pop

// Default limit for a single blocking read/connect.
#define FLUXO_DEFAULT_IO_TIMEOUT_US (15 * 1000000LL)
// Timestamp jumps larger than this (in AV_TIME_BASE units) are treated as discontinuities.
#define FLUXO_DISCONTINUITY_THRESHOLD (10 * AV_TIME_BASE)
// Upper bound of outputs a session can feed. Only HLS is used today; recordings can be added later.
#define FLUXO_MAX_OUTPUTS 4

// One muxer fed with the copied packets of the input.
typedef struct FluxoRemuxOutput {
    AVFormatContext *context;
    // Input stream index -> output stream index (-1 when the stream is not mapped).
    int *stream_map;
    // Last DTS written per output stream, in the output stream time base.
    int64_t *last_dts;
    int header_written;
} FluxoRemuxOutput;

struct FluxoRemuxSession {
    char *input_url;
    char *user_agent;
    int64_t io_timeout_us;

    char *hls_playlist_path;
    char *hls_segment_pattern;
    double hls_segment_duration;
    int32_t hls_playlist_size;
    int32_t hls_delete_old_segments;

    FluxoRemuxStateCallback callback;
    void *context;

    atomic_bool cancel_requested;
    atomic_bool started;
    pthread_t thread;
    int thread_created;

    AVFormatContext *input;
    FluxoRemuxOutput outputs[FLUXO_MAX_OUTPUTS];
    int output_count;

    // Offset (AV_TIME_BASE units) added to every packet so that the output starts near zero
    // and stays continuous across input timestamp discontinuities.
    int64_t timestamp_offset;
    int64_t last_input_dts;
};

static pthread_once_t fluxo_init_once = PTHREAD_ONCE_INIT;

static void fluxo_global_init(void) {
    avformat_network_init();
    av_log_set_level(AV_LOG_ERROR);
}

static char *fluxo_strdup(const char *value) {
    if (value == NULL || value[0] == '\0') {
        return NULL;
    }
    return strdup(value);
}

static void fluxo_notify(FluxoRemuxSession *session, FluxoRemuxState state, int error_code, const char *message) {
    if (session->callback != NULL) {
        session->callback(session->context, state, (int32_t)error_code, message);
    }
}

static void fluxo_notify_error(FluxoRemuxSession *session, int error_code, const char *what) {
    char reason[AV_ERROR_MAX_STRING_SIZE] = {0};
    char message[512] = {0};
    av_strerror(error_code, reason, sizeof(reason));
    snprintf(message, sizeof(message), "%s: %s", what, reason);
    fluxo_notify(session, FluxoRemuxStateFailed, error_code, message);
}

static int fluxo_interrupt_callback(void *opaque) {
    FluxoRemuxSession *session = opaque;
    return atomic_load(&session->cancel_requested) ? 1 : 0;
}

static int fluxo_is_stream_supported(const AVStream *stream) {
    if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) {
        return 0;
    }
    enum AVMediaType type = stream->codecpar->codec_type;
    return type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO;
}

// MARK: - Input

static int fluxo_open_input(FluxoRemuxSession *session) {
    AVFormatContext *input = avformat_alloc_context();
    if (input == NULL) {
        return AVERROR(ENOMEM);
    }
    input->interrupt_callback.callback = fluxo_interrupt_callback;
    input->interrupt_callback.opaque = session;

    char timeout[32];
    snprintf(timeout, sizeof(timeout), "%lld", (long long)session->io_timeout_us);

    AVDictionary *options = NULL;
    av_dict_set(&options, "rw_timeout", timeout, 0);
    // HTTP specific options; ignored by other protocols.
    av_dict_set(&options, "reconnect", "1", 0);
    av_dict_set(&options, "reconnect_streamed", "1", 0);
    av_dict_set(&options, "reconnect_on_network_error", "1", 0);
    av_dict_set(&options, "reconnect_delay_max", "5", 0);
    if (session->user_agent != NULL) {
        av_dict_set(&options, "user_agent", session->user_agent, 0);
    }
    // Keep the start-up latency low: live inputs rarely need more than 3 seconds of probing.
    av_dict_set(&options, "analyzeduration", "3000000", 0);

    int ret = avformat_open_input(&input, session->input_url, NULL, &options);
    av_dict_free(&options);
    if (ret < 0) {
        // avformat_open_input frees the context on failure.
        return ret;
    }
    session->input = input;

    ret = avformat_find_stream_info(input, NULL);
    if (ret < 0) {
        return ret;
    }

    int64_t start = input->start_time;
    session->timestamp_offset = start == AV_NOPTS_VALUE ? 0 : -start;
    session->last_input_dts = AV_NOPTS_VALUE;
    return 0;
}

// MARK: - Outputs

static void fluxo_output_free(FluxoRemuxOutput *output) {
    if (output->context != NULL) {
        if (output->context->pb != NULL && !(output->context->oformat->flags & AVFMT_NOFILE)) {
            avio_closep(&output->context->pb);
        }
        avformat_free_context(output->context);
        output->context = NULL;
    }
    free(output->stream_map);
    output->stream_map = NULL;
    free(output->last_dts);
    output->last_dts = NULL;
    output->header_written = 0;
}

// Creates an output of `format_name` at `path` with every supported input stream copied.
static int fluxo_output_prepare(FluxoRemuxSession *session, FluxoRemuxOutput *output, const char *format_name, const char *path) {
    AVFormatContext *input = session->input;
    int ret = avformat_alloc_output_context2(&output->context, NULL, format_name, path);
    if (ret < 0 || output->context == NULL) {
        return ret < 0 ? ret : AVERROR_UNKNOWN;
    }
    // Outputs are local files and intentionally have no interrupt callback: after a cancellation
    // the trailer must still be written so that segments and playlists are finalized cleanly.

    output->stream_map = malloc(sizeof(int) * input->nb_streams);
    output->last_dts = malloc(sizeof(int64_t) * input->nb_streams);
    if (output->stream_map == NULL || output->last_dts == NULL) {
        return AVERROR(ENOMEM);
    }

    int mapped = 0;
    int has_video = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        AVStream *in_stream = input->streams[i];
        output->stream_map[i] = -1;
        output->last_dts[i] = AV_NOPTS_VALUE;

        if (!fluxo_is_stream_supported(in_stream)) {
            continue;
        }
        // HLS players expect a single video rendition per variant.
        if (in_stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            if (has_video) {
                continue;
            }
            has_video = 1;
        }

        AVStream *out_stream = avformat_new_stream(output->context, NULL);
        if (out_stream == NULL) {
            return AVERROR(ENOMEM);
        }
        ret = avcodec_parameters_copy(out_stream->codecpar, in_stream->codecpar);
        if (ret < 0) {
            return ret;
        }
        out_stream->codecpar->codec_tag = 0;
        out_stream->time_base = in_stream->time_base;
        output->stream_map[i] = out_stream->index;
        mapped++;
    }

    if (mapped == 0) {
        return AVERROR_STREAM_NOT_FOUND;
    }

    if (!(output->context->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&output->context->pb, path, AVIO_FLAG_WRITE);
        if (ret < 0) {
            return ret;
        }
    }
    return 0;
}

static int fluxo_output_write_header(FluxoRemuxOutput *output, AVDictionary **options) {
    int ret = avformat_write_header(output->context, options);
    if (ret >= 0) {
        output->header_written = 1;
    }
    return ret;
}

static int fluxo_open_hls_output(FluxoRemuxSession *session, FluxoRemuxOutput *output) {
    int ret = fluxo_output_prepare(session, output, "hls", session->hls_playlist_path);
    if (ret < 0) {
        return ret;
    }

    char value[64];
    AVDictionary *options = NULL;
    snprintf(value, sizeof(value), "%g", session->hls_segment_duration);
    av_dict_set(&options, "hls_time", value, 0);
    snprintf(value, sizeof(value), "%d", session->hls_playlist_size);
    av_dict_set(&options, "hls_list_size", value, 0);
    // temp_file: playlists and segments are written to a temporary file and renamed when complete,
    // so the HTTP server never serves a partially written file.
    av_dict_set(&options, "hls_flags", session->hls_delete_old_segments ? "delete_segments+temp_file" : "temp_file", 0);
    if (session->hls_segment_pattern != NULL) {
        av_dict_set(&options, "hls_segment_filename", session->hls_segment_pattern, 0);
    }

    ret = fluxo_output_write_header(output, &options);
    av_dict_free(&options);
    return ret;
}

// MARK: - Packet loop

// Applies the session offset and handles input timestamp discontinuities (e.g. MPEG-TS wrap or encoder restarts).
static void fluxo_adjust_timestamps(FluxoRemuxSession *session, AVPacket *packet, const AVStream *in_stream) {
    if (packet->dts != AV_NOPTS_VALUE) {
        int64_t dts = av_rescale_q(packet->dts, in_stream->time_base, AV_TIME_BASE_Q) + session->timestamp_offset;
        int discontinuous_input = (session->input->iformat->flags & AVFMT_TS_DISCONT) != 0;
        if (discontinuous_input && session->last_input_dts != AV_NOPTS_VALUE) {
            int64_t delta = dts - session->last_input_dts;
            if (delta > FLUXO_DISCONTINUITY_THRESHOLD || delta < -FLUXO_DISCONTINUITY_THRESHOLD) {
                session->timestamp_offset -= delta;
                dts -= delta;
            }
        }
        if (session->last_input_dts == AV_NOPTS_VALUE || dts > session->last_input_dts) {
            session->last_input_dts = dts;
        }
    }

    int64_t offset = av_rescale_q(session->timestamp_offset, AV_TIME_BASE_Q, in_stream->time_base);
    if (packet->dts != AV_NOPTS_VALUE) {
        packet->dts += offset;
    }
    if (packet->pts != AV_NOPTS_VALUE) {
        packet->pts += offset;
    }
}

// Writes `packet` (input time base, already adjusted) to `output`. Returns a negative value only on fatal errors.
static int fluxo_output_write_packet(FluxoRemuxOutput *output, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    int out_index = output->stream_map[packet->stream_index];
    if (out_index < 0 || !output->header_written) {
        return 0;
    }
    AVStream *out_stream = output->context->streams[out_index];

    int ret = av_packet_ref(scratch, packet);
    if (ret < 0) {
        return ret;
    }
    scratch->stream_index = out_index;
    av_packet_rescale_ts(scratch, in_stream->time_base, out_stream->time_base);
    scratch->pos = -1;

    // Muxers reject non monotonic DTS; drop late packets and nudge duplicates.
    int64_t last = output->last_dts[packet->stream_index];
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
    if (scratch->dts != AV_NOPTS_VALUE) {
        output->last_dts[packet->stream_index] = scratch->dts;
    }

    // Takes ownership of the packet data and resets `scratch`.
    ret = av_interleaved_write_frame(output->context, scratch);
    if (ret == AVERROR(EINVAL)) {
        // Invalid timestamps on a single packet should not stop a live stream.
        return 0;
    }
    return ret;
}

static int fluxo_run_loop(FluxoRemuxSession *session) {
    AVPacket *packet = av_packet_alloc();
    AVPacket *scratch = av_packet_alloc();
    if (packet == NULL || scratch == NULL) {
        av_packet_free(&packet);
        av_packet_free(&scratch);
        return AVERROR(ENOMEM);
    }

    int ret = 0;
    while (!atomic_load(&session->cancel_requested)) {
        ret = av_read_frame(session->input, packet);
        if (ret == AVERROR(EAGAIN)) {
            ret = 0;
            continue;
        }
        if (ret < 0) {
            break;
        }

        if (packet->stream_index < 0 || (unsigned int)packet->stream_index >= session->input->nb_streams) {
            av_packet_unref(packet);
            continue;
        }

        AVStream *in_stream = session->input->streams[packet->stream_index];
        fluxo_adjust_timestamps(session, packet, in_stream);

        for (int i = 0; i < session->output_count && ret >= 0; i++) {
            ret = fluxo_output_write_packet(&session->outputs[i], packet, in_stream, scratch);
        }
        av_packet_unref(packet);
        if (ret < 0) {
            break;
        }
    }

    av_packet_free(&packet);
    av_packet_free(&scratch);
    return ret;
}

static void fluxo_close_all(FluxoRemuxSession *session) {
    for (int i = 0; i < session->output_count; i++) {
        FluxoRemuxOutput *output = &session->outputs[i];
        if (output->header_written) {
            // Flushes the last segment and finalizes the playlist (EXT-X-ENDLIST for HLS).
            av_write_trailer(output->context);
        }
        fluxo_output_free(output);
    }
    session->output_count = 0;
    if (session->input != NULL) {
        avformat_close_input(&session->input);
    }
}

static void *fluxo_thread_main(void *arg) {
    FluxoRemuxSession *session = arg;
    fluxo_notify(session, FluxoRemuxStateOpening, 0, NULL);

    int ret = fluxo_open_input(session);
    const char *stage = "Unable to open the stream";
    if (ret >= 0) {
        stage = "Unable to create the HLS output";
        ret = fluxo_open_hls_output(session, &session->outputs[0]);
        session->output_count = 1;
    }
    if (ret >= 0) {
        fluxo_notify(session, FluxoRemuxStateRunning, 0, NULL);
        stage = "Stream interrupted";
        ret = fluxo_run_loop(session);
    }

    fluxo_close_all(session);

    if (atomic_load(&session->cancel_requested)) {
        fluxo_notify(session, FluxoRemuxStateCancelled, 0, NULL);
    } else if (ret == AVERROR_EOF || ret >= 0) {
        fluxo_notify(session, FluxoRemuxStateFinished, 0, NULL);
    } else {
        fluxo_notify_error(session, ret, stage);
    }
    return NULL;
}

// MARK: - Public API

FluxoRemuxSession *fluxo_remux_create(const FluxoRemuxConfig *config, FluxoRemuxStateCallback callback, void *context) {
    if (config == NULL || config->input_url == NULL || config->hls.playlist_path == NULL) {
        return NULL;
    }
    pthread_once(&fluxo_init_once, fluxo_global_init);

    FluxoRemuxSession *session = calloc(1, sizeof(FluxoRemuxSession));
    if (session == NULL) {
        return NULL;
    }
    session->input_url = fluxo_strdup(config->input_url);
    session->user_agent = fluxo_strdup(config->user_agent);
    session->io_timeout_us = config->io_timeout_us > 0 ? config->io_timeout_us : FLUXO_DEFAULT_IO_TIMEOUT_US;
    session->hls_playlist_path = fluxo_strdup(config->hls.playlist_path);
    session->hls_segment_pattern = fluxo_strdup(config->hls.segment_path_pattern);
    session->hls_segment_duration = config->hls.segment_duration > 0 ? config->hls.segment_duration : 2.0;
    session->hls_playlist_size = config->hls.playlist_size >= 0 ? config->hls.playlist_size : 0;
    session->hls_delete_old_segments = config->hls.delete_old_segments;
    session->callback = callback;
    session->context = context;
    atomic_init(&session->cancel_requested, false);
    atomic_init(&session->started, false);

    if (session->input_url == NULL || session->hls_playlist_path == NULL) {
        fluxo_remux_destroy(session);
        return NULL;
    }
    return session;
}

int32_t fluxo_remux_start(FluxoRemuxSession *session) {
    if (session == NULL || atomic_exchange(&session->started, true)) {
        return -1;
    }

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 1024 * 1024);
    int ret = pthread_create(&session->thread, &attributes, fluxo_thread_main, session);
    pthread_attr_destroy(&attributes);
    if (ret != 0) {
        return -ret;
    }
    session->thread_created = 1;
    return 0;
}

void fluxo_remux_cancel(FluxoRemuxSession *session) {
    if (session != NULL) {
        atomic_store(&session->cancel_requested, true);
    }
}

void fluxo_remux_destroy(FluxoRemuxSession *session) {
    if (session == NULL) {
        return;
    }
    fluxo_remux_cancel(session);
    if (session->thread_created) {
        pthread_join(session->thread, NULL);
        session->thread_created = 0;
    }
    free(session->input_url);
    free(session->user_agent);
    free(session->hls_playlist_path);
    free(session->hls_segment_pattern);
    free(session);
}
