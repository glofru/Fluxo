//
//  FluxoEngineVODPlan.c
//  Fluxo
//
//  On-demand inputs: waking the engine thread, the segment plan made before playback starts, and the
//  complete VOD playlists.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

// MARK: - On-demand inputs

// Wakes the engine thread (a segment request, a recording request, a cancellation). Call with vod_lock held.
void fluxo_vod_signal_locked(FluxoRemuxSession *session) {
    session->vod_wakeups++;
    pthread_cond_broadcast(&session->vod_cond);
}

void fluxo_vod_signal(FluxoRemuxSession *session) {
    pthread_mutex_lock(&session->vod_lock);
    fluxo_vod_signal_locked(session);
    pthread_mutex_unlock(&session->vod_lock);
}

// Sleeps while reading is paused: until the next wake-up after the one numbered `wakeups` (read under vod_lock
// with the decision to pause, so a request that came in between is not missed), a cancellation, or `timeout_us`.
void fluxo_vod_wait(FluxoRemuxSession *session, uint64_t wakeups, int64_t timeout_us) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)(timeout_us / 1000000);
    deadline.tv_nsec += (long)(timeout_us % 1000000) * 1000;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }
    pthread_mutex_lock(&session->vod_lock);
    while (session->vod_wakeups == wakeups && session->vod_reposition < 0 && !fluxo_is_cancelled(session)) {
        if (pthread_cond_timedwait(&session->vod_cond, &session->vod_lock, &deadline) == ETIMEDOUT) {
            break;
        }
    }
    pthread_mutex_unlock(&session->vod_lock);
}

int fluxo_compare_times(const void *a, const void *b) {
    int64_t left = *(const int64_t *)a;
    int64_t right = *(const int64_t *)b;
    return left < right ? -1 : left > right;
}

// Time of `packet` (input timeline, AV_TIME_BASE units) used to place it in a segment. Key frames of the
// reference video use the same clock as the index the plan was made from.
int64_t fluxo_vod_packet_time(const FluxoPlan *plan, const AVPacket *packet, const AVStream *stream, int key_clock) {
    int64_t ts;
    if (key_clock && plan->key_uses_dts) {
        ts = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
    } else {
        ts = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    }
    return ts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(ts, stream->time_base, AV_TIME_BASE_Q);
}

int fluxo_vod_input_is_seekable(const AVFormatContext *input) {
    // Demuxers without an AVIOContext of their own (e.g. HLS) seek through their own requests.
    return input->pb == NULL || (input->pb->seekable & AVIO_SEEKABLE_NORMAL) != 0;
}

