//
//  FluxoEngineHLS.c
//  Fluxo
//
//  The HLS segmenter of the main output: segment files, the time-shift window, the media playlist, and the
//  life of a segment (open, cut, finish) for live inputs.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

// MARK: - HLS segmenter

void fluxo_hls_segment_path(const FluxoHLS *hls, int64_t sequence, int temporary, char *buffer, size_t size) {
    snprintf(buffer, size, "%s-%06lld.%s%s", hls->segment_prefix, (long long)sequence, hls->segment_extension, temporary ? ".tmp" : "");
}

// AVPlayer decodes HEVC from HLS only in fragmented MP4 (from MPEG-TS segments it plays the audio
// over a black picture), so HEVC video gets fMP4 segments, and so does AV1 (which MPEG-TS cannot carry);
// everything else (converted video included: H.264) stays MPEG-TS.
int fluxo_hls_wants_fragmented_mp4(const AVFormatContext *input) {
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        const AVStream *stream = input->streams[i];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && fluxo_is_stream_supported(stream)) {
            enum AVCodecID codec_id = fluxo_stream_parameters(input, i)->codec_id;
            return codec_id == AV_CODEC_ID_HEVC || codec_id == AV_CODEC_ID_AV1;
        }
    }
    return 0;
}

// Header options of the fragmented MP4 muxers (the main output of HEVC video and its audio renditions): one
// fragment per segment, flushed by the segmenter (frag_custom); the moov written at the first flush
// (delay_moov: AC-3 / E-AC-3 tracks need packets before their sample entry can be written), into the
// initialization segment; fragments addressed from their own moof, so they can be stored as separate files; no
// edit list and no timestamp shift, so that the tfdt of every fragment is its real decoding time, also for the
// first fragment after a seek (frag_discont).
static AVDictionary *fluxo_fragmented_options(void) {
    AVDictionary *options = NULL;
    av_dict_set(&options, "movflags", "+frag_custom+delay_moov+default_base_moof+frag_discont+skip_trailer", 0);
    av_dict_set(&options, "use_editlist", "0", 0);
    return options;
}

// Writes the muxer header: into the open segment for MPEG-TS; nowhere for fragmented MP4, whose header
// is the moov written at the first flush (fluxo_output_flush).
int fluxo_output_write_header(FluxoOutput *output, int fragmented) {
    AVFormatContext *context = output->context;
    int ret;
    if (!fragmented) {
        ret = avformat_write_header(context, NULL);
    } else {
        AVDictionary *options = fluxo_fragmented_options();
        AVIOContext *segment = context->pb;
        ret = avio_open_dyn_buf(&context->pb);
        if (ret >= 0) {
            ret = avformat_write_header(context, &options);
            uint8_t *discarded = NULL;
            avio_close_dyn_buf(context->pb, &discarded);
            av_free(discarded);
        }
        context->pb = segment;
        av_dict_free(&options);
    }
    if (ret >= 0) {
        output->header_written = 1;
    }
    return ret < 0 ? ret : 0;
}

// Writes the packets buffered for the current segment into its file. The first flush of a fragmented MP4
// muxer writes only the ftyp and moov (delay_moov): the first time into the initialization segment
// `init_path`, later (every run of an on-demand input has the same moov) into a discarded buffer; then the
// fragment follows.
int fluxo_output_flush(FluxoOutput *output, int fragmented, const char *init_path, int *init_written, int *moov_flushed) {
    AVFormatContext *context = output->context;
    if (!fragmented) {
        int ret = av_write_frame(context, NULL);
        return ret < 0 ? ret : 0;
    }
    if (!*moov_flushed) {
        AVIOContext *segment = context->pb;
        char temporary[PATH_MAX];
        snprintf(temporary, sizeof(temporary), "%s.tmp", init_path);
        int write_init = !*init_written;
        int ret = write_init ? avio_open(&context->pb, temporary, AVIO_FLAG_WRITE) : avio_open_dyn_buf(&context->pb);
        if (ret >= 0) {
            ret = av_write_frame(context, NULL);
            if (write_init) {
                avio_flush(context->pb);
                if (avio_closep(&context->pb) < 0 && ret >= 0) {
                    ret = AVERROR(EIO);
                }
                if (ret >= 0 && rename(temporary, init_path) != 0) {
                    ret = AVERROR(errno);
                }
                if (ret < 0) {
                    unlink(temporary);
                } else {
                    *init_written = 1;
                }
            } else {
                uint8_t *discarded = NULL;
                avio_close_dyn_buf(context->pb, &discarded);
                av_free(discarded);
            }
        }
        context->pb = segment;
        if (ret < 0) {
            return ret;
        }
        *moov_flushed = 1;
    }
    int ret = av_write_frame(context, NULL);
    return ret < 0 ? ret : 0;
}

