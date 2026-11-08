//
//  FluxoEngineRenditions.c
//  Fluxo
//
//  The renditions of a master playlist: extra audio tracks and text subtitles, their segments and cues.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

// MARK: - Renditions (alternative audio and subtitles)

static int fluxo_is_text_subtitle(enum AVCodecID codec_id) {
    switch (codec_id) {
    case AV_CODEC_ID_SUBRIP:
    case AV_CODEC_ID_TEXT:
    case AV_CODEC_ID_ASS:
    case AV_CODEC_ID_SSA:
    case AV_CODEC_ID_WEBVTT:
    case AV_CODEC_ID_MOV_TEXT:
        return 1;
    default:
        return 0;
    }
}

// Audio codecs HLS players decode (Apple's HLS authoring specification): only these become renditions.
// MPEG-1 Layer II (DVB channels; on iOS it is converted to AAC) and others stay out of the master playlist:
// AVPlayer on iOS fails the whole item when it switches to one ("fmt?"). Converted streams are AAC.
static int fluxo_is_hls_audio(const AVFormatContext *input, unsigned int index) {
    switch (fluxo_stream_parameters(input, index)->codec_id) {
    case AV_CODEC_ID_AAC:
    case AV_CODEC_ID_AC3:
    case AV_CODEC_ID_EAC3:
    case AV_CODEC_ID_MP3:
        return 1;
    default:
        return 0;
    }
}

static int fluxo_is_subtitle_source(const AVStream *stream) {
    return stream->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && fluxo_is_text_subtitle(stream->codecpar->codec_id);
}

// The input stream of `rendition` in `input`, or -1.
static int fluxo_rendition_find_source(const FluxoRendition *rendition, const AVFormatContext *input) {
    int ordinal = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        const AVStream *stream = input->streams[i];
        int matches = rendition->type == FluxoRenditionAudio
            ? fluxo_is_stream_supported(stream) && stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO
            : fluxo_is_subtitle_source(stream);
        if (!matches) {
            continue;
        }
        if (ordinal == rendition->ordinal) {
            if (rendition->type == FluxoRenditionSubtitles && stream->codecpar->codec_id != rendition->codec_id) {
                return -1;
            }
            return (int)i;
        }
        ordinal++;
    }
    return -1;
}

static void fluxo_rendition_drop_cue(FluxoRendition *rendition, int index) {
    free(rendition->cues[index].text);
    memmove(rendition->cues + index, rendition->cues + index + 1, sizeof(FluxoCue) * (size_t)(rendition->cue_count - index - 1));
    rendition->cue_count--;
}

// Queues the cue of a subtitle packet (output time base, already adjusted) for the next segments.
static int fluxo_rendition_add_cue(FluxoRendition *rendition, const AVPacket *packet, const AVStream *in_stream) {
    int64_t start = fluxo_packet_time(packet, in_stream);
    if (start == AV_NOPTS_VALUE) {
        return 0;
    }
    int64_t duration = packet->duration > 0 ? av_rescale_q(packet->duration, in_stream->time_base, AV_TIME_BASE_Q) : 0;
    if (duration <= 0) {
        duration = FLUXO_DEFAULT_CUE_DURATION;
    }
    char *text = fluxo_subtitle_text(rendition->codec_id, packet->data, packet->size);
    if (text == NULL) {
        return 0;
    }
    // The same cue read again (an on-demand input read over the same span after a seek or a reopen).
    for (int i = rendition->cue_count - 1; i >= 0 && rendition->cues[i].start >= start; i--) {
        if (rendition->cues[i].start == start && rendition->cues[i].end == start + duration && strcmp(rendition->cues[i].text, text) == 0) {
            free(text);
            return 0;
        }
    }
    if (rendition->cue_count == FLUXO_MAX_PENDING_CUES) {
        fluxo_rendition_drop_cue(rendition, 0);
    }
    if (rendition->cue_count == rendition->cue_capacity) {
        int capacity = rendition->cue_capacity > 0 ? rendition->cue_capacity * 2 : 32;
        FluxoCue *cues = realloc(rendition->cues, sizeof(FluxoCue) * (size_t)capacity);
        if (cues == NULL) {
            free(text);
            return AVERROR(ENOMEM);
        }
        rendition->cues = cues;
        rendition->cue_capacity = capacity;
    }
    // Kept in start order (demuxers deliver them in order, except around a reconnection).
    int index = rendition->cue_count;
    while (index > 0 && rendition->cues[index - 1].start > start) {
        index--;
    }
    memmove(rendition->cues + index + 1, rendition->cues + index, sizeof(FluxoCue) * (size_t)(rendition->cue_count - index));
    rendition->cues[index] = (FluxoCue){ .start = start, .end = start + duration, .text = text };
    rendition->cue_count++;
    return 0;
}

