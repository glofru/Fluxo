//
//  FluxoRemuxEngine.c
//  Fluxo
//
//  Uses only libavformat/libavcodec/libavutil API that is common to FFmpeg 6
//  (bundled iOS frameworks) and FFmpeg 8 (Homebrew on macOS).
//
//  Threading: everything except the public request functions runs on the engine thread.
//  Requests coming from other threads (cancel, recording) go through atomics and a mutex.
//

#include "FluxoRemuxEngine.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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
#include <libavutil/opt.h>
#pragma clang diagnostic pop

// Default limit for a single blocking read/connect.
#define FLUXO_DEFAULT_IO_TIMEOUT_US (15 * 1000000LL)
// Timestamp jumps larger than this (in AV_TIME_BASE units) are treated as discontinuities.
#define FLUXO_DISCONTINUITY_THRESHOLD (10 * AV_TIME_BASE)
// Default number of consecutive reconnection attempts for live inputs.
#define FLUXO_DEFAULT_RECONNECT_ATTEMPTS 10
// Longest pause between two reconnection attempts.
#define FLUXO_MAX_RECONNECT_DELAY_US (8 * 1000000LL)
// Segments removed from the playlist are deleted only after this many newer removals, so that a
// player that just read the old playlist can still download them.
#define FLUXO_RETIRED_SEGMENTS 3
// Gap inserted between the last packet before a reconnection and the first one after it.
#define FLUXO_RECONNECT_GAP (AV_TIME_BASE / 10)

// MARK: - Types

// One muxer fed with the copied packets of the input.
typedef struct FluxoOutput {
    AVFormatContext *context;
    // Input stream index -> output stream index (-1 when the stream is not mapped).
    int *stream_map;
    unsigned int stream_map_size;
    // Last DTS written per output stream, in the output stream time base.
    int64_t *last_dts;
    // Output index of the video stream, or -1.
    int video_index;
    // Drop packets until the next video key frame so that the output starts decodable.
    int wait_keyframe;
    int header_written;
} FluxoOutput;

typedef struct FluxoSegment {
    int64_t sequence;
    double duration;
    int64_t bytes;
    int64_t wallclock_ms;
    int discontinuity;
} FluxoSegment;

typedef struct FluxoHLS {
    FluxoOutput output;
    char *playlist_path;
    char *playlist_tmp_path;
    char *segment_prefix;
    // File name part of segment_prefix (points into segment_prefix).
    const char *segment_base_name;
    double segment_duration;
    double max_window_duration;
    int64_t max_window_bytes;
    int min_window_segments;
    // Live playlists carry EXT-X-PROGRAM-DATE-TIME (wall clock of each segment); on-demand ones do not.
    int program_date_time;

    FluxoSegment *segments;
    int count;
    int capacity;
    double window_duration;
    int64_t window_bytes;
    int64_t discontinuity_sequence;
    int target_duration;

    int64_t retired[FLUXO_RETIRED_SEGMENTS];
    int retired_count;

    int64_t next_sequence;
    int64_t segments_written;

    // Current segment.
    int segment_open;
    int64_t segment_start_time;  // AV_TIME_BASE units, AV_NOPTS_VALUE until the first packet
    int64_t segment_wallclock_ms;
    int64_t last_reference_time;
    int segment_discontinuity;
    // Output stream used to decide where segments are cut (video if present).
    int reference_stream;
} FluxoHLS;

typedef struct FluxoRecording {
    FluxoOutput output;
    char *path;
    int active;
    int64_t first_time;
    int64_t last_time;
} FluxoRecording;

// A requested recording that was cancelled or replaced before the engine opened it. The engine
// still reports it (RecordingStopped) so that the caller always gets a terminal recording event.
typedef struct FluxoDiscardedRecording {
    char *path;
    struct FluxoDiscardedRecording *next;
} FluxoDiscardedRecording;

struct FluxoRemuxSession {
    char *input_url;
    char *user_agent;
    int64_t io_timeout_us;
    int is_live;
    int max_reconnect_attempts;

    FluxoRemuxEventCallback callback;
    void *context;

    atomic_bool cancel_requested;
    atomic_bool started;
    pthread_t thread;
    int thread_created;

    // Recording requests from other threads.
    pthread_mutex_t request_lock;
    atomic_bool request_pending;
    char *pending_recording_path;
    int pending_recording_stop;
    FluxoDiscardedRecording *discarded_recordings;

    FluxoRemuxState state;
    int reconnect_attempt;
    // Set when the HLS output itself failed (disk full, ...): never recovered by reconnecting.
    int output_failed;

    AVFormatContext *input;
    FluxoHLS hls;
    FluxoRecording recording;

    // Offset (AV_TIME_BASE units) added to every packet so that the output starts near zero
    // and stays continuous across input timestamp discontinuities and reconnections.
    int64_t timestamp_offset;
    int64_t last_input_dts;
    int rebase_pending;
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

static int64_t fluxo_wallclock_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int fluxo_is_cancelled(FluxoRemuxSession *session) {
    return atomic_load(&session->cancel_requested) ? 1 : 0;
}

static int fluxo_interrupt_callback(void *opaque) {
    return fluxo_is_cancelled(opaque);
}

static int fluxo_is_stream_supported(const AVStream *stream) {
    if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) {
        return 0;
    }
    enum AVMediaType type = stream->codecpar->codec_type;
    return type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO;
}

// MARK: - Events