// Muxing delay of the MPEG-TS outputs of a master playlist. The main output and the audio renditions are
// separate muxers, so they must put the same timestamps on the same media: an explicit delay, and no
// automatic shift of negative timestamps (libavformat would shift each muxer by its own first packet).
// Fragmented MP4 outputs (HEVC video and its audio renditions) write their timestamps as they are.
#define FLUXO_RENDITION_MUX_DELAY 700000

// Aligns an MPEG-TS muxer of a master playlist (the main output or an audio rendition), see above, and sets
// the time of output time 0 in the segments, for the X-TIMESTAMP-MAP of the WebVTT segments: the MPEG-TS
// muxer adds twice its maximum delay to every timestamp (90 kHz clock). With fragmented MP4 it stays 0: the
// map then refers to the media timeline itself.
void fluxo_hls_align_muxer(FluxoHLS *hls, AVFormatContext *context) {
    context->max_delay = FLUXO_RENDITION_MUX_DELAY;
    context->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    hls->mpegts_time_zero = av_rescale(FLUXO_RENDITION_MUX_DELAY, 90000, AV_TIME_BASE) * 2;
}

// Allocates the HLS muxer for the input. The caller opens the segment file and writes the header.
int fluxo_hls_prepare_output(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    hls->fragmented = fluxo_hls_wants_fragmented_mp4(session->input);
    hls->segment_extension = hls->fragmented ? "m4s" : "ts";
    hls->moov_flushed = 0;
    int ret = fluxo_output_prepare(&hls->output, session->input, hls->fragmented ? "mp4" : "mpegts", NULL);
    if (ret < 0) {
        return ret;
    }
    // Timestamps are positive (FLUXO_TIMESTAMP_BASE) and are kept as they are: segments of different
    // runs of an on-demand input (after a seek) are placed by their own timestamps.
    hls->output.context->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    // The MP4 muxer does not insert aac_adtstoasc itself when the moov comes first.
    hls->output.convert_adts = hls->fragmented;
    if (hls->rendition_count > 0 && !hls->fragmented) {
        fluxo_hls_align_muxer(hls, hls->output.context);
    }
    return 0;
}

int fluxo_hls_write_header(FluxoHLS *hls) {
    return fluxo_output_write_header(&hls->output, hls->fragmented);
}

int fluxo_hls_flush(FluxoHLS *hls) {
    return fluxo_output_flush(&hls->output, hls->fragmented, hls->init_path, &hls->init_written, &hls->moov_flushed);
}

