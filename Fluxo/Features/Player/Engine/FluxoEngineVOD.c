//
//  FluxoEngineVOD.c
//  Fluxo
//
//  On-demand inputs: producing the requested segments, seeking, recovery after read errors, and the reader.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

// Ends the current run: the partial segment is deleted and the muxer freed without a trailer (after a
// seek, an error or a cancellation).
void fluxo_vod_abort_run(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    if (hls->segment_open && hls->output.context != NULL) {
        char temporary[PATH_MAX];
        avio_closep(&hls->output.context->pb);
        fluxo_hls_segment_path(hls, session->vod_segment, 1, temporary, sizeof(temporary));
        unlink(temporary);
        fluxo_hls_close_rendition_segments(hls, session->vod_segment, 0, 0);
    }
    hls->segment_open = 0;
    fluxo_output_free(&hls->output);
    for (int i = 0; i < hls->rendition_count; i++) {
        fluxo_output_free(&hls->renditions[i].output);
    }
    hls->moov_flushed = 0;
    session->vod_writing = 0;
    fluxo_vod_drop_held(session);
    fluxo_vod_drop_preroll(session);
}

// Deletes the segments farthest from the player while the cache is over its budget. Kept: the two
// segments before the latest request and the read-ahead after it.
static void fluxo_vod_evict(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    FluxoPlan *plan = &session->plan;
    if (hls->max_window_bytes <= 0) {
        return;
    }
    pthread_mutex_lock(&session->vod_lock);
    while (session->vod_cached_bytes > hls->max_window_bytes) {
        int64_t requested = session->vod_requested;
        int64_t keep_from = requested - 2;
        int64_t keep_to = requested;
        int64_t horizon = plan->starts[requested] + (int64_t)(session->read_ahead * AV_TIME_BASE);
        while (keep_to + 1 < plan->count && plan->starts[keep_to + 1] <= horizon) {
            keep_to++;
        }
        keep_to++;
        int victim = -1;
        int64_t farthest = -1;
        for (int i = 0; i < plan->count; i++) {
            if (plan->bytes[i] <= 0 || (i >= keep_from && i <= keep_to)) {
                continue;
            }
            // Played segments go first: going back far is rarer than continuing.
            int64_t distance = i < requested ? (requested - i) * 2 : i - requested;
            if (distance > farthest) {
                farthest = distance;
                victim = i;
            }
        }
        if (victim < 0) {
            break;
        }
        fluxo_hls_delete_segment(hls, victim);
        session->vod_cached_bytes -= plan->bytes[victim];
        plan->bytes[victim] = 0;
        session->vod_segments_on_disk--;
    }
    pthread_mutex_unlock(&session->vod_lock);
}

// Opens the file of segment `index`, starting a new run (muxer) when none is open.
static int fluxo_vod_open_segment(FluxoRemuxSession *session, int64_t index) {
    FluxoHLS *hls = &session->hls;
    int new_run = hls->output.context == NULL;
    if (new_run) {
        int ret = fluxo_hls_prepare_output(session);
        if (ret >= 0) {
            ret = fluxo_hls_prepare_renditions(session);
        }
        if (ret < 0) {
            return ret;
        }
        // The plan decides the cuts and where a run starts (fluxo_vod_route).
        hls->output.wait_keyframe = 0;
    }
    char path[PATH_MAX];
    fluxo_hls_segment_path(hls, index, 1, path, sizeof(path));
    int ret = avio_open(&hls->output.context->pb, path, AVIO_FLAG_WRITE);
    if (ret < 0) {
        return ret;
    }
    hls->segment_open = 1;
    session->vod_segment_independent = !session->plan.has_video;
    session->vod_segment_awaits_video = session->plan.has_video;
    // The audio renditions' segments of the same span, under the same number.
    ret = fluxo_hls_open_rendition_segments(hls, index, !new_run);
    if (ret < 0) {
        return ret;
    }
    if (new_run) {
        ret = fluxo_hls_write_header(hls);
        if (ret >= 0) {
            ret = fluxo_hls_write_rendition_headers(hls);
        }
        if (ret < 0) {
            return ret;
        }
        // Video packets before the first key frame of a run cannot be decoded.
        session->vod_need_key = session->plan.has_video;
    } else if (!hls->fragmented) {
        // Every segment must start with PAT/PMT so that it can be decoded on its own.
        av_opt_set(hls->output.context->priv_data, "mpegts_flags", "+resend_headers", 0);
    }
    session->vod_writing = 1;
    session->vod_segment_pictures = 0;
    return 0;
}

// Keeps track of the segments written without a picture while converted video had no encoder; once a segment has
// pictures again, deletes them (but the one the player asked for last and the one before, which it may be reading), so that the
// player gets them again with pictures when it asks. Called with vod_lock held, after segment `index` is published.
static void fluxo_vod_track_blind_locked(FluxoRemuxSession *session, int64_t index) {
    FluxoPlan *plan = &session->plan;
    if (plan->blind == NULL || !plan->has_video || !fluxo_stream_is_converted(session->input, (unsigned int)plan->reference_input_stream)) {
        return;
    }
    if (session->vod_segment_pictures == 0) {
        if (!plan->blind[index]) {
            plan->blind[index] = 1;
            plan->blind_count++;
        }
        return;
    }
    if (plan->blind[index]) {
        plan->blind[index] = 0;
        plan->blind_count--;
    }
    for (int i = 0; i < plan->count && plan->blind_count > 0; i++) {
        if (!plan->blind[i] || (i >= session->vod_requested - 1 && i <= session->vod_requested)) {
            continue;
        }
        plan->blind[i] = 0;
        plan->blind_count--;
        if (plan->bytes[i] > 0) {
            fluxo_hls_delete_segment(&session->hls, i);
            session->vod_cached_bytes -= plan->bytes[i];
            plan->bytes[i] = 0;
            session->vod_segments_on_disk--;
        }
    }
}

