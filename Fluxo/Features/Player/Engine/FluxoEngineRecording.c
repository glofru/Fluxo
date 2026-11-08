//
//  FluxoEngineRecording.c
//  Fluxo
//
//  Recording to a second output, and the requests other threads make to the engine thread.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

// MARK: - Recording

void fluxo_recording_close(FluxoRemuxSession *session, int error_code, const char *message) {
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

int fluxo_recording_write(FluxoRemuxSession *session, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
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
void fluxo_discard_pending_recording_locked(FluxoRemuxSession *session) {
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

void fluxo_free_discarded_recordings(FluxoDiscardedRecording *list) {
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
void fluxo_process_requests(FluxoRemuxSession *session) {
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
void fluxo_drain_requests(FluxoRemuxSession *session) {
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