void fluxo_hls_delete_segment(const FluxoHLS *hls, int64_t sequence) {
    char path[PATH_MAX];
    fluxo_hls_segment_path(hls, sequence, 0, path, sizeof(path));
    unlink(path);
    fluxo_hls_delete_rendition_segments(hls, sequence);
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

// Closes `file`, written at `tmp_path`, and puts it at `path` in one step (an atomic replacement: the HTTP server
// never serves a partially written playlist or segment). On a write error the temporary file is deleted.
int fluxo_publish_file(FILE *file, const char *tmp_path, const char *path) {
    int failed = ferror(file);
    if (fclose(file) != 0 || failed) {
        unlink(tmp_path);
        return AVERROR(EIO);
    }
    if (rename(tmp_path, path) != 0) {
        return AVERROR(errno);
    }
    return 0;
}

// The EXT-X-MAP of a media playlist of fragmented MP4 segments: its initialization segment, next to the playlist.
void fluxo_write_map(FILE *file, const char *init_path) {
    const char *slash = strrchr(init_path, '/');
    fprintf(file, "#EXT-X-MAP:URI=\"%s\"\n", slash != NULL ? slash + 1 : init_path);
}

// Writes one media playlist of the window: the main one, or a rendition's (same segments, other files).
// `init_path`: the initialization segment of fragmented MP4 segments (EXT-X-MAP), NULL for MPEG-TS and WebVTT.
static int fluxo_hls_write_media_playlist(FluxoHLS *hls, const char *path, const char *tmp_path, const char *base_name,
                                          const char *extension, const char *init_path, int independent, int ended) {
    FILE *file = fopen(tmp_path, "w");
    if (file == NULL) {
        return AVERROR(errno);
    }
    int64_t media_sequence = hls->count > 0 ? hls->segments[0].sequence : hls->next_sequence;
    int unlimited = hls->max_window_duration <= 0 && hls->max_window_bytes <= 0;

    // fMP4 segments (EXT-X-MAP in a media playlist without I-frames only) need version 6; 7 is what
    // Apple's tools write for them.
    fprintf(file, "#EXTM3U\n#EXT-X-VERSION:%d\n", init_path != NULL ? 7 : 3);
    fprintf(file, "#EXT-X-TARGETDURATION:%d\n", hls->target_duration);
    fprintf(file, "#EXT-X-MEDIA-SEQUENCE:%lld\n", (long long)media_sequence);
    if (hls->discontinuity_sequence > 0) {
        fprintf(file, "#EXT-X-DISCONTINUITY-SEQUENCE:%lld\n", (long long)hls->discontinuity_sequence);
    }
    if (unlimited) {
        // Nothing is ever removed: lets players seek back to the very beginning.
        fprintf(file, "#EXT-X-PLAYLIST-TYPE:EVENT\n");
        if (!hls->program_date_time) {
            // An on-demand input still being read: AVPlayer would join a growing playlist near its end,
            // like a live stream; a movie starts at its beginning.
            fprintf(file, "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n");
        }
    }
    if (independent) {
        fprintf(file, "#EXT-X-INDEPENDENT-SEGMENTS\n");
    }
    if (init_path != NULL) {
        fluxo_write_map(file, init_path);
    }
    for (int i = 0; i < hls->count; i++) {
        const FluxoSegment *segment = &hls->segments[i];
        if (segment->discontinuity) {
            fprintf(file, "#EXT-X-DISCONTINUITY\n");
        }
        if (hls->program_date_time) {
            time_t seconds = (time_t)(segment->date_ms / 1000);
            struct tm utc;
            gmtime_r(&seconds, &utc);
            char date[32];
            strftime(date, sizeof(date), "%Y-%m-%dT%H:%M:%S", &utc);
            fprintf(file, "#EXT-X-PROGRAM-DATE-TIME:%s.%03dZ\n", date, (int)(segment->date_ms % 1000));
        }
        fprintf(file, "#EXTINF:%.3f,\n%s-%06lld.%s\n", segment->duration, base_name, (long long)segment->sequence, extension);
    }
    if (ended) {
        fprintf(file, "#EXT-X-ENDLIST\n");
    }
    return fluxo_publish_file(file, tmp_path, path);
}

// Rewrites the playlists of the renditions, then the main one, so that no rendition is ever behind it.
int fluxo_hls_write_playlist(FluxoHLS *hls, int ended) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->muxed) {
            continue;
        }
        int is_audio = rendition->type == FluxoRenditionAudio;
        int ret = fluxo_hls_write_media_playlist(hls, rendition->playlist_path, rendition->playlist_tmp_path, rendition->base_name,
                                                 fluxo_rendition_extension(rendition), rendition->fragmented ? rendition->init_path : NULL,
                                                 is_audio, ended);
        if (ret < 0) {
            return ret;
        }
    }
    return fluxo_hls_write_media_playlist(hls, hls->playlist_path, hls->playlist_tmp_path, hls->segment_base_name,
                                          hls->segment_extension, hls->fragmented ? hls->init_path : NULL,
                                          hls->output.video_index >= 0, ended);
}

