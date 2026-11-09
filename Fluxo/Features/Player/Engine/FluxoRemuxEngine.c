//
//  FluxoRemuxEngine.c
//  Fluxo
//
//  Built against the bundled FFmpeg 9 (Vendor/FFmpeg, see Tools/FFmpeg/build-xcframework.sh),
//  using only the public libavformat/libavcodec/libavutil API. Every demuxer, muxer, protocol and
//  bitstream filter the engine reaches must be enabled in that script.
//
//  This file has the engine's interface (FluxoRemuxEngine.h): the session, its thread, events and file
//  conversion. The rest of the engine is in the FluxoEngine*.c files, which share FluxoEngineInternal.h.
//
//  Threading: everything except the public request functions runs on the engine thread.
//  Requests coming from other threads (cancel, recording) go through atomics and a mutex.
//

#include "FluxoEngineInternal.h"
#include "FluxoEngineHTTP.h"

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

int64_t fluxo_wallclock_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

int fluxo_is_cancelled(FluxoRemuxSession *session) {
    return atomic_load(&session->cancel_requested) ? 1 : 0;
}

int fluxo_interrupt_callback(void *opaque) {
    return fluxo_is_cancelled(opaque);
}

// Audio and video the outputs take: not cover art, nor a stream the engine left out (fluxo_streams_open discards
// streams that can neither be copied nor converted, and video after the first playable one).
int fluxo_is_stream_supported(const AVStream *stream) {
    if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) || stream->discard >= AVDISCARD_ALL) {
        return 0;
    }
    enum AVMediaType type = stream->codecpar->codec_type;
    return type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO;
}

// MARK: - Events