// Publishes the current segment: flushes it, renames it into place and reports it.
static int fluxo_vod_finish_segment(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    AVFormatContext *context = hls->output.context;
    int64_t index = session->vod_segment;
    int ret = fluxo_hls_flush(hls);
    if (ret < 0) {
        return ret;
    }
    avio_flush(context->pb);
    int64_t bytes = avio_tell(context->pb);
    ret = avio_closep(&context->pb);
    hls->segment_open = 0;
    session->vod_writing = 0;

    char temporary[PATH_MAX];
    char final_path[PATH_MAX];
    fluxo_hls_segment_path(hls, index, 1, temporary, sizeof(temporary));
    fluxo_hls_segment_path(hls, index, 0, final_path, sizeof(final_path));
    if (ret < 0 || bytes <= 0) {
        // An error, or no packet reached it (the input ended, or had nothing between two cuts): nothing to publish.
        unlink(temporary);
        fluxo_hls_close_rendition_segments(hls, index, 1, 0);
        return ret < 0 ? ret : 0;
    }
    if (rename(temporary, final_path) != 0) {
        fluxo_hls_close_rendition_segments(hls, index, 1, 0);
        return AVERROR(errno);
    }
    if (hls->rendition_count > 0) {
        // The renditions' segments are in place before the segment is reported (the player asks for them
        // at about the same time). Subtitles cover the planned span of the segment, output timeline.
        int64_t rendition_bytes = fluxo_hls_close_rendition_segments(hls, index, 1, 1);
        if (rendition_bytes < 0) {
            return (int)rendition_bytes;
        }
        const FluxoPlan *plan = &session->plan;
        int64_t subtitle_bytes = fluxo_hls_write_subtitle_segments(hls, index, plan->starts[index] + session->timestamp_offset,
                                                                   plan->starts[index + 1] + session->timestamp_offset,
                                                                   index == plan->count - 1);
        if (subtitle_bytes < 0) {
            return (int)subtitle_bytes;
        }
        bytes += rendition_bytes + subtitle_bytes;
        if (!hls->master_written) {
            // Before the first SegmentWritten event: the player opens the master playlist when it gets it.
            ret = fluxo_hls_write_master(session);
            if (ret < 0) {
                return ret;
            }
        }
    }

    pthread_mutex_lock(&session->vod_lock);
    session->plan.bytes[index] = bytes;
    session->plan.independent[index] = (uint8_t)session->vod_segment_independent;
    session->vod_cached_bytes += bytes;
    session->vod_segments_on_disk++;
    session->vod_init_ready = hls->init_written || !hls->fragmented;
    fluxo_vod_track_blind_locked(session, index);
    pthread_mutex_unlock(&session->vod_lock);

    hls->segments_written++;
    session->vod_recoveries = 0;
    session->vod_preroll_backoffs = 0;
    session->reconnect_attempt = 0;
    session->event_segment_index = index;
    fluxo_emit(session, FluxoRemuxEventSegmentWritten, 0, NULL);
    fluxo_vod_evict(session);
    return 0;
}

// Moves the reader from its segment to the next one: publishes the finished segment, then opens the next
// one if it is wanted and not on disk yet. A segment already on disk is read through without writing,
// unless the next missing one is far: then the reader seeks there.
static int fluxo_vod_cut(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    FluxoPlan *plan = &session->plan;
    if (session->vod_writing) {
        int ret = fluxo_vod_finish_segment(session);
        if (ret < 0) {
            return ret;
        }
    }
    int64_t next = session->vod_segment + 1;
    pthread_mutex_lock(&session->vod_lock);
    session->vod_segment = next;
    int on_disk = next < plan->count && plan->bytes[next] > 0;
    int64_t missing = -1;
    if (on_disk) {
        for (int64_t i = next + 1; i < plan->count; i++) {
            if (plan->bytes[i] <= 0) {
                missing = i;
                break;
            }
        }
    }
    if (on_disk && missing > next && plan->starts[missing] - plan->starts[next] > FLUXO_VOD_READ_ON_TIME && session->vod_reposition < 0) {
        session->vod_reposition = missing;
    }
    pthread_mutex_unlock(&session->vod_lock);

    if (next >= plan->count) {
        return 0;
    }
    if (next >= session->vod_target && !on_disk) {
        return fluxo_vod_open_segment(session, next);
    }
    // Not written: the next written segment starts a new run, whose first fragment is placed by its own
    // timestamps (frag_discont), like after a seek.
    if (hls->output.context != NULL) {
        fluxo_vod_abort_run(session);
    }
    return 0;
}