// Plans the VOD playlist of an on-demand input: from the key frame index when it covers the input (MP4,
// Matroska with Cues, AVI), otherwise one segment every segment_duration. Returns 1 when planned, 0 when
// the input has no reliable duration (it is then remuxed from start to end, see fluxo_run_loop), a
// negative error on allocation failure.
int fluxo_vod_plan(FluxoRemuxSession *session) {
    AVFormatContext *input = session->input;
    FluxoPlan *plan = &session->plan;
    // A duration estimated from the bit rate (an MPEG-TS file served without byte ranges) can be minutes off.
    if (input->duration == AV_NOPTS_VALUE || input->duration <= 0 || input->duration_estimation_method == AVFMT_DURATION_FROM_BITRATE) {
        return 0;
    }
    int video = -1;
    int audio = -1;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        AVStream *stream = input->streams[i];
        if (!fluxo_is_stream_supported(stream)) {
            continue;
        }
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && video < 0) {
            video = (int)i;
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && audio < 0) {
            audio = (int)i;
        }
    }
    if (video < 0 && audio < 0) {
        return 0;
    }
    plan->has_video = video >= 0;
    plan->reference_input_stream = video >= 0 ? video : audio;
    const char *format = input->iformat->name;
    // Converted video gets its key frames at the planned times, by presentation time.
    plan->key_uses_dts = (strstr(format, "mov") != NULL || strstr(format, "avi") != NULL) &&
                         !(video >= 0 && fluxo_stream_is_converted(input, (unsigned int)video));

    int64_t start = input->start_time != AV_NOPTS_VALUE ? input->start_time : 0;
    int64_t end = start + input->duration;
    int64_t step = (int64_t)(session->hls.segment_duration * AV_TIME_BASE);

    int64_t *keys = NULL;
    int key_count = 0;
    if (video >= 0) {
        AVStream *stream = input->streams[video];
        int indexed = avformat_index_get_entries_count(stream);
        const AVIndexEntry *last_entry = indexed > 0 ? avformat_index_get_entry(stream, indexed - 1) : NULL;
        int64_t indexed_until = last_entry != NULL && last_entry->timestamp != AV_NOPTS_VALUE
            ? av_rescale_q(last_entry->timestamp, stream->time_base, AV_TIME_BASE_Q) : AV_NOPTS_VALUE;
        if ((indexed_until == AV_NOPTS_VALUE || indexed_until < end - FLUXO_VOD_INDEX_COVERAGE_GAP) && fluxo_vod_input_is_seekable(input)) {
            // Matroska reads its index (Cues) at the first seek (until then it lists the key frames it read while
            // probing, often one); this one goes back to the start.
            av_seek_frame(input, video, stream->start_time != AV_NOPTS_VALUE ? stream->start_time : 0, AVSEEK_FLAG_BACKWARD);
            fluxo_streams_reset(&session->streams);
        }
        int entries = avformat_index_get_entries_count(stream);
        if (entries > 0) {
            keys = malloc(sizeof(int64_t) * (size_t)entries);
            if (keys == NULL) {
                return AVERROR(ENOMEM);
            }
            for (int i = 0; i < entries; i++) {
                const AVIndexEntry *entry = avformat_index_get_entry(stream, i);
                if (entry != NULL && (entry->flags & AVINDEX_KEYFRAME) && entry->timestamp != AV_NOPTS_VALUE) {
                    keys[key_count++] = av_rescale_q(entry->timestamp, stream->time_base, AV_TIME_BASE_Q);
                }
            }
            qsort(keys, (size_t)key_count, sizeof(int64_t), fluxo_compare_times);
        }
    }
    // The index must reach both ends (some files index only their first minutes) and have no holes: a
    // demuxer without an index of its own (MPEG-TS) only lists the key frames it happened to read while
    // probing the start and the end of the file, which would plan a single segment for the whole movie.
    int exact = key_count >= 2 && keys[0] <= start + 10 * AV_TIME_BASE && keys[key_count - 1] >= end - FLUXO_VOD_INDEX_COVERAGE_GAP;
    for (int i = 1; exact && i < key_count; i++) {
        if (keys[i] - keys[i - 1] > FLUXO_VOD_INDEX_MAX_KEY_GAP) {
            exact = 0;
        }
    }

    int capacity = exact ? key_count + 1 : (int)(input->duration / (step > 0 ? step : AV_TIME_BASE)) + 3;
    plan->starts = malloc(sizeof(int64_t) * (size_t)(capacity + 1));
    if (plan->starts == NULL) {
        free(keys);
        return AVERROR(ENOMEM);
    }
    int count = 0;
    if (exact) {
        // Segments of at least the target duration, each starting on a key frame; a short tail joins the last one.
        plan->starts[count++] = keys[0];
        for (int i = 1; i < key_count; i++) {
            if (keys[i] - plan->starts[count - 1] >= step && keys[i] < end - step / 2 && keys[i] > plan->starts[count - 1]) {
                plan->starts[count++] = keys[i];
            }
        }
    } else {
        for (int64_t time = start; (count == 0 || time < end - step / 2) && count < capacity; time += step) {
            plan->starts[count++] = time;
        }
    }
    free(keys);
    if (end <= plan->starts[count - 1]) {
        end = plan->starts[count - 1] + step;
    }
    plan->starts[count] = end;
    plan->count = count;
    plan->exact = exact;
    plan->bytes = calloc((size_t)count, sizeof(int64_t));
    plan->blind = calloc((size_t)count, sizeof(uint8_t));
    plan->blind_count = 0;
    plan->independent = calloc((size_t)count, sizeof(uint8_t));
    if (plan->bytes == NULL || plan->blind == NULL || plan->independent == NULL) {
        return AVERROR(ENOMEM);
    }
    session->vod_end_segment = count - 1;
    fluxo_streams_set_key_times(&session->streams, plan->starts, plan->count);
    return 1;
}