// `explicit_path` reports a recording that was never opened; otherwise the active recording is reported.
static void fluxo_emit_with_path(FluxoRemuxSession *session, FluxoRemuxEventKind kind, int error_code, const char *message,
                                 const char *explicit_path) {
    if (session->callback == NULL) {
        return;
    }
    FluxoRemuxEvent event;
    memset(&event, 0, sizeof(event));
    event.kind = kind;
    event.state = session->state;
    event.error_code = (int32_t)error_code;
    event.message = message;
    event.reconnect_attempt = session->state == FluxoRemuxStateReconnecting ? session->reconnect_attempt : 0;
    event.segments_written = session->hls.segments_written;
    event.window_segment_count = session->hls.count;
    event.window_duration = session->hls.window_duration;
    event.window_bytes = session->hls.window_bytes;

    FluxoRecording *recording = &session->recording;
    if (explicit_path != NULL) {
        event.recording_path = explicit_path;
    } else if (recording->path != NULL) {
        event.recording_path = recording->path;
        if (recording->first_time != AV_NOPTS_VALUE && recording->last_time != AV_NOPTS_VALUE) {
            event.recording_duration = (double)(recording->last_time - recording->first_time) / AV_TIME_BASE;
        }
        if (recording->output.context != NULL && recording->output.context->pb != NULL) {
            event.recording_bytes = avio_tell(recording->output.context->pb);
        }
    }
    session->callback(session->context, &event);
}

static void fluxo_emit(FluxoRemuxSession *session, FluxoRemuxEventKind kind, int error_code, const char *message) {
    fluxo_emit_with_path(session, kind, error_code, message, NULL);
}

static void fluxo_set_state(FluxoRemuxSession *session, FluxoRemuxState state, int error_code, const char *message) {
    session->state = state;
    fluxo_emit(session, FluxoRemuxEventStateChanged, error_code, message);
}

static void fluxo_format_error(char *buffer, size_t size, int error_code, const char *what) {
    char reason[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(error_code, reason, sizeof(reason));
    snprintf(buffer, size, "%s: %s", what, reason);
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
    // HTTP specific options; ignored by other protocols. They cover short drops inside a connection,
    // longer outages are handled by the reconnection loop of the engine.
    av_dict_set(&options, "reconnect", "1", 0);
    av_dict_set(&options, "reconnect_streamed", "1", 0);
    av_dict_set(&options, "reconnect_on_network_error", "1", 0);
    av_dict_set(&options, "reconnect_delay_max", "4", 0);
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
        avformat_close_input(&session->input);
        return ret;
    }
    return 0;
}

// True when the input has a known size and everything up to it was read. Live inputs have no
// size (or an unreachable placeholder size), so an EOF there means the connection was lost.
static int fluxo_input_reached_end_of_file(FluxoRemuxSession *session) {
    if (session->input == NULL || session->input->pb == NULL) {
        return 0;
    }
    int64_t size = avio_size(session->input->pb);
    return size > 0 && avio_tell(session->input->pb) >= size;
}

static void fluxo_close_input(FluxoRemuxSession *session) {
    if (session->input != NULL) {
        avformat_close_input(&session->input);
    }
}

// MARK: - Outputs

static void fluxo_output_free(FluxoOutput *output) {
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
    free(output->last_dts);
    output->last_dts = NULL;
    output->header_written = 0;
    output->video_index = -1;
    output->wait_keyframe = 0;
}