// Writes `packet` (input timeline) to the current segment, or drops it while no segment is written.
static int fluxo_vod_write(FluxoRemuxSession *session, AVPacket *packet, AVPacket *scratch) {
    if (!session->vod_writing) {
        return 0;
    }
    AVStream *in_stream = session->input->streams[packet->stream_index];
    if (session->vod_need_key && packet->stream_index == session->plan.reference_input_stream && session->plan.has_video) {
        if (!(packet->flags & AV_PKT_FLAG_KEY)) {
            return 0;
        }
        session->vod_need_key = 0;
    }
    if (session->vod_segment_awaits_video && packet->stream_index == session->plan.reference_input_stream) {
        session->vod_segment_awaits_video = 0;
        session->vod_segment_independent = (packet->flags & AV_PKT_FLAG_KEY) != 0;
    }
    int64_t offset = av_rescale_q(session->timestamp_offset, AV_TIME_BASE_Q, in_stream->time_base);
    if (packet->dts != AV_NOPTS_VALUE) {
        packet->dts += offset;
    }
    if (packet->pts != AV_NOPTS_VALUE) {
        packet->pts += offset;
    }
    FluxoHLS *hls = &session->hls;
    if (hls->rendition_count > 0 && !hls->master_written && !hls->closed_captions && hls->output.video_index >= 0 &&
        (unsigned int)packet->stream_index < hls->output.stream_map_size &&
        hls->output.stream_map[packet->stream_index] == hls->output.video_index) {
        hls->closed_captions = fluxo_packet_has_closed_captions(packet);
    }
    int ret = fluxo_output_prepare_packet(&hls->output, packet, in_stream, scratch);
    if (ret > 0) {
        if (scratch->stream_index == hls->output.video_index) {
            session->vod_segment_pictures++;
        }
        ret = fluxo_output_commit(&hls->output, scratch);
    }
    if (ret >= 0 && hls->rendition_count > 0) {
        // Extra audio tracks and subtitles: packets the main output does not take.
        ret = fluxo_hls_write_renditions(hls, packet, in_stream, scratch);
    }
    if (packet->dts != AV_NOPTS_VALUE) {
        packet->dts -= offset;
    }
    if (packet->pts != AV_NOPTS_VALUE) {
        packet->pts -= offset;
    }
    return ret < 0 ? ret : 0;
}