// `explicit_path` reports a recording that was never opened; otherwise the active recording is reported.
void fluxo_emit_with_path(FluxoRemuxSession *session, FluxoRemuxEventKind kind, int error_code, const char *message,
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
    event.master_playlist_written = session->hls.master_written;
    event.audio_rendition_count = session->hls.master_written ? session->hls.audio_rendition_count : 0;
    event.subtitle_rendition_count = session->hls.master_written ? session->hls.subtitle_rendition_count : 0;
    event.segment_index = session->event_segment_index;
    if (session->on_demand) {
        // On-demand: the segments on disk and their size; the duration of the whole playlist.
        event.window_segment_count = (int32_t)session->vod_segments_on_disk;
        event.window_duration = session->plan.count > 0 ? (double)(session->plan.starts[session->plan.count] - session->plan.starts[0]) / AV_TIME_BASE : 0;
        event.window_bytes = session->vod_cached_bytes;
    }

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

void fluxo_emit(FluxoRemuxSession *session, FluxoRemuxEventKind kind, int error_code, const char *message) {
    fluxo_emit_with_path(session, kind, error_code, message, NULL);
}

void fluxo_set_state(FluxoRemuxSession *session, FluxoRemuxState state, int error_code, const char *message) {
    session->state = state;
    fluxo_emit(session, FluxoRemuxEventStateChanged, error_code, message);
}

void fluxo_format_error(char *buffer, size_t size, int error_code, const char *what) {
    char reason[AV_ERROR_MAX_STRING_SIZE] = {0};
    // The engine's own codes have no text in FFmpeg (EngineMessage translates them by code).
    if (error_code == FLUXO_REMUX_ERROR_TLS_CERTIFICATE) {
        snprintf(reason, sizeof(reason), "Server certificate not trusted");
    } else if (error_code == FLUXO_REMUX_ERROR_TLS_HANDSHAKE) {
        snprintf(reason, sizeof(reason), "Secure connection failed");
    } else {
        av_strerror(error_code, reason, sizeof(reason));
    }
    snprintf(buffer, size, "%s: %s", what, reason);
}

// "Protocol not found" names neither the protocol nor the cause; say which URL scheme the bundled
// FFmpeg cannot open (Tools/FFmpeg/build-xcframework.sh lists the protocols it has).
static void fluxo_format_unsupported_protocol(char *buffer, size_t size, const char *url) {
    const char *separator = url != NULL ? strstr(url, "://") : NULL;
    int length = separator != NULL ? (int)(separator - url) : 0;
    if (length > 0 && length <= 16) {
        snprintf(buffer, size, "Unsupported stream type: %.*s:// streams cannot be played", length, url);
    } else {
        snprintf(buffer, size, "Unsupported stream type");
    }
}

static void *fluxo_thread_main(void *arg) {
    FluxoRemuxSession *session = arg;
    fluxo_set_state(session, FluxoRemuxStateOpening, 0, NULL);

    const char *stage = "Unable to open the stream";
    // Set when a live input could not be reconnected: always a failure, even if the last error was EOF.
    int reconnect_failed = 0;
    session->is_first_open = 1;
    int ret = fluxo_open_input(session);
    // A dead channel fails within seconds (fluxo_first_open_retries), 0.5 s, 1 s and 2 s apart.
    for (int attempt = 1; ret < 0 && !fluxo_is_cancelled(session) && attempt <= fluxo_first_open_retries(ret); attempt++) {
        fluxo_wait(session, (AV_TIME_BASE / 2) << (attempt - 1));
        if (!fluxo_is_cancelled(session)) {
            ret = fluxo_open_input(session);
        }
    }
    session->is_first_open = 0;
    int planned = 0;
    if (ret >= 0) {
        int64_t start = session->input->start_time;
        session->timestamp_offset = (start == AV_NOPTS_VALUE ? 0 : -start) + FLUXO_TIMESTAMP_BASE;
        session->last_input_dts = AV_NOPTS_VALUE;

        stage = "Unable to create the HLS output";
        if (!session->is_live) {
            ret = fluxo_vod_plan(session);
            planned = ret > 0;
            if (planned) {
                pthread_mutex_lock(&session->vod_lock);
                session->on_demand = 1;
                pthread_mutex_unlock(&session->vod_lock);
                ret = fluxo_vod_open(session);
            }
        }
        if (ret >= 0 && !planned) {
            if (!session->is_live) {
                // Every segment stays listed (EXT-X-PLAYLIST-TYPE:EVENT), so that every position read so
                // far stays seekable; the budget only slows reading down (fluxo_run_loop).
                session->vod_budget_bytes = session->hls.max_window_bytes;
                session->hls.max_window_bytes = 0;
                session->hls.max_window_duration = 0;
            }
            ret = fluxo_hls_open(session);
        }
    }
    if (ret >= 0 && planned) {
        fluxo_set_state(session, FluxoRemuxStateRunning, 0, NULL);
        stage = "Stream interrupted";
        ret = fluxo_vod_run(session);
        if (session->output_failed) {
            stage = "Unable to write the stream";
        }
    } else if (ret >= 0) {
        fluxo_set_state(session, FluxoRemuxStateRunning, 0, NULL);
        for (;;) {
            stage = "Stream interrupted";
            ret = fluxo_run_loop(session);
            if (fluxo_is_cancelled(session) || session->output_failed || !session->is_live) {
                break;
            }
            if (ret == FLUXO_INPUT_SUSPENDED) {
                ret = fluxo_resume_input(session);
                if (ret < 0) {
                    stage = "Connection lost";
                    reconnect_failed = !fluxo_is_cancelled(session);
                    break;
                }
                continue;
            }
            if (ret == AVERROR_EOF && fluxo_input_reached_end_of_file(session)) {
                // A finite file served over HTTP (e.g. an on-demand .ts): it really ended.
                break;
            }
            // Live inputs never end on their own: a drop or an EOF means the connection was lost.
            stage = "Connection lost";
            ret = fluxo_reconnect(session, ret, 0);
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
    if (planned) {
        // The VOD playlist stays as it is; only the partial segment goes (fluxo_vod_run).
        fluxo_vod_abort_run(session);
    } else {
        fluxo_hls_close(session, !cancelled);
    }
    fluxo_close_input(session);
    // Before the final state: a request that sees the state wait for nothing more.
    pthread_mutex_lock(&session->vod_lock);
    session->vod_terminal = 1;
    pthread_mutex_unlock(&session->vod_lock);

    if (cancelled) {
        fluxo_set_state(session, FluxoRemuxStateCancelled, 0, NULL);
    } else if (finished) {
        fluxo_set_state(session, FluxoRemuxStateFinished, 0, NULL);
    } else {
        if (ret >= 0) {
            ret = AVERROR_UNKNOWN;
        }
        char message[512];
        if (ret == AVERROR_PROTOCOL_NOT_FOUND) {
            fluxo_format_unsupported_protocol(message, sizeof(message), session->input_url);
        } else if (ret == FLUXO_ERROR_UNSUPPORTED_VIDEO || ret == FLUXO_ERROR_UNSUPPORTED_AUDIO) {
            // StreamRemuxer.swift (EngineMessage) recognizes these.
            snprintf(message, sizeof(message), "%s: %s", ret == FLUXO_ERROR_UNSUPPORTED_VIDEO ? "Unsupported video format" : "Unsupported audio format",
                     session->streams.unsupported_codec[0] != '\0' ? session->streams.unsupported_codec : "unknown");
        } else {
            fluxo_format_error(message, sizeof(message), ret, stage);
        }
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
    pthread_mutex_init(&session->vod_lock, NULL);
    pthread_cond_init(&session->vod_cond, NULL);
    session->vod_reposition = -1;
    session->vod_segment = -1;
    session->vod_seek_hint = AV_NOPTS_VALUE;
    session->vod_read_time = AV_NOPTS_VALUE;
    session->read_ahead = config->read_ahead_duration > 0 ? config->read_ahead_duration : FLUXO_DEFAULT_READ_AHEAD;
    session->start_time = config->start_time > 0 ? (int64_t)(config->start_time * AV_TIME_BASE) : 0;
    atomic_init(&session->cancel_requested, false);
    atomic_init(&session->suspend_requested, false);
    atomic_init(&session->started, false);
    atomic_init(&session->request_pending, false);

    session->input_url = fluxo_strdup(config->input_url);
    session->user_agent = fluxo_strdup(config->user_agent);
    session->io_timeout_us = config->io_timeout_us > 0 ? config->io_timeout_us : FLUXO_DEFAULT_IO_TIMEOUT_US;
    session->is_live = config->is_live != 0;
    session->max_reconnect_attempts = config->max_reconnect_attempts == 0 ? FLUXO_DEFAULT_RECONNECT_ATTEMPTS : config->max_reconnect_attempts;
    session->quick_open = config->quick_open != 0;
    session->http_ffmpeg = config->http_input == FluxoRemuxHTTPInputLibavformat;
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
    hls->segment_cut_on_audio = 0;
    hls->last_reference_time = AV_NOPTS_VALUE;
    hls->master_path = fluxo_strdup(config->hls.master_playlist_path);
    if (hls->master_path != NULL) {
        size_t master_length = strlen(hls->master_path) + 5;
        hls->master_tmp_path = malloc(master_length);
        if (hls->master_tmp_path == NULL) {
            free(hls->master_path);
            hls->master_path = NULL;
        } else {
            snprintf(hls->master_tmp_path, master_length, "%s.tmp", hls->master_path);
        }
    }
    hls->segment_extension = "ts";

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
    length = strlen(hls->segment_prefix) + sizeof("-init.mp4");
    hls->init_path = malloc(length);
    if (hls->init_path == NULL) {
        fluxo_remux_destroy(session);
        return NULL;
    }
    snprintf(hls->init_path, length, "%s-init.mp4", hls->segment_prefix);
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
        fluxo_vod_signal(session);
    }
}

int32_t fluxo_remux_request_segment(FluxoRemuxSession *session, int64_t index, int32_t is_rendition) {
    if (session == NULL || session->is_live) {
        return -1;
    }
    int32_t result;
    pthread_mutex_lock(&session->vod_lock);
    if (index == -1) {
        // The initialization segment of fMP4 playlists, written with the first segment.
        result = session->vod_init_ready ? 1 : 0;
    } else if (index < 0) {
        result = -1;
    } else if (!session->on_demand) {
        // Remuxed from start to end: segments are listed as they are written.
        if (!is_rendition) {
            session->vod_requested = index;
        }
        result = index < session->vod_available ? 1 : 0;
    } else if (index >= session->plan.count || index > session->vod_end_segment) {
        result = -2;
    } else if (is_rendition) {
        // Produced with the main segment of the same number; only the main playlist moves the reader (players
        // load the audio and subtitle segments of a rendition about where they load the video, some ahead).
        result = session->plan.bytes[index] > 0 ? 1 : 0;
    } else {
        int64_t previous = session->vod_requested;
        session->vod_requested = index;
        // A request that does not follow the previous one is a seek. So is the segment a seek the player announced
        // goes to (fluxo_remux_note_seek), even when it is the next one: a seek just past what the player buffered
        // asks for the segment after the last one it loaded, which the reader may have written ahead without a key
        // frame at its start; served as written, playback would start at its next key frame, seconds late.
        int is_seek = index != previous && index != previous + 1;
        if (session->vod_seek_hint != AV_NOPTS_VALUE) {
            int64_t time = session->plan.starts[0] + session->vod_seek_hint;
            if (time >= session->plan.starts[index] - FLUXO_VOD_SEEK_HINT_MARGIN && time < session->plan.starts[index + 1]) {
                is_seek = 1;
            }
            session->vod_seek_hint = AV_NOPTS_VALUE;
        }
        if (session->plan.bytes[index] > 0 && is_seek && !session->plan.exact && session->plan.has_video && !session->plan.independent[index]) {
            // A seek into a segment that starts inside a GOP would show a frozen picture until the next key frame:
            // it is written again from the key frame before it.
            result = 0;
            session->vod_regenerate = index;
            session->vod_reposition = index;
        } else if (session->plan.bytes[index] > 0) {
            result = 1;
        } else {
            result = 0;
            // The segment the reader produces next: the one it is in, or the one it seeks to.
            int64_t reader = session->vod_segment > session->vod_target ? session->vod_segment : session->vod_target;
            if (reader >= session->plan.count) {
                reader = session->plan.count - 1;
            }
            if (session->vod_ended || index < reader || session->plan.starts[index] - session->plan.starts[reader] > FLUXO_VOD_READ_ON_TIME) {
                session->vod_reposition = index;
            } else if (is_seek && !session->plan.exact && session->plan.has_video && index > 0 &&
                       !(session->vod_target == index && session->vod_segment <= index)) {
                // A seek into the segment the reader writes now, or reaches by reading on: without an index it would be
                // cut at its planned time inside a GOP, and play from its next key frame, seconds after the target. It
                // starts a run of its own instead, with its pre-roll (from the GOP in memory, see fluxo_vod_replay: no
                // network). Not for the first segment of the reader's run (it heads for it, or writes it): that one starts
                // with its pre-roll already.
                session->vod_reposition = index;
            }
        }
    }
    if (result == 0 && (session->vod_terminal || atomic_load(&session->cancel_requested))) {
        // Nothing will produce it any more: the session finished, failed or was cancelled.
        result = -2;
    }
    fluxo_vod_signal_locked(session);
    pthread_mutex_unlock(&session->vod_lock);
    return result;
}

void fluxo_remux_set_input_suspended(FluxoRemuxSession *session, int32_t suspended) {
    if (session == NULL || !session->is_live) {
        return;
    }
    atomic_store(&session->suspend_requested, suspended != 0);
    fluxo_vod_signal(session);
}

void fluxo_remux_note_seek(FluxoRemuxSession *session, double seconds) {
    if (session == NULL || session->is_live || !isfinite(seconds)) {
        return;
    }
    pthread_mutex_lock(&session->vod_lock);
    session->vod_seek_hint = seconds > 0 ? (int64_t)(seconds * AV_TIME_BASE) : 0;
    pthread_mutex_unlock(&session->vod_lock);
}

int32_t fluxo_remux_set_start_time(FluxoRemuxSession *session, double seconds) {
    if (session == NULL || session->is_live || !isfinite(seconds)) {
        return -1;
    }
    int32_t result = -1;
    pthread_mutex_lock(&session->vod_lock);
    // Only once the engine wrote the playlists: it never writes them again, and it reads start_time before.
    if (session->on_demand && session->vod_playlist_written) {
        session->start_time = seconds > 0 ? (int64_t)(seconds * AV_TIME_BASE) : 0;
        result = fluxo_vod_write_playlist(session) < 0 ? -1 : 0;
    }
    pthread_mutex_unlock(&session->vod_lock);
    return result;
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
    // A paused on-demand reader applies requests when it wakes up.
    fluxo_vod_signal(session);
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
    fluxo_vod_signal(session);
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
    fluxo_http_client_free(&session->http_client);

    free(session->input_url);
    free(session->user_agent);
    free(session->hls.playlist_path);
    free(session->hls.playlist_tmp_path);
    free(session->hls.segment_prefix);
    free(session->hls.segments);
    fluxo_hls_free_renditions(&session->hls);
    free(session->hls.master_path);
    free(session->hls.master_tmp_path);
    free(session->hls.init_path);
    fluxo_vod_drop_held(session);
    free(session->vod_held);
    fluxo_vod_drop_preroll(session);
    free(session->vod_preroll);
    fluxo_vod_drop_gop(session);
    free(session->vod_kept);
    free(session->vod_replay);
    fluxo_vod_plan_free(&session->plan);
    free(session->pending_recording_path);
    fluxo_free_discarded_recordings(session->discarded_recordings);
    pthread_mutex_destroy(&session->request_lock);
    pthread_cond_destroy(&session->vod_cond);
    pthread_mutex_destroy(&session->vod_lock);
    free(session);
}

// MARK: - File conversion

_Static_assert(FLUXO_REMUX_ERROR_ENCODER_UNAVAILABLE == FLUXO_ERROR_ENCODER_UNAVAILABLE, "one error code for Swift and the converter");

int32_t fluxo_remux_convert_file(const char *input_path, const char *output_path, double *duration_seconds,
                                 char *error_message, int32_t error_message_size) {
    if (input_path == NULL || output_path == NULL) {
        return AVERROR(EINVAL);
    }
    pthread_once(&fluxo_init_once, fluxo_global_init);

    AVFormatContext *input = NULL;
    FluxoStreams streams;
    memset(&streams, 0, sizeof(streams));
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
        // What AVPlayer cannot decode (DTS audio, MPEG-4 Part 2 video of a downloaded movie, ...) is converted.
        FluxoStreamsOptions streams_options = {.is_live = 0, .global_header = 1, .key_interval = 4, .complete = 1};
        ret = fluxo_streams_open(&streams, input, &streams_options);
        if (ret == FLUXO_ERROR_UNSUPPORTED_VIDEO || ret == FLUXO_ERROR_UNSUPPORTED_AUDIO) {
            stage = ret == FLUXO_ERROR_UNSUPPORTED_VIDEO ? "Unsupported video format" : "Unsupported audio format";
        }
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
        while ((ret = fluxo_streams_read(&streams, packet)) >= 0) {
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
        if (ret == FLUXO_ERROR_UNSUPPORTED_VIDEO || ret == FLUXO_ERROR_UNSUPPORTED_AUDIO) {
            snprintf(error_message, (size_t)error_message_size, "%s: %s", stage, streams.unsupported_codec[0] != '\0' ? streams.unsupported_codec : "unknown");
        } else if (ret == FLUXO_ERROR_ENCODER_UNAVAILABLE) {
            snprintf(error_message, (size_t)error_message_size, "%s", "Video encoder unavailable");
        } else {
            fluxo_format_error(error_message, (size_t)error_message_size, ret, stage);
        }
    }
    if (duration_seconds != NULL) {
        *duration_seconds = first_time != AV_NOPTS_VALUE && last_time > first_time ? (double)(last_time - first_time) / AV_TIME_BASE : 0;
    }

    fluxo_output_free(&output);
    fluxo_streams_close(&streams);
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

const char *fluxo_remux_library_version(void) {
    return av_version_info();
}