static int fluxo_hls_open_segment(FluxoHLS *hls) {
    char path[PATH_MAX];
    fluxo_hls_segment_path(hls, hls->next_sequence, 1, path, sizeof(path));
    int ret = avio_open(&hls->output.context->pb, path, AVIO_FLAG_WRITE);
    if (ret < 0) {
        return ret;
    }
    if (!hls->fragmented && (hls->segments_written > 0 || hls->count > 0)) {
        // Every segment must start with PAT/PMT so that it can be decoded on its own.
        av_opt_set(hls->output.context->priv_data, "mpegts_flags", "+resend_headers", 0);
    }
    hls->segment_open = 1;
    ret = fluxo_hls_open_rendition_segments(hls, hls->next_sequence, hls->segments_written > 0 || hls->count > 0);
    if (ret < 0) {
        return ret;
    }
    hls->segment_start_time = AV_NOPTS_VALUE;
    hls->segment_cut_on_audio = 0;
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
        int ret = fluxo_hls_flush(hls);
        if (ret < 0) {
            return ret;
        }
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
        fluxo_hls_close_rendition_segments(hls, hls->next_sequence, flush, 0);
        return ended ? fluxo_hls_write_playlist(hls, 1) : 0;
    }
    if (rename(temporary, final_path) != 0) {
        return AVERROR(errno);
    }
    // The renditions' segments of the same span, under the same sequence number.
    int64_t rendition_bytes = fluxo_hls_close_rendition_segments(hls, hls->next_sequence, flush, 1);
    if (rendition_bytes < 0) {
        return (int)rendition_bytes;
    }
    int64_t subtitle_bytes = fluxo_hls_write_subtitle_segments(hls, hls->next_sequence, hls->segment_start_time, end_time, ended);
    if (subtitle_bytes < 0) {
        return (int)subtitle_bytes;
    }
    bytes += rendition_bytes + subtitle_bytes;

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
    if (!hls->dated) {
        hls->dated = 1;
        hls->date_origin_ms = hls->segment_wallclock_ms;
        hls->date_media_ms = 0;
    }
    segment->date_ms = hls->date_origin_ms + hls->date_media_ms;
    // (The EXTINF of the playlist, rounded the same way: "%.3f".)
    hls->date_media_ms += llround(duration * 1000);
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
    if (!hls->master_written && hls->rendition_count > 0) {
        // Before the first SegmentWritten event: the player opens the master playlist when it gets it.
        ret = fluxo_hls_write_master(session);
        if (ret < 0) {
            return ret;
        }
    }
    // A segment is the proof that the (re)connection works.
    session->reconnect_attempt = 0;
    // (The window may have been pruned: `segment` no longer points at this segment.)
    session->event_segment_index = hls->next_sequence - 1;
    if (!session->is_live) {
        pthread_mutex_lock(&session->vod_lock);
        session->vod_available = hls->next_sequence;
        session->vod_init_ready = hls->init_written || !hls->fragmented;
        pthread_mutex_unlock(&session->vod_lock);
    }
    fluxo_emit(session, FluxoRemuxEventSegmentWritten, 0, NULL);
    return 0;
}

int fluxo_hls_open(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    int ret = fluxo_hls_plan_renditions(session);
    if (ret < 0) {
        return ret;
    }
    ret = fluxo_hls_prepare_output(session);
    if (ret < 0) {
        return ret;
    }
    ret = fluxo_hls_prepare_renditions(session);
    if (ret < 0) {
        return ret;
    }
    hls->reference_stream = hls->output.video_index >= 0 ? hls->output.video_index : 0;
    hls->target_duration = (int)ceil(hls->segment_duration);

    ret = fluxo_hls_open_segment(hls);
    if (ret < 0) {
        return ret;
    }
    ret = fluxo_hls_write_header(hls);
    if (ret < 0) {
        return ret;
    }
    // The master playlist is written with the first segment (fluxo_hls_finish_segment).
    return fluxo_hls_write_rendition_headers(hls);
}