// Places one input packet in the plan. A segment ends at the first key frame of the reference video at or
// after the start of the next segment. Packets at or after that start are held until that key frame
// arrives (they belong to the current segment if they come before it). When no key frame comes before the
// segment after next (a longer GOP than planned), the cut is made at the planned time instead.
static int fluxo_vod_route(FluxoRemuxSession *session, AVPacket *packet, AVPacket *scratch) {
    FluxoPlan *plan = &session->plan;
    AVStream *in_stream = session->input->streams[packet->stream_index];
    int reference = packet->stream_index == plan->reference_input_stream;
    int key = reference && (packet->flags & AV_PKT_FLAG_KEY);
    int64_t time = fluxo_vod_packet_time(plan, packet, in_stream, 0);
    int64_t key_time = key ? fluxo_vod_packet_time(plan, packet, in_stream, 1) : AV_NOPTS_VALUE;
    int ret;
    if (key && time != AV_NOPTS_VALUE) {
        int64_t interval = time - session->vod_last_key;
        if (session->vod_last_key != AV_NOPTS_VALUE && interval > 0 && interval <= FLUXO_VOD_INDEX_MAX_KEY_GAP && interval > session->vod_gop) {
            session->vod_gop = interval;
        }
        session->vod_last_key = time;
    }

    if (session->vod_check_seek && reference && time != AV_NOPTS_VALUE && session->vod_seek_position >= 0) {
        // A byte seek: where it landed tells how far off the estimate was.
        int64_t error = time - session->vod_seek_time;
        int64_t size = session->input->pb != NULL ? avio_size(session->input->pb) : -1;
        int64_t duration = session->input->duration;
        if ((error > FLUXO_VOD_BYTE_SEEK_LATE || error < -FLUXO_VOD_BYTE_SEEK_EARLY) && session->vod_seek_corrections < FLUXO_VOD_BYTE_SEEK_CORRECTIONS &&
            size > 0 && duration > 0) {
            double bytes_per_time = (double)size / (double)duration;
            // A late landing goes back a little more than the error, so that the next one is early (reading on is cheap).
            int64_t correction = error > 0 ? error + AV_TIME_BASE : error + AV_TIME_BASE * 2;
            int64_t position = session->vod_seek_position - (int64_t)(correction * bytes_per_time);
            if (position < 0) {
                position = 0;
            }
            if (position != session->vod_seek_position && av_seek_frame(session->input, -1, position, AVSEEK_FLAG_BYTE) >= 0) {
                FLUXO_TRACE("byte seek for %.2f s landed at %.2f s: again at byte %lld", session->vod_seek_time / 1e6, time / 1e6, (long long)position);
                fluxo_streams_reset(&session->streams);
                fluxo_vod_drop_gop(session);
                session->vod_seek_position = position;
                session->vod_seek_corrections++;
                return 0;
            }
        }
        FLUXO_TRACE("byte seek for %.2f s landed at %.2f s", session->vod_seek_time / 1e6, time / 1e6);
        session->vod_check_seek = 0;
        session->vod_seek_position = -1;
    }
    if (session->vod_check_seek && reference && time != AV_NOPTS_VALUE) {
        session->vod_check_seek = 0;
        int64_t target = plan->starts[session->vod_target];
        int64_t step = (int64_t)(session->hls.segment_duration * AV_TIME_BASE);
        if (time > target + 2 * step && session->vod_target > 0) {
            // Landed after the target: seek again from earlier, with a margin of the overshoot.
            int64_t earlier = target - (time - target) - step;
            if (earlier < plan->starts[0]) {
                earlier = plan->starts[0];
            }
            if (av_seek_frame(session->input, -1, earlier, AVSEEK_FLAG_BACKWARD) >= 0) {
                fluxo_streams_reset(&session->streams);
                fluxo_vod_drop_gop(session);
                FLUXO_TRACE("seek to segment %lld landed at %.2f s, after its start %.2f s: again from %.2f s", (long long)session->vod_target,
                            time / 1e6, target / 1e6, earlier / 1e6);
                return 0;
            }
        }
    }
    int64_t upcoming = session->vod_segment + 1;
    // (Only without an index: the boundaries of an index are key frames.)
    if (!plan->exact && plan->has_video && !session->vod_writing && session->vod_segment >= 0 && upcoming >= session->vod_target &&
        upcoming < plan->count && plan->bytes[upcoming] <= 0 && time != AV_NOPTS_VALUE) {
        // The reader writes nothing yet and the next segment starts a run: after a seek (the reader is in the
        // segment before the target), or after reading through segments already on disk.
        int64_t boundary = plan->starts[upcoming];
        if (time < boundary - FLUXO_VOD_TIME_EPSILON) {
            if (key) {
                // The latest key frame before the target segment so far: the pre-roll starts over from it.
                fluxo_vod_drop_preroll(session);
            }
            if (key || session->vod_preroll_count > 0) {
                ret = fluxo_vod_add_preroll(session, packet, time);
                if (ret < 0) {
                    return ret;
                }
            }
            return 0;
        }
        if (reference && !(key && key_time != AV_NOPTS_VALUE && key_time >= boundary - FLUXO_VOD_TIME_EPSILON)) {
            // The target segment starts inside a GOP.
            if (session->vod_preroll_count == 0 && session->vod_preroll_backoffs < FLUXO_VOD_MAX_PREROLL_BACKOFFS &&
                fluxo_vod_input_is_seekable(session->input)) {
                // No key frame was read before it: seek back further for one.
                session->vod_preroll_backoffs++;
                int64_t earlier = boundary - session->vod_preroll_backoffs * FLUXO_VOD_PREROLL_BACKOFF;
                if (earlier < plan->starts[0]) {
                    earlier = plan->starts[0];
                }
                FLUXO_TRACE("segment %lld starts inside a GOP at %.2f s, no key frame read: back to %.2f s", (long long)upcoming,
                            boundary / 1e6, earlier / 1e6);
                int64_t size = session->input->pb != NULL ? avio_size(session->input->pb) : -1;
                int seeked;
                if (size > 0 && session->input->duration > 0 && (session->input->iformat->flags & AVFMT_NO_BYTE_SEEK) == 0) {
                    // By byte position, like the seek itself (fluxo_vod_seek).
                    int64_t position = (int64_t)((double)(earlier - plan->starts[0]) / (double)session->input->duration * (double)size);
                    seeked = av_seek_frame(session->input, -1, position > 0 ? position : 0, AVSEEK_FLAG_BYTE) >= 0;
                } else {
                    seeked = av_seek_frame(session->input, -1, earlier, AVSEEK_FLAG_BACKWARD) >= 0;
                }
                if (seeked) {
                    fluxo_streams_reset(&session->streams);
                    fluxo_vod_drop_held(session);
                    fluxo_vod_drop_gop(session);
                    return 0;
                }
            }
            if (session->vod_preroll_count > 0) {
                // Open the target segment and start it with the pre-roll from its key frame: AVPlayer decodes from
                // there and shows the frames from the target on.
                FLUXO_TRACE("segment %lld starts inside a GOP at %.2f s: pre-roll of %d packets from the key frame at %.2f s",
                            (long long)upcoming, boundary / 1e6, session->vod_preroll_count, session->vod_preroll[0].time / 1e6);
                ret = fluxo_vod_cut(session);
                if (ret < 0) {
                    return ret;
                }
                if (session->vod_writing) {
                    // AVPlayer places an MPEG-TS segment by its first video frame, at the start the playlist gives the
                    // segment: frames from the key frame before it would shift the whole picture off the timeline by
                    // the length of the pre-roll. So the pre-roll's video frames before the segment are presented
                    // just before its start (they are decoded, then dropped by the seek, which lands at or after it)
                    // and its audio before the segment is left out.
                    // Squeezed into the last ticks before their segment's first own frame: decode times in decode order,
                    // just before the decode time of the video packet that opens the segment (later frames keep theirs,
                    // and the muxer drops a packet whose decode time goes back), presentation times in presentation order
                    // in the last ticks before the segment's start, so a seek to that start shows at most the last of
                    // them, the frame just before it. Decode times never go back from the end of the segment before
                    // either (it ends a frame before that packet), which plays into this one when it is on disk.
                    int video = 0;
                    for (int i = 0; i < session->vod_preroll_count; i++) {
                        const FluxoHeldPacket *held = &session->vod_preroll[i];
                        if (held->packet->stream_index == plan->reference_input_stream && held->time != AV_NOPTS_VALUE && held->time < boundary) {
                            video++;
                        }
                    }
                    int64_t *order = video > 0 ? malloc(sizeof(int64_t) * (size_t)video) : NULL;
                    if (video > 0 && order == NULL) {
                        return AVERROR(ENOMEM);
                    }
                    int count = 0;
                    for (int i = 0; i < session->vod_preroll_count; i++) {
                        const FluxoHeldPacket *held = &session->vod_preroll[i];
                        if (held->packet->stream_index == plan->reference_input_stream && held->time != AV_NOPTS_VALUE && held->time < boundary) {
                            order[count++] = held->time;
                        }
                    }
                    if (video > 0) {
                        qsort(order, (size_t)video, sizeof(int64_t), fluxo_compare_times);
                    }
                    int decoded;
                    AVStream *reference_stream = session->input->streams[plan->reference_input_stream];
                    int64_t start_ticks = av_rescale_q(boundary, AV_TIME_BASE_Q, reference_stream->time_base);
                    int64_t opening = packet->dts != AV_NOPTS_VALUE ? packet->dts : (packet->pts != AV_NOPTS_VALUE ? packet->pts : start_ticks);
                    int64_t base_dts = opening - video - 1;
                    int64_t base_pts = start_ticks - video;
                    decoded = 0;
                    for (int i = 0; i < session->vod_preroll_count; i++) {
                        AVPacket *held = session->vod_preroll[i].packet;
                        int64_t time = session->vod_preroll[i].time;
                        if (time != AV_NOPTS_VALUE && time < boundary) {
                            if (held->stream_index != plan->reference_input_stream) {
                                // The pre-roll's audio before the segment is left out.
                                continue;
                            }
                            int64_t *found = bsearch(&time, order, (size_t)video, sizeof(int64_t), fluxo_compare_times);
                            int rank = found != NULL ? (int)(found - order) : decoded;
                            held->dts = base_dts + decoded;
                            held->pts = base_pts + rank;
                            if (held->pts < held->dts) {
                                held->pts = held->dts;
                            }
                            decoded++;
                        }
                        ret = fluxo_vod_write(session, held, scratch);
                        if (ret < 0) {
                            free(order);
                            return ret;
                        }
                    }
                    free(order);
                    // Packets held at the start of the segment (audio read before this video packet) follow it.
                    for (int i = 0; i < session->vod_held_count; i++) {
                        ret = fluxo_vod_write(session, session->vod_held[i].packet, scratch);
                        if (ret < 0) {
                            return ret;
                        }
                    }
                }
                fluxo_vod_drop_preroll(session);
                fluxo_vod_drop_held(session);
                // The packet is placed against the boundaries of the target segment (below).
            }
        }
    }
    if (session->vod_segment < 0) {
        // Reading from the start: the first packet opens segment 0.
        ret = fluxo_vod_cut(session);
        if (ret < 0) {
            return ret;
        }
    }
    for (;;) {
        int64_t next = session->vod_segment + 1;
        if (next >= plan->count) {
            return fluxo_vod_write(session, packet, scratch);
        }
        int64_t boundary = plan->starts[next];
        int64_t following = next + 1 < plan->count ? plan->starts[next + 1] : INT64_MAX;
        if (!plan->has_video) {
            if (reference && time != AV_NOPTS_VALUE && time >= boundary - FLUXO_VOD_TIME_EPSILON) {
                ret = fluxo_vod_cut(session);
                if (ret < 0) {
                    return ret;
                }
                continue;
            }
            return fluxo_vod_write(session, packet, scratch);
        }
        if (key && key_time != AV_NOPTS_VALUE && key_time >= boundary - FLUXO_VOD_TIME_EPSILON) {
            for (int i = 0; i < session->vod_held_count; i++) {
                ret = fluxo_vod_write(session, session->vod_held[i].packet, scratch);
                if (ret < 0) {
                    return ret;
                }
            }
            fluxo_vod_drop_held(session);
            // A pre-roll read for this segment is not needed: it starts with its own key frame.
            fluxo_vod_drop_preroll(session);
            ret = fluxo_vod_cut(session);
            if (ret < 0) {
                return ret;
            }
            return fluxo_vod_write(session, packet, scratch);
        }
        int pending = session->vod_held_count > 0 || (time != AV_NOPTS_VALUE && time >= boundary - FLUXO_VOD_TIME_EPSILON);
        if (!pending) {
            return fluxo_vod_write(session, packet, scratch);
        }
        // Converted video whose encoder is refused (the app in the background, Picture in Picture) gives no
        // packets: the audio cuts at the planned start meanwhile, so that it keeps playing.
        int audio_cuts = !reference && in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && time != AV_NOPTS_VALUE &&
                         time >= boundary - FLUXO_VOD_TIME_EPSILON && fluxo_streams_video_stalled(&session->streams);
        // Without an index the cut is made at the planned time, key frame or not: the media of every segment then
        // starts where the playlist says, which is where AVPlayer places it (MPEG-TS media is placed by the playlist,
        // not by its timestamps: segments that start later or earlier than planned shift the picture off the
        // timeline). A seek into a segment that starts inside a GOP writes it again with a pre-roll.
        int overdue = (reference && time != AV_NOPTS_VALUE && time >= following - FLUXO_VOD_TIME_EPSILON) ||
                      session->vod_held_count >= FLUXO_VOD_MAX_HELD_PACKETS || audio_cuts ||
                      (!plan->exact && reference && time != AV_NOPTS_VALUE);
        if (!overdue) {
            return fluxo_vod_hold(session, packet, time);
        }
        // No key frame in the next segment: cut at its planned start.
        fluxo_vod_drop_preroll(session);
        int held = session->vod_held_count;
        for (int i = 0; i < held; i++) {
            if (session->vod_held[i].time == AV_NOPTS_VALUE || session->vod_held[i].time < boundary) {
                ret = fluxo_vod_write(session, session->vod_held[i].packet, scratch);
                if (ret < 0) {
                    return ret;
                }
            }
        }
        ret = fluxo_vod_cut(session);
        if (ret < 0) {
            return ret;
        }
        for (int i = 0; i < held; i++) {
            if (session->vod_held[i].time != AV_NOPTS_VALUE && session->vod_held[i].time >= boundary) {
                ret = fluxo_vod_write(session, session->vod_held[i].packet, scratch);
                if (ret < 0) {
                    return ret;
                }
            }
        }
        fluxo_vod_drop_held(session);
        // The packet is placed against the boundaries of the new segment.
    }
}