// Maps the streams of `input` to the existing output streams with the same media type and codec.
// Returns the number of mapped streams or a negative error.
static int fluxo_output_map_input(FluxoOutput *output, AVFormatContext *input) {
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
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        map[i] = -1;
        AVStream *in_stream = input->streams[i];
        if (!fluxo_is_stream_supported(in_stream)) {
            continue;
        }
        for (unsigned int j = 0; j < output_count; j++) {
            AVCodecParameters *out_par = output->context->streams[j]->codecpar;
            if (!used[j] && out_par->codec_type == in_stream->codecpar->codec_type && out_par->codec_id == in_stream->codecpar->codec_id) {
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

// Allocates an output of `format_name` with a copy of the first video stream and every audio stream.
// The file itself is not opened.
static int fluxo_output_prepare(FluxoOutput *output, AVFormatContext *input, const char *format_name, const char *path) {
    output->video_index = -1;
    int ret = avformat_alloc_output_context2(&output->context, NULL, format_name, path);
    if (ret < 0 || output->context == NULL) {
        return ret < 0 ? ret : AVERROR_UNKNOWN;
    }
    // Outputs are local files and intentionally have no interrupt callback: after a cancellation
    // the trailer must still be written so that segments and recordings are finalized cleanly.

    int is_mp4 = strcmp(output->context->oformat->name, "mp4") == 0 || strcmp(output->context->oformat->name, "mov") == 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        AVStream *in_stream = input->streams[i];
        if (!fluxo_is_stream_supported(in_stream)) {
            continue;
        }
        // HLS players expect a single video rendition per variant.
        if (in_stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && output->video_index >= 0) {
            continue;
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
        if (is_mp4 && in_stream->codecpar->codec_id == AV_CODEC_ID_HEVC) {
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

// Copies `packet` (input time base, already adjusted) into `scratch` for `output`.
// Returns 1 when `scratch` must be written, 0 when the packet is skipped, a negative value on errors.
static int fluxo_output_prepare_packet(FluxoOutput *output, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
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
static int fluxo_output_commit(FluxoOutput *output, AVPacket *scratch) {
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

static int64_t fluxo_packet_time(const AVPacket *packet, const AVStream *stream) {
    int64_t ts = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    if (ts == AV_NOPTS_VALUE) {
        return AV_NOPTS_VALUE;
    }
    return av_rescale_q(ts, stream->time_base, AV_TIME_BASE_Q);
}

// MARK: - HLS segmenter

static void fluxo_hls_segment_path(const FluxoHLS *hls, int64_t sequence, int temporary, char *buffer, size_t size) {
    snprintf(buffer, size, "%s-%06lld.ts%s", hls->segment_prefix, (long long)sequence, temporary ? ".tmp" : "");
}

static void fluxo_hls_delete_segment(const FluxoHLS *hls, int64_t sequence) {
    char path[PATH_MAX];
    fluxo_hls_segment_path(hls, sequence, 0, path, sizeof(path));
    unlink(path);
}

static void fluxo_hls_retire(FluxoHLS *hls, int64_t sequence) {
    if (hls->retired_count == FLUXO_RETIRED_SEGMENTS) {
        fluxo_hls_delete_segment(hls, hls->retired[0]);
        memmove(hls->retired, hls->retired + 1, sizeof(int64_t) * (FLUXO_RETIRED_SEGMENTS - 1));
        hls->retired_count--;
    }
    hls->retired[hls->retired_count++] = sequence;
}

// Drops the oldest segments while the window is over its duration or size limit.
static void fluxo_hls_prune(FluxoHLS *hls) {
    int removed = 0;
    while (hls->count - removed > hls->min_window_segments) {
        int over_duration = hls->max_window_duration > 0 && hls->window_duration > hls->max_window_duration;
        int over_size = hls->max_window_bytes > 0 && hls->window_bytes > hls->max_window_bytes;
        if (!over_duration && !over_size) {
            break;
        }
        FluxoSegment *oldest = &hls->segments[removed];
        hls->window_duration -= oldest->duration;
        hls->window_bytes -= oldest->bytes;
        if (oldest->discontinuity) {
            hls->discontinuity_sequence++;
        }
        fluxo_hls_retire(hls, oldest->sequence);
        removed++;
    }
    if (removed > 0) {
        hls->count -= removed;
        memmove(hls->segments, hls->segments + removed, sizeof(FluxoSegment) * (size_t)hls->count);
    }
}

static int fluxo_hls_write_playlist(FluxoHLS *hls, int ended) {
    FILE *file = fopen(hls->playlist_tmp_path, "w");
    if (file == NULL) {
        return AVERROR(errno);
    }
    int64_t media_sequence = hls->count > 0 ? hls->segments[0].sequence : hls->next_sequence;
    int unlimited = hls->max_window_duration <= 0 && hls->max_window_bytes <= 0;

    fprintf(file, "#EXTM3U\n#EXT-X-VERSION:3\n");
    fprintf(file, "#EXT-X-TARGETDURATION:%d\n", hls->target_duration);
    fprintf(file, "#EXT-X-MEDIA-SEQUENCE:%lld\n", (long long)media_sequence);
    if (hls->discontinuity_sequence > 0) {
        fprintf(file, "#EXT-X-DISCONTINUITY-SEQUENCE:%lld\n", (long long)hls->discontinuity_sequence);
    }
    if (unlimited) {
        // Nothing is ever removed: lets players seek back to the very beginning.
        fprintf(file, "#EXT-X-PLAYLIST-TYPE:EVENT\n");
    }
    if (hls->output.video_index >= 0) {
        fprintf(file, "#EXT-X-INDEPENDENT-SEGMENTS\n");
    }
    for (int i = 0; i < hls->count; i++) {
        const FluxoSegment *segment = &hls->segments[i];
        if (segment->discontinuity) {
            fprintf(file, "#EXT-X-DISCONTINUITY\n");
        }
        if (hls->program_date_time) {
            time_t seconds = (time_t)(segment->wallclock_ms / 1000);
            struct tm utc;
            gmtime_r(&seconds, &utc);
            char date[32];
            strftime(date, sizeof(date), "%Y-%m-%dT%H:%M:%S", &utc);
            fprintf(file, "#EXT-X-PROGRAM-DATE-TIME:%s.%03dZ\n", date, (int)(segment->wallclock_ms % 1000));
        }
        fprintf(file, "#EXTINF:%.3f,\n%s-%06lld.ts\n", segment->duration, hls->segment_base_name, (long long)segment->sequence);
    }
    if (ended) {
        fprintf(file, "#EXT-X-ENDLIST\n");
    }
    int failed = ferror(file);
    if (fclose(file) != 0 || failed) {
        unlink(hls->playlist_tmp_path);
        return AVERROR(EIO);
    }
    // Atomic replacement: the HTTP server never serves a partially written playlist.
    if (rename(hls->playlist_tmp_path, hls->playlist_path) != 0) {
        return AVERROR(errno);
    }
    return 0;
}

static int fluxo_hls_open_segment(FluxoHLS *hls) {
    char path[PATH_MAX];
    fluxo_hls_segment_path(hls, hls->next_sequence, 1, path, sizeof(path));
    int ret = avio_open(&hls->output.context->pb, path, AVIO_FLAG_WRITE);
    if (ret < 0) {
        return ret;
    }
    if (hls->segments_written > 0 || hls->count > 0) {
        // Every segment must start with PAT/PMT so that it can be decoded on its own.
        av_opt_set(hls->output.context->priv_data, "mpegts_flags", "+resend_headers", 0);
    }
    hls->segment_open = 1;
    hls->segment_start_time = AV_NOPTS_VALUE;
    hls->last_reference_time = AV_NOPTS_VALUE;
    hls->segment_wallclock_ms = fluxo_wallclock_ms();
    return 0;
}

// Closes the current segment file, publishes it and rewrites the playlist.
// `flush` drains the muxer first (not needed after av_write_trailer).
static int fluxo_hls_finish_segment(FluxoRemuxSession *session, int64_t end_time, int flush, int ended) {
    FluxoHLS *hls = &session->hls;
    if (!hls->segment_open) {
        return ended ? fluxo_hls_write_playlist(hls, 1) : 0;
    }
    AVFormatContext *context = hls->output.context;
    if (flush) {
        av_write_frame(context, NULL);
    }
    avio_flush(context->pb);
    int64_t bytes = avio_tell(context->pb);
    avio_closep(&context->pb);
    hls->segment_open = 0;

    char temporary[PATH_MAX];
    char final_path[PATH_MAX];
    fluxo_hls_segment_path(hls, hls->next_sequence, 1, temporary, sizeof(temporary));
    fluxo_hls_segment_path(hls, hls->next_sequence, 0, final_path, sizeof(final_path));

    double duration = 0;
    if (hls->segment_start_time != AV_NOPTS_VALUE && end_time != AV_NOPTS_VALUE && end_time > hls->segment_start_time) {
        duration = (double)(end_time - hls->segment_start_time) / AV_TIME_BASE;
    }
    if (bytes <= 0 || duration < 0.05) {
        // Nothing playable (e.g. cancelled right after a cut).
        unlink(temporary);
        return ended ? fluxo_hls_write_playlist(hls, 1) : 0;
    }
    if (rename(temporary, final_path) != 0) {
        return AVERROR(errno);
    }

    if (hls->count == hls->capacity) {
        int capacity = hls->capacity > 0 ? hls->capacity * 2 : 64;
        FluxoSegment *segments = realloc(hls->segments, sizeof(FluxoSegment) * (size_t)capacity);
        if (segments == NULL) {
            return AVERROR(ENOMEM);
        }
        hls->segments = segments;
        hls->capacity = capacity;
    }
    FluxoSegment *segment = &hls->segments[hls->count++];
    segment->sequence = hls->next_sequence++;
    segment->duration = duration;
    segment->bytes = bytes;
    segment->wallclock_ms = hls->segment_wallclock_ms;
    segment->discontinuity = hls->segment_discontinuity;
    hls->segment_discontinuity = 0;
    hls->window_duration += duration;
    hls->window_bytes += bytes;
    hls->segments_written++;

    // EXTINF rounded to the nearest integer must not exceed the target duration, and the target
    // should not change once published. Inputs are cut on key frames, so segments follow the GOP of
    // the stream: the first segment (written before the playlist is first published) seeds the
    // target with 50% headroom so that ordinary GOP jitter does not change it later. A longer
    // segment still raises it, because the EXTINF rule takes precedence. It never decreases.
    if (hls->segments_written == 1) {
        int seeded = (int)ceil(duration * 1.5);
        if (seeded > hls->target_duration) {
            hls->target_duration = seeded;
        }
    }
    int rounded = (int)lround(duration);
    if (rounded > hls->target_duration) {
        hls->target_duration = rounded;
    }

    fluxo_hls_prune(hls);
    int ret = fluxo_hls_write_playlist(hls, ended);
    if (ret < 0) {
        return ret;
    }
    // A segment is the proof that the (re)connection works.
    session->reconnect_attempt = 0;
    fluxo_emit(session, FluxoRemuxEventSegmentWritten, 0, NULL);
    return 0;
}

static int fluxo_hls_open(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    int ret = fluxo_output_prepare(&hls->output, session->input, "mpegts", NULL);
    if (ret < 0) {
        return ret;
    }
    hls->reference_stream = hls->output.video_index >= 0 ? hls->output.video_index : 0;
    hls->target_duration = (int)ceil(hls->segment_duration);

    ret = fluxo_hls_open_segment(hls);
    if (ret < 0) {
        return ret;
    }
    ret = avformat_write_header(hls->output.context, NULL);
    if (ret < 0) {
        return ret;
    }
    hls->output.header_written = 1;
    return 0;
}

static int fluxo_hls_write(FluxoRemuxSession *session, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    FluxoHLS *hls = &session->hls;
    int ret = fluxo_output_prepare_packet(&hls->output, packet, in_stream, scratch);
    if (ret <= 0) {
        return ret;
    }

    if (scratch->stream_index == hls->reference_stream) {
        int64_t time = fluxo_packet_time(scratch, hls->output.context->streams[scratch->stream_index]);
        if (time != AV_NOPTS_VALUE) {
            if (hls->segment_start_time == AV_NOPTS_VALUE) {
                hls->segment_start_time = time;
            } else {
                int cut_point = hls->output.video_index < 0 || (scratch->flags & AV_PKT_FLAG_KEY);
                int64_t elapsed = time - hls->segment_start_time;
                if (cut_point && elapsed >= (int64_t)(hls->segment_duration * AV_TIME_BASE)) {
                    ret = fluxo_hls_finish_segment(session, time, 1, 0);
                    if (ret >= 0) {
                        ret = fluxo_hls_open_segment(hls);
                    }
                    if (ret < 0) {
                        av_packet_unref(scratch);
                        return ret;
                    }
                    hls->segment_start_time = time;
                }
            }
            if (hls->last_reference_time == AV_NOPTS_VALUE || time > hls->last_reference_time) {
                hls->last_reference_time = time;
            }
        }
    }
    return fluxo_output_commit(&hls->output, scratch);
}

// Ends the current segment early, e.g. before a reconnection, and marks the next one as discontinuous.
static int fluxo_hls_break(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    if (!hls->output.header_written) {
        return 0;
    }
    int ret = 0;
    if (hls->segment_start_time != AV_NOPTS_VALUE) {
        ret = fluxo_hls_finish_segment(session, hls->last_reference_time, 1, 0);
        if (ret >= 0) {
            ret = fluxo_hls_open_segment(hls);
        }
    }
    hls->segment_discontinuity = 1;
    hls->output.wait_keyframe = hls->output.video_index >= 0;
    return ret;
}

static void fluxo_hls_close(FluxoRemuxSession *session, int ended) {
    FluxoHLS *hls = &session->hls;
    if (hls->output.header_written) {
        // Drains the muxer into the current segment, which is then published with EXT-X-ENDLIST.
        av_write_trailer(hls->output.context);
        if (hls->segment_open) {
            fluxo_hls_finish_segment(session, hls->last_reference_time, 0, ended);
        } else if (ended) {
            fluxo_hls_write_playlist(hls, 1);
        }
    } else if (hls->segment_open && hls->output.context != NULL) {
        char temporary[PATH_MAX];
        avio_closep(&hls->output.context->pb);
        fluxo_hls_segment_path(hls, hls->next_sequence, 1, temporary, sizeof(temporary));
        unlink(temporary);
        hls->segment_open = 0;
    }
    fluxo_output_free(&hls->output);
}

// MARK: - Recording

static void fluxo_recording_close(FluxoRemuxSession *session, int error_code, const char *message) {
    FluxoRecording *recording = &session->recording;
    if (recording->path == NULL) {
        return;
    }
    int ret = error_code;
    if (recording->output.header_written) {
        int trailer = av_write_trailer(recording->output.context);
        if (ret == 0 && trailer < 0) {
            ret = trailer;
        }
        avio_flush(recording->output.context->pb);
    }
    if (ret < 0) {
        char buffer[512];
        fluxo_format_error(buffer, sizeof(buffer), ret, message != NULL ? message : "Recording failed");
        fluxo_emit(session, FluxoRemuxEventRecordingFailed, ret, buffer);
    } else {
        fluxo_emit(session, FluxoRemuxEventRecordingStopped, 0, NULL);
    }
    fluxo_output_free(&recording->output);
    free(recording->path);
    recording->path = NULL;
    recording->active = 0;
}

static void fluxo_recording_open(FluxoRemuxSession *session, char *path) {
    FluxoRecording *recording = &session->recording;
    recording->path = path;
    recording->first_time = AV_NOPTS_VALUE;
    recording->last_time = AV_NOPTS_VALUE;

    int ret = fluxo_output_prepare(&recording->output, session->input, "mpegts", path);
    if (ret >= 0) {
        ret = avio_open(&recording->output.context->pb, path, AVIO_FLAG_WRITE);
    }
    if (ret >= 0) {
        ret = avformat_write_header(recording->output.context, NULL);
        if (ret >= 0) {
            recording->output.header_written = 1;
        }
    }
    if (ret < 0) {
        fluxo_recording_close(session, ret, "Unable to start the recording");
        return;
    }
    recording->active = 1;
    fluxo_emit(session, FluxoRemuxEventRecordingStarted, 0, NULL);
}

static int fluxo_recording_write(FluxoRemuxSession *session, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    FluxoRecording *recording = &session->recording;
    int ret = fluxo_output_prepare_packet(&recording->output, packet, in_stream, scratch);
    if (ret <= 0) {
        return ret;
    }
    int64_t time = fluxo_packet_time(scratch, recording->output.context->streams[scratch->stream_index]);
    if (time != AV_NOPTS_VALUE) {
        if (recording->first_time == AV_NOPTS_VALUE) {
            recording->first_time = time;
        }
        if (recording->last_time == AV_NOPTS_VALUE || time > recording->last_time) {
            recording->last_time = time;
        }
    }
    return fluxo_output_commit(&recording->output, scratch);
}

// Moves the queued (never opened) recording path to the discarded list. Caller holds request_lock.
static void fluxo_discard_pending_recording_locked(FluxoRemuxSession *session) {
    char *path = session->pending_recording_path;
    session->pending_recording_path = NULL;
    if (path == NULL) {
        return;
    }
    FluxoDiscardedRecording *node = malloc(sizeof(FluxoDiscardedRecording));
    if (node == NULL) {
        // Out of memory: the request is dropped without an event (the caller's own teardown still runs).
        free(path);
        return;
    }
    node->path = path;
    node->next = NULL;
    // Appended, so that the events keep the order of the requests.
    FluxoDiscardedRecording **tail = &session->discarded_recordings;
    while (*tail != NULL) {
        tail = &(*tail)->next;
    }
    *tail = node;
}

static void fluxo_free_discarded_recordings(FluxoDiscardedRecording *list) {
    while (list != NULL) {
        FluxoDiscardedRecording *next = list->next;
        free(list->path);
        free(list);
        list = next;
    }
}

// Reports (RecordingStopped, nothing written) and frees recordings that were never opened.
static void fluxo_report_discarded_recordings(FluxoRemuxSession *session, FluxoDiscardedRecording *list) {
    for (FluxoDiscardedRecording *node = list; node != NULL; node = node->next) {
        fluxo_emit_with_path(session, FluxoRemuxEventRecordingStopped, 0, NULL, node->path);
    }
    fluxo_free_discarded_recordings(list);
}

// Applies pending recording requests. Starting needs an open input; otherwise the request stays queued.
static void fluxo_process_requests(FluxoRemuxSession *session) {
    if (!atomic_load(&session->request_pending)) {
        return;
    }
    pthread_mutex_lock(&session->request_lock);
    char *path = NULL;
    int stop = session->pending_recording_stop;
    session->pending_recording_stop = 0;
    if (session->input != NULL) {
        path = session->pending_recording_path;
        session->pending_recording_path = NULL;
    }
    FluxoDiscardedRecording *discarded = session->discarded_recordings;
    session->discarded_recordings = NULL;
    atomic_store(&session->request_pending, session->pending_recording_path != NULL);
    pthread_mutex_unlock(&session->request_lock);

    fluxo_report_discarded_recordings(session, discarded);
    if ((stop || path != NULL) && session->recording.path != NULL) {
        fluxo_recording_close(session, 0, NULL);
    }
    if (path != NULL) {
        fluxo_recording_open(session, path);
    }
}

// Called when the engine thread ends: every recording request still queued gets its terminal event.
static void fluxo_drain_requests(FluxoRemuxSession *session) {
    pthread_mutex_lock(&session->request_lock);
    if (session->pending_recording_path != NULL) {
        fluxo_discard_pending_recording_locked(session);
    }
    session->pending_recording_stop = 0;
    FluxoDiscardedRecording *discarded = session->discarded_recordings;
    session->discarded_recordings = NULL;
    atomic_store(&session->request_pending, false);
    pthread_mutex_unlock(&session->request_lock);

    fluxo_report_discarded_recordings(session, discarded);
}

// MARK: - Packet loop

// Applies the session offset and handles input timestamp discontinuities (e.g. MPEG-TS wrap,
// encoder restarts or a reconnection).
static void fluxo_adjust_timestamps(FluxoRemuxSession *session, AVPacket *packet, const AVStream *in_stream) {
    if (packet->dts != AV_NOPTS_VALUE) {
        int64_t raw = av_rescale_q(packet->dts, in_stream->time_base, AV_TIME_BASE_Q);
        if (session->rebase_pending) {
            // Continue right after the last packet written before the input changed.
            int64_t target = session->last_input_dts == AV_NOPTS_VALUE ? 0 : session->last_input_dts + FLUXO_RECONNECT_GAP;
            session->timestamp_offset = target - raw;
            session->last_input_dts = AV_NOPTS_VALUE;
            session->rebase_pending = 0;
        }
        int64_t dts = raw + session->timestamp_offset;
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

// Reads the input until it ends, fails or the session is cancelled. Returns the read error
// (AVERROR_EOF at the end) or the output error, in which case `output_failed` is set.
static int fluxo_run_loop(FluxoRemuxSession *session) {
    AVPacket *packet = av_packet_alloc();
    AVPacket *scratch = av_packet_alloc();
    if (packet == NULL || scratch == NULL) {
        av_packet_free(&packet);
        av_packet_free(&scratch);
        session->output_failed = 1;
        return AVERROR(ENOMEM);
    }

    int ret = 0;
    while (!fluxo_is_cancelled(session)) {
        fluxo_process_requests(session);

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

        ret = fluxo_hls_write(session, packet, in_stream, scratch);
        if (ret < 0) {
            av_packet_unref(packet);
            session->output_failed = 1;
            break;
        }
        if (session->recording.active) {
            int recording_ret = fluxo_recording_write(session, packet, in_stream, scratch);
            if (recording_ret < 0) {
                // A full disk stops the recording, not the stream.
                fluxo_recording_close(session, recording_ret, "Recording stopped");
            }
        }
        av_packet_unref(packet);
    }

    av_packet_free(&packet);
    av_packet_free(&scratch);
    return ret;
}

// Sleeps up to `duration_us`, waking up early when the session is cancelled.
static void fluxo_wait(FluxoRemuxSession *session, int64_t duration_us) {
    while (duration_us > 0 && !fluxo_is_cancelled(session)) {
        int64_t step = duration_us < 100000 ? duration_us : 100000;
        usleep((useconds_t)step);
        duration_us -= step;
        fluxo_process_requests(session);
    }
}

// Reconnects a live input. Returns 0 once packets can flow again, a negative value to give up.
static int fluxo_reconnect(FluxoRemuxSession *session, int last_error) {
    int ret = fluxo_hls_break(session);
    if (ret < 0) {
        session->output_failed = 1;
        return ret;
    }
    fluxo_close_input(session);

    while (!fluxo_is_cancelled(session)) {
        session->reconnect_attempt++;
        if (session->max_reconnect_attempts > 0 && session->reconnect_attempt > session->max_reconnect_attempts) {
            return last_error < 0 ? last_error : AVERROR(ECONNRESET);
        }
        fluxo_set_state(session, FluxoRemuxStateReconnecting, last_error, NULL);

        // 0.5s, 1s, 2s, 4s, 8s, 8s, ...
        int shift = session->reconnect_attempt - 1 < 4 ? session->reconnect_attempt - 1 : 4;
        int64_t delay = (AV_TIME_BASE / 2) << shift;
        fluxo_wait(session, delay < FLUXO_MAX_RECONNECT_DELAY_US ? delay : FLUXO_MAX_RECONNECT_DELAY_US);
        if (fluxo_is_cancelled(session)) {
            break;
        }

        ret = fluxo_open_input(session);
        if (ret < 0) {
            last_error = ret;
            continue;
        }
        ret = fluxo_output_map_input(&session->hls.output, session->input);
        if (ret <= 0) {
            // The stream layout changed (e.g. a different codec): the playlist cannot continue.
            session->output_failed = 1;
            return ret < 0 ? ret : AVERROR_STREAM_NOT_FOUND;
        }
        if (session->recording.path != NULL) {
            ret = fluxo_output_map_input(&session->recording.output, session->input);
            if (ret <= 0) {
                fluxo_recording_close(session, ret < 0 ? ret : AVERROR_STREAM_NOT_FOUND, "Recording stopped");
            } else {
                session->recording.output.wait_keyframe = session->recording.output.video_index >= 0;
            }
        }
        session->rebase_pending = 1;
        fluxo_set_state(session, FluxoRemuxStateRunning, 0, NULL);
        return 0;
    }
    return AVERROR_EXIT;
}

static void *fluxo_thread_main(void *arg) {
    FluxoRemuxSession *session = arg;
    fluxo_set_state(session, FluxoRemuxStateOpening, 0, NULL);

    const char *stage = "Unable to open the stream";
    // Set when a live input could not be reconnected: always a failure, even if the last error was EOF.
    int reconnect_failed = 0;
    int ret = fluxo_open_input(session);
    if (ret < 0 && session->is_live && !fluxo_is_cancelled(session)) {
        // One quick retry: IPTV servers often refuse the very first connection of a burst.
        fluxo_wait(session, AV_TIME_BASE / 2);
        if (!fluxo_is_cancelled(session)) {
            ret = fluxo_open_input(session);
        }
    }
    if (ret >= 0) {
        int64_t start = session->input->start_time;
        session->timestamp_offset = start == AV_NOPTS_VALUE ? 0 : -start;
        session->last_input_dts = AV_NOPTS_VALUE;

        stage = "Unable to create the HLS output";
        ret = fluxo_hls_open(session);
    }
    if (ret >= 0) {
        fluxo_set_state(session, FluxoRemuxStateRunning, 0, NULL);
        for (;;) {
            stage = "Stream interrupted";
            ret = fluxo_run_loop(session);
            if (fluxo_is_cancelled(session) || session->output_failed || !session->is_live) {
                break;
            }
            if (ret == AVERROR_EOF && fluxo_input_reached_end_of_file(session)) {
                // A finite file served over HTTP (e.g. an on-demand .ts): it really ended.
                break;
            }
            // Live inputs never end on their own: a drop or an EOF means the connection was lost.
            stage = "Connection lost";
            ret = fluxo_reconnect(session, ret);
            if (ret < 0) {
                reconnect_failed = !fluxo_is_cancelled(session);
                break;
            }
        }
        if (session->output_failed) {
            stage = "Unable to write the stream";
        }
    }

    int cancelled = fluxo_is_cancelled(session);
    int finished = !cancelled && !reconnect_failed && !session->output_failed && (ret == AVERROR_EOF || ret >= 0);

    fluxo_recording_close(session, 0, NULL);
    fluxo_drain_requests(session);
    fluxo_hls_close(session, !cancelled);
    fluxo_close_input(session);

    if (cancelled) {
        fluxo_set_state(session, FluxoRemuxStateCancelled, 0, NULL);
    } else if (finished) {
        fluxo_set_state(session, FluxoRemuxStateFinished, 0, NULL);
    } else {
        if (ret >= 0) {
            ret = AVERROR_UNKNOWN;
        }
        char message[512];
        fluxo_format_error(message, sizeof(message), ret, stage);
        fluxo_set_state(session, FluxoRemuxStateFailed, ret, message);
    }
    return NULL;
}

// MARK: - Public API

FluxoRemuxSession *fluxo_remux_create(const FluxoRemuxConfig *config, FluxoRemuxEventCallback callback, void *context) {
    if (config == NULL || config->input_url == NULL || config->hls.playlist_path == NULL || config->hls.segment_path_prefix == NULL) {
        return NULL;
    }
    pthread_once(&fluxo_init_once, fluxo_global_init);

    FluxoRemuxSession *session = calloc(1, sizeof(FluxoRemuxSession));
    if (session == NULL) {
        return NULL;
    }
    pthread_mutex_init(&session->request_lock, NULL);
    atomic_init(&session->cancel_requested, false);
    atomic_init(&session->started, false);
    atomic_init(&session->request_pending, false);

    session->input_url = fluxo_strdup(config->input_url);
    session->user_agent = fluxo_strdup(config->user_agent);
    session->io_timeout_us = config->io_timeout_us > 0 ? config->io_timeout_us : FLUXO_DEFAULT_IO_TIMEOUT_US;
    session->is_live = config->is_live != 0;
    session->max_reconnect_attempts = config->max_reconnect_attempts == 0 ? FLUXO_DEFAULT_RECONNECT_ATTEMPTS : config->max_reconnect_attempts;
    session->callback = callback;
    session->context = context;
    session->state = FluxoRemuxStateIdle;
    session->timestamp_offset = 0;
    session->last_input_dts = AV_NOPTS_VALUE;
    session->recording.first_time = AV_NOPTS_VALUE;
    session->recording.last_time = AV_NOPTS_VALUE;
    session->recording.output.video_index = -1;

    FluxoHLS *hls = &session->hls;
    hls->output.video_index = -1;
    hls->playlist_path = fluxo_strdup(config->hls.playlist_path);
    hls->segment_prefix = fluxo_strdup(config->hls.segment_path_prefix);
    hls->segment_duration = config->hls.segment_duration > 0 ? config->hls.segment_duration : 2.0;
    hls->max_window_duration = config->hls.max_window_duration > 0 ? config->hls.max_window_duration : 0;
    hls->max_window_bytes = config->hls.max_window_bytes > 0 ? config->hls.max_window_bytes : 0;
    hls->min_window_segments = config->hls.min_window_segments > 0 ? config->hls.min_window_segments : 3;
    hls->program_date_time = session->is_live;
    hls->segment_start_time = AV_NOPTS_VALUE;
    hls->last_reference_time = AV_NOPTS_VALUE;

    if (session->input_url == NULL || hls->playlist_path == NULL || hls->segment_prefix == NULL) {
        fluxo_remux_destroy(session);
        return NULL;
    }
    size_t length = strlen(hls->playlist_path) + 5;
    hls->playlist_tmp_path = malloc(length);
    if (hls->playlist_tmp_path == NULL) {
        fluxo_remux_destroy(session);
        return NULL;
    }
    snprintf(hls->playlist_tmp_path, length, "%s.tmp", hls->playlist_path);
    const char *slash = strrchr(hls->segment_prefix, '/');
    hls->segment_base_name = slash != NULL ? slash + 1 : hls->segment_prefix;
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

int32_t fluxo_remux_start_recording(FluxoRemuxSession *session, const char *path) {
    if (session == NULL || path == NULL || path[0] == '\0') {
        return -1;
    }
    char *copy = strdup(path);
    if (copy == NULL) {
        return -1;
    }
    pthread_mutex_lock(&session->request_lock);
    fluxo_discard_pending_recording_locked(session);
    session->pending_recording_path = copy;
    session->pending_recording_stop = 0;
    atomic_store(&session->request_pending, true);
    pthread_mutex_unlock(&session->request_lock);
    return 0;
}

void fluxo_remux_stop_recording(FluxoRemuxSession *session) {
    if (session == NULL) {
        return;
    }
    pthread_mutex_lock(&session->request_lock);
    fluxo_discard_pending_recording_locked(session);
    session->pending_recording_stop = 1;
    atomic_store(&session->request_pending, true);
    pthread_mutex_unlock(&session->request_lock);
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
    // Only reached without a thread when start failed: nothing was opened.
    fluxo_output_free(&session->recording.output);
    free(session->recording.path);
    fluxo_output_free(&session->hls.output);
    fluxo_close_input(session);

    free(session->input_url);
    free(session->user_agent);
    free(session->hls.playlist_path);
    free(session->hls.playlist_tmp_path);
    free(session->hls.segment_prefix);
    free(session->hls.segments);
    free(session->pending_recording_path);
    fluxo_free_discarded_recordings(session->discarded_recordings);
    pthread_mutex_destroy(&session->request_lock);
    free(session);
}

// MARK: - File conversion

int32_t fluxo_remux_convert_file(const char *input_path, const char *output_path, double *duration_seconds,
                                 char *error_message, int32_t error_message_size) {
    if (input_path == NULL || output_path == NULL) {
        return AVERROR(EINVAL);
    }
    pthread_once(&fluxo_init_once, fluxo_global_init);

    AVFormatContext *input = NULL;
    FluxoOutput output;
    memset(&output, 0, sizeof(output));
    output.video_index = -1;
    AVPacket *packet = av_packet_alloc();
    AVPacket *scratch = av_packet_alloc();
    const char *stage = "Unable to open the recording";
    int64_t first_time = AV_NOPTS_VALUE;
    int64_t last_time = AV_NOPTS_VALUE;
    int output_opened = 0;

    int ret = packet != NULL && scratch != NULL ? 0 : AVERROR(ENOMEM);
    if (ret >= 0) {
        ret = avformat_open_input(&input, input_path, NULL, NULL);
    }
    if (ret >= 0) {
        ret = avformat_find_stream_info(input, NULL);
    }
    if (ret >= 0) {
        stage = "Unable to create the output file";
        ret = fluxo_output_prepare(&output, input, NULL, output_path);
    }
    if (ret >= 0) {
        // Everything is kept, including audio that precedes the first key frame.
        output.wait_keyframe = 0;
        ret = avio_open(&output.context->pb, output_path, AVIO_FLAG_WRITE);
        output_opened = ret >= 0;
    }
    if (ret >= 0) {
        AVDictionary *options = NULL;
        // The index goes first so that the file starts playing (and seeking) immediately.
        av_dict_set(&options, "movflags", "+faststart", 0);
        ret = avformat_write_header(output.context, &options);
        av_dict_free(&options);
        if (ret >= 0) {
            output.header_written = 1;
        }
    }

    int64_t start = input != NULL && input->start_time != AV_NOPTS_VALUE ? input->start_time : 0;
    if (ret >= 0) {
        stage = "Unable to convert the recording";
        while ((ret = av_read_frame(input, packet)) >= 0) {
            if (packet->stream_index < 0 || (unsigned int)packet->stream_index >= input->nb_streams) {
                av_packet_unref(packet);
                continue;
            }
            AVStream *in_stream = input->streams[packet->stream_index];
            int64_t offset = av_rescale_q(start, AV_TIME_BASE_Q, in_stream->time_base);
            if (packet->pts != AV_NOPTS_VALUE) {
                packet->pts -= offset;
            }
            if (packet->dts != AV_NOPTS_VALUE) {
                packet->dts -= offset;
            }
            int prepared = fluxo_output_prepare_packet(&output, packet, in_stream, scratch);
            av_packet_unref(packet);
            if (prepared < 0) {
                ret = prepared;
                break;
            }
            if (prepared == 0) {
                continue;
            }
            int64_t time = fluxo_packet_time(scratch, output.context->streams[scratch->stream_index]);
            if (time != AV_NOPTS_VALUE) {
                int64_t end = time + av_rescale_q(scratch->duration, output.context->streams[scratch->stream_index]->time_base, AV_TIME_BASE_Q);
                if (first_time == AV_NOPTS_VALUE || time < first_time) {
                    first_time = time;
                }
                if (last_time == AV_NOPTS_VALUE || end > last_time) {
                    last_time = end;
                }
            }
            if (scratch->dts != AV_NOPTS_VALUE) {
                output.last_dts[scratch->stream_index] = scratch->dts;
            }
            ret = av_interleaved_write_frame(output.context, scratch);
            av_packet_unref(scratch);
            if (ret < 0 && ret != AVERROR(EINVAL)) {
                break;
            }
            ret = 0;
        }
        if (ret == AVERROR_EOF) {
            ret = 0;
        }
        if (ret >= 0) {
            ret = av_write_trailer(output.context);
        }
    }

    if (ret < 0 && error_message != NULL && error_message_size > 0) {
        fluxo_format_error(error_message, (size_t)error_message_size, ret, stage);
    }
    if (duration_seconds != NULL) {
        *duration_seconds = first_time != AV_NOPTS_VALUE && last_time > first_time ? (double)(last_time - first_time) / AV_TIME_BASE : 0;
    }

    fluxo_output_free(&output);
    if (input != NULL) {
        avformat_close_input(&input);
    }
    av_packet_free(&packet);
    av_packet_free(&scratch);
    if (ret < 0 && output_opened) {
        unlink(output_path);
    }
    return ret < 0 ? ret : 0;
}