static void fluxo_vtt_time(int64_t time, char *buffer, size_t size) {
    if (time < 0) {
        time = 0;
    }
    int64_t milliseconds = time / 1000;
    snprintf(buffer, size, "%02lld:%02lld:%02lld.%03lld", (long long)(milliseconds / 3600000), (long long)(milliseconds / 60000 % 60),
             (long long)(milliseconds / 1000 % 60), (long long)(milliseconds % 1000));
}

// The extension of a rendition's segments.
const char *fluxo_rendition_extension(const FluxoRendition *rendition) {
    if (rendition->type == FluxoRenditionSubtitles) {
        return "vtt";
    }
    return rendition->fragmented ? "m4s" : "ts";
}

static void fluxo_rendition_segment_path(const FluxoRendition *rendition, int64_t sequence, int temporary, char *buffer, size_t size) {
    snprintf(buffer, size, "%s-%06lld.%s%s", rendition->base_path, (long long)sequence, fluxo_rendition_extension(rendition),
             temporary ? ".tmp" : "");
}

// Writes the WebVTT segment `sequence` covering [start, end) of the output timeline (the last segment also
// takes the cues after it), then forgets the cues that end within it. Returns its size or a negative error.
static int64_t fluxo_rendition_write_vtt(FluxoHLS *hls, FluxoRendition *rendition, int64_t sequence, int64_t start, int64_t end, int last) {
    char temporary[PATH_MAX];
    char final_path[PATH_MAX];
    fluxo_rendition_segment_path(rendition, sequence, 1, temporary, sizeof(temporary));
    fluxo_rendition_segment_path(rendition, sequence, 0, final_path, sizeof(final_path));
    FILE *file = fopen(temporary, "w");
    if (file == NULL) {
        return AVERROR(errno);
    }
    // The cue times are output times; the MPEG-TS segments carry them shifted by the muxing delay.
    fprintf(file, "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:%lld,LOCAL:00:00:00.000\n\n", (long long)hls->mpegts_time_zero);
    for (int i = 0; i < rendition->cue_count; i++) {
        const FluxoCue *cue = &rendition->cues[i];
        if (cue->end <= start || (!last && cue->start >= end)) {
            continue;
        }
        char from[32];
        char to[32];
        fluxo_vtt_time(cue->start, from, sizeof(from));
        fluxo_vtt_time(cue->end, to, sizeof(to));
        fprintf(file, "%s --> %s\n%s\n\n", from, to, cue->text);
    }
    int64_t bytes = ftell(file);
    int ret = fluxo_publish_file(file, temporary, final_path);
    if (ret < 0) {
        return ret;
    }
    // Cues that go on into the next segment are written again there (players drop the repeated cue).
    for (int i = rendition->cue_count - 1; i >= 0; i--) {
        if (last || rendition->cues[i].end <= end) {
            fluxo_rendition_drop_cue(rendition, i);
        }
    }
    return bytes > 0 ? bytes : 0;
}

void fluxo_hls_free_renditions(FluxoHLS *hls) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        fluxo_output_free(&rendition->output);
        for (int j = 0; j < rendition->cue_count; j++) {
            free(rendition->cues[j].text);
        }
        free(rendition->cues);
        free(rendition->base_path);
        free(rendition->playlist_path);
        free(rendition->playlist_tmp_path);
        free(rendition->init_path);
    }
    free(hls->renditions);
    hls->renditions = NULL;
    hls->rendition_count = 0;
    hls->audio_rendition_count = 0;
    hls->subtitle_rendition_count = 0;
}