// Positions the reader at the start of segment `index`: seeks to the key frame at or before it, or (an
// input that cannot seek, e.g. a server without byte ranges) reads on to it, or reads again from the start.
static int fluxo_vod_seek(FluxoRemuxSession *session, int64_t index) {
    FluxoPlan *plan = &session->plan;
    fluxo_vod_abort_run(session);
    int64_t current = session->vod_segment;

    pthread_mutex_lock(&session->vod_lock);
    if (session->vod_regenerate == index && plan->bytes[index] > 0) {
        // On disk, but it does not start with a key frame: written again, with a pre-roll.
        fluxo_hls_delete_segment(&session->hls, index);
        session->vod_cached_bytes -= plan->bytes[index];
        session->vod_segments_on_disk--;
        plan->bytes[index] = 0;
        plan->independent[index] = 0;
    }
    session->vod_regenerate = -1;
    pthread_mutex_unlock(&session->vod_lock);

    if (fluxo_vod_replay(session, index)) {
        // From the key frame in memory: the segment starts with its pre-roll (fluxo_vod_route), and the reader
        // continues with the input where it is once the replayed packets are routed.
        fluxo_hls_clear_cues(&session->hls);
        pthread_mutex_lock(&session->vod_lock);
        session->vod_segment = index - 1;
        session->vod_target = index;
        session->vod_ended = 0;
        session->vod_paused = 0;
        pthread_mutex_unlock(&session->vod_lock);
        session->vod_need_key = plan->has_video;
        session->vod_preroll_backoffs = 0;
        session->vod_check_seek = 0;
        session->vod_seek_position = -1;
        session->vod_last_key = AV_NOPTS_VALUE;
        FLUXO_TRACE("seek to segment %lld (%.2f s) from segment %lld: replaying %d packets from the key frame at %.2f s", (long long)index,
                    plan->starts[index] / 1e6, (long long)current, session->vod_replay_count, session->vod_replay[0].time / 1e6);
        return 0;
    }
    // The input moves: the GOP in memory no longer leads to where it reads.
    fluxo_vod_drop_gop(session);

    // Without an index the segment may start inside a GOP: the seek goes back about a GOP, to read the key frame
    // before the segment (its pre-roll, see fluxo_vod_route) without seeking again.
    int64_t seek_time = plan->starts[index];
    if (!plan->exact && plan->has_video && index > 0) {
        // (A byte position is estimated from the average bit rate: a second more covers its error.)
        int64_t back = session->vod_gop > 0 ? session->vod_gop + AV_TIME_BASE * 3 / 2 : FLUXO_VOD_PREROLL_BACKOFF;
        seek_time = seek_time - back > plan->starts[0] ? seek_time - back : plan->starts[0];
    }
    // Demuxers emulate seeking on an input that cannot seek by reading and skipping, which can lose their
    // place in the file: such inputs are only read on, or reopened.
    int ret;
    session->vod_seek_position = -1;
    // (The size only of an input that can seek: asking an HTTP input without byte ranges for it costs a request.)
    int seekable = fluxo_vod_input_is_seekable(session->input);
    int64_t size = seekable && !plan->exact && session->input->pb != NULL ? avio_size(session->input->pb) : -1;
    if (!seekable) {
        ret = AVERROR(ENOSYS);
    } else if (!plan->exact && size > 0 && session->input->duration > 0 && (session->input->iformat->flags & AVFMT_NO_BYTE_SEEK) == 0) {
        // No index: one request at the estimated byte position (corrected in fluxo_vod_route).
        int64_t start = plan->starts[0];
        int64_t position = (int64_t)((double)(seek_time - start) / (double)session->input->duration * (double)size);
        if (position < 0) {
            position = 0;
        }
        ret = av_seek_frame(session->input, -1, position, AVSEEK_FLAG_BYTE);
        if (ret >= 0) {
            session->vod_seek_time = seek_time;
            session->vod_seek_position = position;
            session->vod_seek_corrections = 0;
        } else {
            ret = av_seek_frame(session->input, -1, seek_time, AVSEEK_FLAG_BACKWARD);
        }
    } else {
        ret = av_seek_frame(session->input, -1, seek_time, AVSEEK_FLAG_BACKWARD);
    }
    int64_t position;
    if (ret >= 0) {
        position = index - 1;
        session->vod_check_seek = 1;
        // What the converters hold belongs to the old position.
        fluxo_streams_reset(&session->streams);
    } else if (index > current) {
        // Reading on reaches it; nothing is written until then.
        position = current;
    } else {
        fluxo_close_input(session);
        ret = fluxo_open_input(session);
        if (ret < 0) {
            return ret;
        }
        fluxo_hls_remap_renditions(session);
        position = -1;
    }
    // Cues read before the jump belong to other segments.
    fluxo_hls_clear_cues(&session->hls);
    pthread_mutex_lock(&session->vod_lock);
    session->vod_segment = position;
    session->vod_target = index;
    session->vod_ended = 0;
    session->vod_paused = 0;
    pthread_mutex_unlock(&session->vod_lock);
    session->vod_need_key = plan->has_video;
    session->vod_preroll_backoffs = 0;
    // The next key frame read is not a GOP after the previous one.
    session->vod_last_key = AV_NOPTS_VALUE;
    FLUXO_TRACE("seek to segment %lld (%.2f s) from segment %lld: %s", (long long)index, plan->starts[index] / 1e6, (long long)current,
                position == -1 ? "reopened" : (position == current ? "reading on" : "seeked"));
    return 0;
}

