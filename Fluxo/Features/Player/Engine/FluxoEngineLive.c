//
//  FluxoEngineLive.c
//  Fluxo
//
//  The packet loop of live inputs: timestamps across discontinuities, and reconnection.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

// MARK: - Packet loop

// Applies the session offset and handles input timestamp discontinuities (e.g. MPEG-TS wrap,
// encoder restarts or a reconnection).
static void fluxo_adjust_timestamps(FluxoRemuxSession *session, AVPacket *packet, const AVStream *in_stream) {
    if (packet->dts != AV_NOPTS_VALUE) {
        int64_t raw = av_rescale_q(packet->dts, in_stream->time_base, AV_TIME_BASE_Q);
        if (session->rebase_pending) {
            // Continue right after the last packet written before the input changed.
            int64_t target = session->last_input_dts == AV_NOPTS_VALUE ? FLUXO_TIMESTAMP_BASE : session->last_input_dts + FLUXO_RECONNECT_GAP;
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

// fluxo_adjust_timestamps for FluxoStreams.adjust: applied to the packets as the input gives them.
static void fluxo_adjust_input_packet(void *opaque, AVPacket *packet, const AVStream *in_stream) {
    fluxo_adjust_timestamps(opaque, packet, in_stream);
}

// Reads the input until it ends, fails or the session is cancelled. Returns the read error
// (AVERROR_EOF at the end) or the output error, in which case `output_failed` is set.
int fluxo_run_loop(FluxoRemuxSession *session) {
    AVPacket *packet = av_packet_alloc();
    AVPacket *scratch = av_packet_alloc();
    if (packet == NULL || scratch == NULL) {
        av_packet_free(&packet);
        av_packet_free(&scratch);
        session->output_failed = 1;
        return AVERROR(ENOMEM);
    }

    int ret = 0;
    // On-demand input without a plan: segments are listed as they are written, as fast as the input
    // allows (positions are seekable only once read); over the disk budget, reading pauses once it is
    // read_ahead seconds of segments ahead of the latest one the player requested.
    int64_t read_ahead_segments = (int64_t)ceil(session->read_ahead / session->hls.segment_duration);
    // Timestamps are moved to the session's timeline as the input gives the packets, before any is converted.
    session->streams.adjust = fluxo_adjust_input_packet;
    session->streams.adjust_opaque = session;
    while (!fluxo_is_cancelled(session)) {
        fluxo_process_requests(session);

        if (session->is_live && atomic_load(&session->suspend_requested) && session->recording.path == NULL &&
            !atomic_load(&session->request_pending)) {
            // The player is paused for long (never while recording): the input closes until it plays again.
            ret = FLUXO_INPUT_SUSPENDED;
            break;
        }
        if (!session->is_live) {
            pthread_mutex_lock(&session->vod_lock);
            int64_t ahead = session->vod_available - 1 - session->vod_requested;
            int over_budget = session->vod_budget_bytes > 0 && session->hls.window_bytes > session->vod_budget_bytes;
            session->vod_paused = over_budget && (session->vod_paused ? ahead > read_ahead_segments / 2 : ahead > read_ahead_segments);
            int paused = session->vod_paused;
            uint64_t wakeups = session->vod_wakeups;
            pthread_mutex_unlock(&session->vod_lock);
            if (paused) {
                fluxo_vod_wait(session, wakeups, FLUXO_VOD_IDLE_WAIT_US);
                continue;
            }
        }

        ret = fluxo_streams_read(&session->streams, packet);
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

    session->streams.adjust = NULL;
    session->streams.adjust_opaque = NULL;
    av_packet_free(&packet);
    av_packet_free(&scratch);
    return ret;
}

// Sleeps up to `duration_us`, waking up early when the session is cancelled.
void fluxo_wait(FluxoRemuxSession *session, int64_t duration_us) {
    while (duration_us > 0 && !fluxo_is_cancelled(session)) {
        int64_t step = duration_us < 100000 ? duration_us : 100000;
        usleep((useconds_t)step);
        duration_us -= step;
        fluxo_process_requests(session);
    }
}

// Reconnects a live input. Returns 0 once packets can flow again, a negative value to give up. `resuming`: the input
// was closed on purpose (fluxo_resume_input): the first attempt is made at once and the state stays Running for it.
int fluxo_reconnect(FluxoRemuxSession *session, int last_error, int resuming) {
    int ret = fluxo_hls_break(session);
    if (ret < 0) {
        session->output_failed = 1;
        return ret;
    }
    fluxo_close_input(session);

    int quiet = resuming;
    while (!fluxo_is_cancelled(session)) {
        if (!quiet) {
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
        }
        quiet = 0;

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
        fluxo_hls_remap_renditions(session);
        if (session->recording.path != NULL) {
            ret = fluxo_output_map_input(&session->recording.output, session->input);
            if (ret <= 0) {
                fluxo_recording_close(session, ret < 0 ? ret : AVERROR_STREAM_NOT_FOUND, "Recording stopped");
            } else {
                session->recording.output.wait_keyframe = session->recording.output.video_index >= 0;
            }
        }
        session->rebase_pending = 1;
        if (session->state != FluxoRemuxStateRunning) {
            fluxo_set_state(session, FluxoRemuxStateRunning, 0, NULL);
        }
        return 0;
    }
    return AVERROR_EXIT;
}

// fluxo_remux_set_input_suspended: the current segment is published and the input closed (the time-shift window and
// the playlist stay; the playlist is marked as ended meanwhile), until the player plays again, a recording is asked
// for or the session is cancelled. Then the input opens again like after a drop: the playlist continues with
// EXT-X-DISCONTINUITY, and the media read then follow the media before without a gap in the timeline. Returns like
// fluxo_reconnect.
int fluxo_resume_input(FluxoRemuxSession *session) {
    int ret = fluxo_hls_break(session);
    if (ret < 0) {
        session->output_failed = 1;
        return ret;
    }
    fluxo_close_input(session);
    FLUXO_TRACE("input suspended");
    // A live playlist that stays unchanged for long makes AVPlayer give up on it (CoreMedia -12888 seven times in about
    // 40 s; then on macOS it waits forever at the end of what it had, on iOS it fails the item with -11866 "Playback
    // Stopped"). Marked as ended (EXT-X-ENDLIST) it is not reloaded at all: the paused item stays playable within the
    // window. The next playlist written, after the resume, goes on without the mark; the player attaches a new item
    // for it (FluxoRemuxEventInputSuspended). Not when the player plays again already: the playlist hardly paused, and
    // the item that follows it goes on (the player would otherwise have to replace it for nothing).
    if (!atomic_load(&session->suspend_requested)) {
        FLUXO_TRACE("input resumed before the playlist was marked as ended");
        session->reconnect_attempt = 0;
        return fluxo_reconnect(session, 0, 1);
    }
    if (session->hls.count > 0) {
        ret = fluxo_hls_write_playlist(&session->hls, 1);
        if (ret < 0) {
            session->output_failed = 1;
            return ret;
        }
    }
    session->event_segment_index = session->hls.next_sequence - 1;
    fluxo_emit(session, FluxoRemuxEventInputSuspended, 0, NULL);
    pthread_mutex_lock(&session->vod_lock);
    while (atomic_load(&session->suspend_requested) && !fluxo_is_cancelled(session) && !atomic_load(&session->request_pending)) {
        pthread_cond_wait(&session->vod_cond, &session->vod_lock);
    }
    pthread_mutex_unlock(&session->vod_lock);
    if (fluxo_is_cancelled(session)) {
        return AVERROR_EXIT;
    }
    FLUXO_TRACE("input resumed");
    session->reconnect_attempt = 0;
    return fluxo_reconnect(session, 0, 1);
}