static int fluxo_rendition_set_paths(FluxoHLS *hls, FluxoRendition *rendition, char kind, int number) {
    size_t length = strlen(hls->segment_prefix) + 16;
    rendition->base_path = malloc(length);
    rendition->playlist_path = malloc(length + 8);
    rendition->playlist_tmp_path = malloc(length + 12);
    rendition->init_path = malloc(length + 12);
    if (rendition->base_path == NULL || rendition->playlist_path == NULL || rendition->playlist_tmp_path == NULL ||
        rendition->init_path == NULL) {
        return AVERROR(ENOMEM);
    }
    snprintf(rendition->base_path, length, "%s-%c%d", hls->segment_prefix, kind, number);
    snprintf(rendition->playlist_path, length + 8, "%s.m3u8", rendition->base_path);
    snprintf(rendition->playlist_tmp_path, length + 12, "%s.m3u8.tmp", rendition->base_path);
    snprintf(rendition->init_path, length + 12, "%s-init.mp4", rendition->base_path);
    const char *slash = strrchr(rendition->base_path, '/');
    rendition->base_name = slash != NULL ? slash + 1 : rendition->base_path;
    return 0;
}

// Fills the name (unique in its group), language and flags of a rendition from its source stream.
static void fluxo_rendition_describe(FluxoHLS *hls, FluxoRendition *rendition, const AVStream *stream, int number) {
    const AVDictionaryEntry *language = av_dict_get(stream->metadata, "language", NULL, 0);
    const AVDictionaryEntry *title = av_dict_get(stream->metadata, "title", NULL, 0);
    fluxo_language_tag(language != NULL ? language->value : NULL, rendition->language, sizeof(rendition->language));
    rendition->is_default = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;
    rendition->forced = (stream->disposition & AV_DISPOSITION_FORCED) != 0;
    rendition->hearing_impaired = (stream->disposition & (AV_DISPOSITION_HEARING_IMPAIRED | AV_DISPOSITION_CAPTIONS)) != 0;
    rendition->visual_impaired = (stream->disposition & (AV_DISPOSITION_VISUAL_IMPAIRED | AV_DISPOSITION_DESCRIPTIONS)) != 0;
    rendition->channels = stream->codecpar->ch_layout.nb_channels;

    // The title of the track, else its language tag, else its number: the app shows the language in the
    // user's own language when the name is only the tag or a number.
    char base[96];
    fluxo_attribute_text(title != NULL ? title->value : NULL, base, sizeof(base));
    if (base[0] == '\0') {
        snprintf(base, sizeof(base), "%s", rendition->language[0] != '\0' ? rendition->language : "");
    }
    if (base[0] == '\0') {
        snprintf(base, sizeof(base), "%d", number);
    }
    snprintf(rendition->name, sizeof(rendition->name), "%s", base);
    for (int copy = 2; copy < 100; copy++) {
        int taken = 0;
        for (int i = 0; i < hls->rendition_count; i++) {
            const FluxoRendition *other = &hls->renditions[i];
            if (other != rendition && other->type == rendition->type && strcmp(other->name, rendition->name) == 0) {
                taken = 1;
                break;
            }
        }
        if (!taken) {
            break;
        }
        snprintf(rendition->name, sizeof(rendition->name), "%s %d", base, copy);
    }
}