// Reopens the input after a read error and positions the reader at the segment it was producing.
// Returns 0 when reading can continue, the error when the input could not be resumed.
static int fluxo_vod_recover(FluxoRemuxSession *session, int error) {
    int64_t resume = session->vod_segment;
    if (!session->vod_writing) {
        resume = resume + 1 > session->vod_target ? resume + 1 : session->vod_target;
    }
    if (resume < 0) {
        resume = 0;
    }
    if (resume >= session->plan.count) {
        resume = session->plan.count - 1;
    }
    fluxo_vod_abort_run(session);
    int ret = error;
    while (!fluxo_is_cancelled(session)) {
        session->vod_recoveries++;
        if (session->vod_recoveries > FLUXO_VOD_MAX_RECOVERIES) {
            return ret;
        }
        session->reconnect_attempt = session->vod_recoveries;
        fluxo_set_state(session, FluxoRemuxStateReconnecting, ret, NULL);
        int shift = session->vod_recoveries - 1 < 4 ? session->vod_recoveries - 1 : 4;
        fluxo_wait(session, (AV_TIME_BASE / 2) << shift);
        if (fluxo_is_cancelled(session)) {
            break;
        }
        fluxo_vod_drop_gop(session);
        fluxo_close_input(session);
        ret = fluxo_open_input(session);
        if (ret < 0) {
            continue;
        }
        fluxo_hls_remap_renditions(session);
        pthread_mutex_lock(&session->vod_lock);
        if (session->vod_reposition < 0) {
            session->vod_reposition = resume;
        }
        pthread_mutex_unlock(&session->vod_lock);
        fluxo_set_state(session, FluxoRemuxStateRunning, 0, NULL);
        return 0;
    }
    return AVERROR_EXIT;
}