void fluxo_vod_plan_free(FluxoPlan *plan) {
    free(plan->starts);
    plan->starts = NULL;
    free(plan->bytes);
    plan->bytes = NULL;
    free(plan->blind);
    plan->blind = NULL;
    plan->blind_count = 0;
    free(plan->independent);
    plan->independent = NULL;
    plan->count = 0;
}

// Writes one complete VOD media playlist of the plan: the main one, or a rendition's (the same segments under
// other file names, `extension` "ts" for audio, "vtt" for subtitles).
static int fluxo_vod_write_media_playlist(FluxoRemuxSession *session, const char *path, const char *tmp_path, const char *base_name,
                                          const char *extension, const char *init_path) {
    const FluxoPlan *plan = &session->plan;
    FILE *file = fopen(tmp_path, "w");
    if (file == NULL) {
        return AVERROR(errno);
    }
    int target = 1;
    for (int i = 0; i < plan->count; i++) {
        int rounded = (int)ceil((double)(plan->starts[i + 1] - plan->starts[i]) / AV_TIME_BASE - 0.001);
        if (rounded > target) {
            target = rounded;
        }
    }
    fprintf(file, "#EXTM3U\n#EXT-X-VERSION:%d\n", init_path != NULL ? 7 : 3);
    fprintf(file, "#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n", target);
    if (session->start_time > 0) {
        // A resume: the player starts there (with the segment the engine produces first, see fluxo_vod_open).
        fprintf(file, "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES\n", (double)session->start_time / AV_TIME_BASE);
    }
    // Every segment the player seeks into starts with a key frame: the boundaries of an index are key frames, and
    // otherwise the first segment of a run starts with its pre-roll, and a segment cut inside a GOP is written again
    // when a seek asks for it (fluxo_remux_request_segment). Audio and subtitle segments always are. Without it,
    // AVPlayer loads the segment before the one it seeks into too, which costs a second seek of the input.
    fprintf(file, "#EXT-X-INDEPENDENT-SEGMENTS\n");
    if (init_path != NULL) {
        fluxo_write_map(file, init_path);
    }
    for (int i = 0; i < plan->count; i++) {
        fprintf(file, "#EXTINF:%.3f,\n%s-%06d.%s\n", (double)(plan->starts[i + 1] - plan->starts[i]) / AV_TIME_BASE, base_name, i, extension);
    }
    fprintf(file, "#EXT-X-ENDLIST\n");
    return fluxo_publish_file(file, tmp_path, path);
}

// Writes the complete VOD playlists, once, before playback starts: the renditions' first, then the main one.
// Segments are produced when requested. The master playlist follows with the first segment.
int fluxo_vod_write_playlist(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    for (int i = 0; i < hls->rendition_count; i++) {
        const FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->muxed) {
            continue;
        }
        int ret = fluxo_vod_write_media_playlist(session, rendition->playlist_path, rendition->playlist_tmp_path, rendition->base_name,
                                                 fluxo_rendition_extension(rendition), rendition->fragmented ? rendition->init_path : NULL);
        if (ret < 0) {
            return ret;
        }
    }
    return fluxo_vod_write_media_playlist(session, hls->playlist_path, hls->playlist_tmp_path, hls->segment_base_name,
                                          hls->segment_extension, hls->fragmented ? hls->init_path : NULL);
}