// Decides the renditions from the streams of the input, before the main output is prepared: with two audio
// streams or more, the main output keeps only the default one. Returns 0 or a negative error.
int fluxo_hls_plan_renditions(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    AVFormatContext *input = session->input;
    if (hls->master_path == NULL) {
        return 0;
    }
    // Audio streams are counted by their ordinal among every supported audio stream (what the outputs
    // select by); only those in a codec HLS players decode can be renditions.
    int audio_total = 0;
    int hls_audio_count = 0;
    int subtitle_count = 0;
    int default_audio = -1;
    int first_hls_audio = -1;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        const AVStream *stream = input->streams[i];
        if (fluxo_is_stream_supported(stream) && stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            if (fluxo_is_hls_audio(input, i) && hls_audio_count < FLUXO_MAX_RENDITIONS) {
                if (first_hls_audio < 0) {
                    first_hls_audio = audio_total;
                }
                if (default_audio < 0 && (stream->disposition & AV_DISPOSITION_DEFAULT)) {
                    default_audio = audio_total;
                }
                hls_audio_count++;
            }
            audio_total++;
        } else if (fluxo_is_subtitle_source(stream)) {
            subtitle_count++;
        }
    }
    if (subtitle_count > FLUXO_MAX_RENDITIONS) {
        subtitle_count = FLUXO_MAX_RENDITIONS;
    }
    if (default_audio < 0) {
        default_audio = first_hls_audio;
    }
    // Two playable audio tracks or more: a rendition each. Otherwise the audio stays as it was (every audio
    // stream in the main playlist).
    int audio_renditions = hls_audio_count > 1 ? hls_audio_count : 0;
    if (audio_renditions == 0 && subtitle_count == 0) {
        return 0;
    }
    hls->renditions = calloc((size_t)(audio_renditions + subtitle_count), sizeof(FluxoRendition));
    if (hls->renditions == NULL) {
        return AVERROR(ENOMEM);
    }

    int audio_ordinal = 0;
    int audio_renditions_made = 0;
    int subtitle_ordinal = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        const AVStream *stream = input->streams[i];
        int is_audio = fluxo_is_stream_supported(stream) && stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO;
        int is_subtitle = fluxo_is_subtitle_source(stream);
        int takes_audio = is_audio && audio_renditions > 0 && audio_renditions_made < audio_renditions && fluxo_is_hls_audio(input, i);
        if ((is_audio && !takes_audio) || (is_subtitle && subtitle_ordinal >= subtitle_count) || (!is_audio && !is_subtitle)) {
            audio_ordinal += is_audio;
            continue;
        }
        FluxoRendition *rendition = &hls->renditions[hls->rendition_count++];
        rendition->type = is_audio ? FluxoRenditionAudio : FluxoRenditionSubtitles;
        rendition->ordinal = is_audio ? audio_ordinal : subtitle_ordinal;
        rendition->input_index = (int)i;
        rendition->codec_id = fluxo_stream_parameters(input, i)->codec_id;
        rendition->output.video_index = -1;
        int number = is_audio ? audio_ordinal + 1 : subtitle_ordinal + 1;
        fluxo_rendition_describe(hls, rendition, stream, number);
        // Converted audio has its own channel count (at most 5.1).
        rendition->channels = fluxo_stream_parameters(input, i)->ch_layout.nb_channels;
        if (is_audio) {
            rendition->muxed = audio_ordinal == default_audio;
            rendition->output.exclude_video = 1;
            rendition->output.audio_selection = audio_ordinal + 1;
            hls->audio_rendition_count++;
            audio_renditions_made++;
            audio_ordinal++;
        } else {
            hls->subtitle_rendition_count++;
            subtitle_ordinal++;
        }
        if (!rendition->muxed) {
            int ret = fluxo_rendition_set_paths(hls, rendition, is_audio ? 'a' : 's', number - 1);
            if (ret < 0) {
                return ret;
            }
        }
    }
    if (audio_renditions > 0) {
        // The main media playlist carries the video and the default audio track only.
        hls->output.audio_selection = default_audio + 1;
    }
    return 0;
}

// Prepares the muxers of the audio renditions (their segments are opened with the main ones).
int fluxo_hls_prepare_renditions(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type != FluxoRenditionAudio || rendition->muxed) {
            continue;
        }
        rendition->fragmented = hls->fragmented;
        rendition->moov_flushed = 0;
        int ret = fluxo_output_prepare(&rendition->output, session->input, rendition->fragmented ? "mp4" : "mpegts", NULL);
        if (ret < 0) {
            return ret;
        }
        if (rendition->fragmented) {
            rendition->output.context->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
            rendition->output.convert_adts = 1;
        } else {
            fluxo_hls_align_muxer(hls, rendition->output.context);
        }
    }
    return 0;
}

int fluxo_hls_write_rendition_headers(FluxoHLS *hls) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->output.context == NULL) {
            continue;
        }
        int ret = fluxo_output_write_header(&rendition->output, rendition->fragmented);
        if (ret < 0) {
            return ret;
        }
    }
    return 0;
}

// Finds the sources of the renditions in a reconnected input. A rendition whose stream is gone stays in
// the master playlist (it cannot be removed from a playlist the player has read) and gets no new media.
void fluxo_hls_remap_renditions(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        rendition->input_index = fluxo_rendition_find_source(rendition, session->input);
        if (rendition->output.context != NULL) {
            fluxo_output_map_input(&rendition->output, session->input);
        }
    }
}

// Opens audio segment `sequence` of every audio rendition (next to the main one). `resend_headers`: the muxer
// already wrote a segment, and this one must start with PAT/PMT too.
int fluxo_hls_open_rendition_segments(FluxoHLS *hls, int64_t sequence, int resend_headers) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->output.context == NULL) {
            continue;
        }
        char path[PATH_MAX];
        fluxo_rendition_segment_path(rendition, sequence, 1, path, sizeof(path));
        int ret = avio_open(&rendition->output.context->pb, path, AVIO_FLAG_WRITE);
        if (ret < 0) {
            return ret;
        }
        if (resend_headers && !rendition->fragmented) {
            av_opt_set(rendition->output.context->priv_data, "mpegts_flags", "+resend_headers", 0);
        }
    }
    return 0;
}