// The input was read to its end: the last segment is published and the reader waits for requests (the
// player may seek back to segments that were deleted from the cache).
static int fluxo_vod_finish_input(FluxoRemuxSession *session, AVPacket *scratch) {
    for (int i = 0; i < session->vod_held_count; i++) {
        int ret = fluxo_vod_write(session, session->vod_held[i].packet, scratch);
        if (ret < 0) {
            return ret;
        }
    }
    fluxo_vod_drop_held(session);
    if (session->vod_writing) {
        int ret = fluxo_vod_finish_segment(session);
        if (ret < 0) {
            return ret;
        }
    }
    fluxo_output_free(&session->hls.output);
    for (int i = 0; i < session->hls.rendition_count; i++) {
        fluxo_output_free(&session->hls.renditions[i].output);
    }
    session->hls.moov_flushed = 0;
    pthread_mutex_lock(&session->vod_lock);
    session->vod_ended = 1;
    // Nothing exists after the segment the reader reached (the plan can be longer than the media: MPEG-TS
    // durations are estimated), nor that segment itself if nothing was written to it.
    int64_t reached = session->vod_segment;
    if (reached >= 0 && reached < session->plan.count) {
        int64_t last = session->plan.bytes[reached] > 0 ? reached : reached - 1;
        if (last >= 0 && last < session->vod_end_segment) {
            session->vod_end_segment = last;
        }
    }
    pthread_mutex_unlock(&session->vod_lock);
    return 0;
}

// True when the reader is far enough ahead of the latest request to pause (with hysteresis: it resumes
// at half the read-ahead).
static int fluxo_vod_should_pause(FluxoRemuxSession *session) {
    const FluxoPlan *plan = &session->plan;
    pthread_mutex_lock(&session->vod_lock);
    int64_t reader = session->vod_segment > session->vod_target ? session->vod_segment : session->vod_target;
    int64_t requested = session->vod_requested;
    if (reader < 0) {
        reader = 0;
    }
    if (reader >= plan->count) {
        reader = plan->count - 1;
    }
    int64_t ahead = plan->starts[reader] - plan->starts[requested];
    int64_t limit = (int64_t)(session->read_ahead * AV_TIME_BASE);
    if (session->vod_paused) {
        session->vod_paused = ahead > limit / 2;
    } else {
        session->vod_paused = ahead > limit;
    }
    int paused = session->vod_paused;
    pthread_mutex_unlock(&session->vod_lock);
    return paused;
}