static int fluxo_hls_write_main(FluxoRemuxSession *session, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    FluxoHLS *hls = &session->hls;
    // Converted video whose encoder is refused (the app in the background, Picture in Picture) gives no packets:
    // the audio cuts the segments meanwhile, so that it keeps playing.
    int audio_cuts = hls->output.video_index >= 0 && in_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
                     fluxo_streams_video_stalled(&session->streams);
    if (audio_cuts) {
        hls->output.wait_keyframe = 0;
    }
    int ret = fluxo_output_prepare_packet(&hls->output, packet, in_stream, scratch);
    if (ret <= 0) {
        return ret;
    }

    if (scratch->stream_index == hls->reference_stream || audio_cuts) {
        int64_t time = fluxo_packet_time(scratch, hls->output.context->streams[scratch->stream_index]);
        if (time != AV_NOPTS_VALUE) {
            if (hls->segment_start_time == AV_NOPTS_VALUE) {
                hls->segment_start_time = time;
            } else {
                int key = hls->output.video_index >= 0 && scratch->stream_index == hls->output.video_index && (scratch->flags & AV_PKT_FLAG_KEY);
                int cut_point = hls->output.video_index < 0 || key || audio_cuts;
                int64_t elapsed = time - hls->segment_start_time;
                // The tolerance is for key frames placed a little early; audio cuts exactly at the duration.
                int64_t tolerance = key ? FLUXO_SEGMENT_CUT_TOLERANCE : 0;
                int due = elapsed >= (int64_t)(hls->segment_duration * AV_TIME_BASE) - tolerance ||
                          (key && hls->segment_cut_on_audio && elapsed > 0);
                if (cut_point && due) {
                    ret = fluxo_hls_finish_segment(session, time, 1, 0);
                    if (ret >= 0) {
                        ret = fluxo_hls_open_segment(hls);
                    }
                    if (ret < 0) {
                        av_packet_unref(scratch);
                        return ret;
                    }
                    hls->segment_start_time = time;
                    hls->segment_cut_on_audio = audio_cuts;
                }
            }
            if (hls->last_reference_time == AV_NOPTS_VALUE || time > hls->last_reference_time) {
                hls->last_reference_time = time;
            }
        }
    }
    return fluxo_output_commit(&hls->output, scratch);
}

// Writes a packet to the main media playlist (cutting its segments) and to the renditions.
int fluxo_hls_write(FluxoRemuxSession *session, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    FluxoHLS *hls = &session->hls;
    if (hls->rendition_count > 0 && !hls->master_written && !hls->closed_captions && hls->output.video_index >= 0
        && packet->stream_index >= 0 && (unsigned int)packet->stream_index < hls->output.stream_map_size
        && hls->output.stream_map[packet->stream_index] == hls->output.video_index) {
        hls->closed_captions = fluxo_packet_has_closed_captions(packet);
    }
    int ret = fluxo_hls_write_main(session, packet, in_stream, scratch);
    if (ret < 0 || session->hls.rendition_count == 0 || !session->hls.output.header_written) {
        return ret;
    }
    return fluxo_hls_write_renditions(&session->hls, packet, in_stream, scratch);
}

// Ends the current segment early, e.g. before a reconnection, and marks the next one as discontinuous.
int fluxo_hls_break(FluxoRemuxSession *session) {
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

void fluxo_hls_close(FluxoRemuxSession *session, int ended) {
    FluxoHLS *hls = &session->hls;
    if (hls->output.header_written) {
        // Drains the muxer into the current segment, which is then published with EXT-X-ENDLIST. A
        // fragmented MP4 muxer is flushed first, so that its moov (if not written yet) goes to the
        // initialization segment.
        if (hls->fragmented && hls->segment_open) {
            fluxo_hls_flush(hls);
        }
        av_write_trailer(hls->output.context);
        for (int i = 0; i < hls->rendition_count; i++) {
            FluxoRendition *rendition = &hls->renditions[i];
            if (rendition->output.header_written && rendition->output.context->pb != NULL) {
                if (rendition->fragmented) {
                    fluxo_output_flush(&rendition->output, 1, rendition->init_path, &rendition->init_written, &rendition->moov_flushed);
                }
                av_write_trailer(rendition->output.context);
            }
        }
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
        fluxo_hls_close_rendition_segments(hls, hls->next_sequence, 0, 0);
        hls->segment_open = 0;
    }
    fluxo_output_free(&hls->output);
    for (int i = 0; i < hls->rendition_count; i++) {
        fluxo_output_free(&hls->renditions[i].output);
    }
}