// Closes audio segment `sequence` of the renditions, keeping (publish) or deleting it with the main one.
// Returns the bytes kept, or a negative error.
int64_t fluxo_hls_close_rendition_segments(FluxoHLS *hls, int64_t sequence, int flush, int publish) {
    int64_t total = 0;
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        AVFormatContext *context = rendition->output.context;
        if (context == NULL || context->pb == NULL) {
            continue;
        }
        if (flush && rendition->output.header_written) {
            int ret = fluxo_output_flush(&rendition->output, rendition->fragmented, rendition->init_path, &rendition->init_written,
                                         &rendition->moov_flushed);
            if (ret < 0 && publish) {
                avio_closep(&context->pb);
                char temporary[PATH_MAX];
                fluxo_rendition_segment_path(rendition, sequence, 1, temporary, sizeof(temporary));
                unlink(temporary);
                return ret;
            }
        }
        avio_flush(context->pb);
        int64_t bytes = avio_tell(context->pb);
        avio_closep(&context->pb);
        char temporary[PATH_MAX];
        fluxo_rendition_segment_path(rendition, sequence, 1, temporary, sizeof(temporary));
        if (!publish) {
            unlink(temporary);
            continue;
        }
        char final_path[PATH_MAX];
        fluxo_rendition_segment_path(rendition, sequence, 0, final_path, sizeof(final_path));
        if (rename(temporary, final_path) != 0) {
            return AVERROR(errno);
        }
        total += bytes > 0 ? bytes : 0;
    }
    return total;
}

// Writes the WebVTT segments `sequence` of the segment being finished, [start, end) of the output timeline.
int64_t fluxo_hls_write_subtitle_segments(FluxoHLS *hls, int64_t sequence, int64_t start, int64_t end, int last) {
    int64_t total = 0;
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type != FluxoRenditionSubtitles) {
            continue;
        }
        int64_t bytes = fluxo_rendition_write_vtt(hls, rendition, sequence, start, end, last);
        if (bytes < 0) {
            return bytes;
        }
        total += bytes;
    }
    return total;
}

void fluxo_hls_delete_rendition_segments(const FluxoHLS *hls, int64_t sequence) {
    for (int i = 0; i < hls->rendition_count; i++) {
        const FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->muxed) {
            continue;
        }
        char path[PATH_MAX];
        fluxo_rendition_segment_path(rendition, sequence, 0, path, sizeof(path));
        unlink(path);
    }
}

// Copies a packet (output time base, already adjusted) to the renditions that take it.
int fluxo_hls_write_renditions(FluxoHLS *hls, const AVPacket *packet, const AVStream *in_stream, AVPacket *scratch) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type == FluxoRenditionSubtitles) {
            if (packet->stream_index == rendition->input_index) {
                int ret = fluxo_rendition_add_cue(rendition, packet, in_stream);
                if (ret < 0) {
                    return ret;
                }
            }
            continue;
        }
        if (rendition->output.context == NULL) {
            continue;
        }
        int ret = fluxo_output_prepare_packet(&rendition->output, packet, in_stream, scratch);
        if (ret < 0) {
            return ret;
        }
        if (ret > 0) {
            ret = fluxo_output_commit(&rendition->output, scratch);
            if (ret < 0) {
                return ret;
            }
        }
    }
    return 0;
}

// True when input stream `index` is the source of a subtitle rendition.
int fluxo_hls_is_subtitle_source(const FluxoHLS *hls, int index) {
    for (int i = 0; i < hls->rendition_count; i++) {
        if (hls->renditions[i].type == FluxoRenditionSubtitles && hls->renditions[i].input_index == index) {
            return 1;
        }
    }
    return 0;
}

// Forgets the subtitle cues waiting for their segments.
void fluxo_hls_clear_cues(FluxoHLS *hls) {
    for (int i = 0; i < hls->rendition_count; i++) {
        FluxoRendition *rendition = &hls->renditions[i];
        for (int j = 0; j < rendition->cue_count; j++) {
            free(rendition->cues[j].text);
        }
        rendition->cue_count = 0;
    }
}