// Produces the segments of a planned on-demand input until the session is cancelled or the input fails.
int fluxo_vod_run(FluxoRemuxSession *session) {
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
        pthread_mutex_lock(&session->vod_lock);
        int64_t reposition = session->vod_reposition;
        session->vod_reposition = -1;
        int ended = session->vod_ended;
        // Read with the state the reader decides on: a request after it ends the wait below at once.
        uint64_t wakeups = session->vod_wakeups;
        pthread_mutex_unlock(&session->vod_lock);

        if (reposition >= 0) {
            ret = fluxo_vod_seek(session, reposition);
            if (ret < 0) {
                ret = fluxo_vod_recover(session, ret);
                if (ret < 0) {
                    break;
                }
            }
            continue;
        }
        if (ended || fluxo_vod_should_pause(session)) {
            fluxo_vod_wait(session, wakeups, FLUXO_VOD_IDLE_WAIT_US);
            continue;
        }

        if (session->vod_replay_next < session->vod_replay_count) {
            // Packets of the GOP in memory first (fluxo_vod_replay).
            FluxoHeldPacket *held = &session->vod_replay[session->vod_replay_next++];
            av_packet_move_ref(packet, held->packet);
            av_packet_free(&held->packet);
            if (session->vod_replay_next == session->vod_replay_count) {
                session->vod_replay_count = 0;
                session->vod_replay_next = 0;
            }
            ret = 0;
        } else {
            ret = fluxo_streams_read(&session->streams, packet);
        }
        if (ret == AVERROR(EAGAIN)) {
            ret = 0;
            continue;
        }
        if (ret == AVERROR_EOF) {
            // The real end, or a connection the server closed early (then the reader resumes where it was).
            const FluxoPlan *plan = &session->plan;
            int at_end = fluxo_input_reached_end_of_file(session) || session->vod_segment >= plan->count - 1 ||
                         session->input->pb == NULL || avio_size(session->input->pb) <= 0;
            if (at_end) {
                ret = fluxo_vod_finish_input(session, scratch);
                if (ret < 0) {
                    session->output_failed = 1;
                    break;
                }
                ret = 0;
                continue;
            }
        }
        if (ret < 0) {
            ret = fluxo_vod_recover(session, ret);
            if (ret < 0) {
                break;
            }
            continue;
        }
        if (packet->stream_index < 0 || (unsigned int)packet->stream_index >= session->input->nb_streams ||
            !(fluxo_is_stream_supported(session->input->streams[packet->stream_index]) ||
              fluxo_hls_is_subtitle_source(&session->hls, packet->stream_index))) {
            av_packet_unref(packet);
            continue;
        }
        fluxo_vod_remember(session, packet);
        ret = fluxo_vod_route(session, packet, scratch);
        av_packet_unref(packet);
        if (ret < 0) {
            session->output_failed = 1;
            break;
        }
    }
    if (fluxo_is_cancelled(session) && ret >= 0) {
        ret = AVERROR_EXIT;
    }
    fluxo_vod_abort_run(session);
    av_packet_free(&packet);
    av_packet_free(&scratch);
    return ret;
}

// Prepares the output of a planned on-demand input: the segment format and the complete playlist.
int fluxo_vod_open(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    hls->fragmented = fluxo_hls_wants_fragmented_mp4(session->input);
    hls->segment_extension = hls->fragmented ? "m4s" : "ts";
    // Extra audio tracks and text subtitles: renditions of a master playlist, with the same segments (audio in
    // fragmented MP4 too next to fMP4 video).
    int ret = fluxo_hls_plan_renditions(session);
    if (ret < 0) {
        return ret;
    }
    for (int i = 0; i < hls->rendition_count; i++) {
        hls->renditions[i].fragmented = hls->fragmented && hls->renditions[i].type == FluxoRenditionAudio;
    }
    // Output timestamps: the input timeline from the first segment, plus the base.
    session->timestamp_offset = FLUXO_TIMESTAMP_BASE - session->plan.starts[0];
    // A resume starts with the segment at the start time (found by bisection: the plan is sorted).
    int64_t first = 0;
    if (session->start_time > 0) {
        int64_t time = session->plan.starts[0] + session->start_time;
        int64_t low = 0;
        int64_t high = session->plan.count - 1;
        while (low < high) {
            int64_t middle = (low + high + 1) / 2;
            if (session->plan.starts[middle] <= time) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        first = low;
        FLUXO_TRACE("start at %.2f s: segment %lld", session->start_time / 1e6, (long long)first);
    }
    if (first == 0 && !session->plan.exact && fluxo_vod_input_is_seekable(session->input) && session->input->pb != NULL &&
        (session->input->iformat->flags & AVFMT_NO_BYTE_SEEK) == 0) {
        // From the very start of the file (probing and the index check leave the reader somewhere after it): its first
        // video frame, a key frame, is where AVPlayer places the first segment.
        av_seek_frame(session->input, -1, 0, AVSEEK_FLAG_BYTE);
        fluxo_streams_reset(&session->streams);
    }
    pthread_mutex_lock(&session->vod_lock);
    session->vod_segment = -1;
    session->vod_target = 0;
    session->vod_requested = first;
    session->vod_reposition = first > 0 ? first : -1;
    session->vod_regenerate = -1;
    session->vod_last_key = AV_NOPTS_VALUE;
    session->vod_seek_position = -1;
    session->vod_gop = 0;
    pthread_mutex_unlock(&session->vod_lock);
    ret = fluxo_vod_write_playlist(session);
    if (ret >= 0) {
        pthread_mutex_lock(&session->vod_lock);
        session->vod_playlist_written = 1;
        pthread_mutex_unlock(&session->vod_lock);
    }
    return ret;
}
