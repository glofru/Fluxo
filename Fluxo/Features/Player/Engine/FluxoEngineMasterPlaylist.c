//
//  FluxoEngineMasterPlaylist.c
//  Fluxo
//
//  The master playlist: the CODECS of the variant (RFC 6381 names), closed captions, and its renditions.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

static void fluxo_write_media_attributes(FILE *file, const FluxoRendition *rendition) {
    if (rendition->language[0] != '\0') {
        fprintf(file, ",LANGUAGE=\"%s\"", rendition->language);
    }
}

// Looks for ATSC A/53 caption data ("GA94" user data, type 3: cc_data) in a video packet: an H.264 / HEVC SEI
// (registered ITU-T T.35) or MPEG-2 user data. Compressed data almost never contains these five bytes by chance.
int fluxo_packet_has_closed_captions(const AVPacket *packet) {
    static const uint8_t marker[] = {'G', 'A', '9', '4', 0x03};
    return packet->data != NULL && packet->size >= (int)sizeof(marker)
        && memmem(packet->data, (size_t)packet->size, marker, sizeof(marker)) != NULL;
}

// The RFC 6381 name of an H.264 stream ("avc1.PPCCLL") from its SPS (avcC or Annex B extradata). Returns 0
// when the stream does not carry one.
static int fluxo_avc_codec_name(const AVCodecParameters *codecpar, char *buffer, size_t size) {
    const uint8_t *data = codecpar->extradata;
    int length = codecpar->extradata_size;
    if (data == NULL || length < 4) {
        return 0;
    }
    if (data[0] == 1) {
        // avcC: version, profile, constraint flags, level.
        snprintf(buffer, size, "avc1.%02X%02X%02X", data[1], data[2], data[3]);
        return 1;
    }
    for (int i = 0; i + 6 < length; i++) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 && (data[i + 3] & 0x1F) == 7) {
            snprintf(buffer, size, "avc1.%02X%02X%02X", data[i + 4], data[i + 5], data[i + 6]);
            return 1;
        }
    }
    return 0;
}

// The RFC 6381 name of an audio codec, or NULL when it is not one this engine names exactly.
static const char *fluxo_audio_codec_name(enum AVCodecID codec_id, int profile) {
    switch (codec_id) {
    case AV_CODEC_ID_AAC:
        if (profile == AV_PROFILE_AAC_HE) {
            return "mp4a.40.5";
        }
        if (profile == AV_PROFILE_AAC_HE_V2) {
            return "mp4a.40.29";
        }
        return profile == AV_PROFILE_AAC_LOW || profile == AV_PROFILE_UNKNOWN ? "mp4a.40.2" : NULL;
    case AV_CODEC_ID_AC3:
        return "ac-3";
    case AV_CODEC_ID_EAC3:
        return "ec-3";
    case AV_CODEC_ID_MP3:
        return "mp4a.40.34";
    default:
        return NULL;
    }
}

// Adds `name` to the comma-separated list `buffer` once. Returns 0 when it does not fit.
static int fluxo_codecs_add(char *buffer, size_t size, const char *name) {
    size_t used = strlen(buffer);
    size_t name_length = strlen(name);
    for (const char *at = strstr(buffer, name); at != NULL; at = strstr(at + 1, name)) {
        if ((at == buffer || at[-1] == ',') && (at[name_length] == ',' || at[name_length] == '\0')) {
            return 1;
        }
    }
    if (used + (used > 0 ? 1 : 0) + name_length + 1 > size) {
        return 0;
    }
    if (used > 0) {
        buffer[used++] = ',';
    }
    memcpy(buffer + used, name, name_length + 1);
    return 1;
}

// The CODECS attribute of the variant: the video and every audio rendition. Returns 0 (and no attribute is
// written) when one of them cannot be named exactly: a partial or wrong list is worse than none, since the
// player takes it as the complete list of what it must decode.
static int fluxo_hls_codecs(FluxoRemuxSession *session, char *buffer, size_t size) {
    FluxoHLS *hls = &session->hls;
    buffer[0] = '\0';
    AVFormatContext *output = hls->output.context;
    if (output == NULL) {
        return 0;
    }
    for (unsigned int i = 0; i < output->nb_streams; i++) {
        const AVCodecParameters *codecpar = output->streams[i]->codecpar;
        if (codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            char video[32];
            if (codecpar->codec_id != AV_CODEC_ID_H264 || !fluxo_avc_codec_name(codecpar, video, sizeof(video)) ||
                !fluxo_codecs_add(buffer, size, video)) {
                return 0;
            }
        } else if (codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            const char *audio = fluxo_audio_codec_name(codecpar->codec_id, codecpar->profile);
            if (audio == NULL || !fluxo_codecs_add(buffer, size, audio)) {
                return 0;
            }
        }
    }
    for (int i = 0; i < hls->rendition_count; i++) {
        const FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type != FluxoRenditionAudio) {
            continue;
        }
        int profile = AV_PROFILE_UNKNOWN;
        if (rendition->input_index >= 0 && (unsigned int)rendition->input_index < session->input->nb_streams) {
            profile = fluxo_stream_parameters(session->input, (unsigned int)rendition->input_index)->profile;
        }
        const char *audio = fluxo_audio_codec_name(rendition->codec_id, profile);
        if (audio == NULL || !fluxo_codecs_add(buffer, size, audio)) {
            return 0;
        }
    }
    return buffer[0] != '\0';
}

// Writes the master playlist: one variant (the main media playlist), its audio renditions and subtitles.
// Written with the first segment, once its video shows whether the stream carries closed captions.
int fluxo_hls_write_master(FluxoRemuxSession *session) {
    FluxoHLS *hls = &session->hls;
    if (hls->rendition_count == 0) {
        return 0;
    }
    FILE *file = fopen(hls->master_tmp_path, "w");
    if (file == NULL) {
        return AVERROR(errno);
    }
    int has_audio_group = hls->audio_rendition_count > 0;
    int has_subtitles = hls->subtitle_rendition_count > 0;
    fprintf(file, "#EXTM3U\n#EXT-X-VERSION:4\n");
    if (hls->output.video_index >= 0) {
        fprintf(file, "#EXT-X-INDEPENDENT-SEGMENTS\n");
    }
    for (int i = 0; i < hls->rendition_count; i++) {
        const FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type != FluxoRenditionAudio) {
            continue;
        }
        fprintf(file, "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"%s\"", rendition->name);
        fluxo_write_media_attributes(file, rendition);
        fprintf(file, ",DEFAULT=%s,AUTOSELECT=YES", rendition->muxed ? "YES" : "NO");
        if (rendition->channels > 0) {
            fprintf(file, ",CHANNELS=\"%d\"", rendition->channels);
        }
        if (rendition->visual_impaired) {
            fprintf(file, ",CHARACTERISTICS=\"public.accessibility.describes-video\"");
        }
        if (!rendition->muxed) {
            fprintf(file, ",URI=\"%s.m3u8\"", rendition->base_name);
        }
        fprintf(file, "\n");
    }
    for (int i = 0; i < hls->rendition_count; i++) {
        const FluxoRendition *rendition = &hls->renditions[i];
        if (rendition->type != FluxoRenditionSubtitles) {
            continue;
        }
        fprintf(file, "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"%s\"", rendition->name);
        fluxo_write_media_attributes(file, rendition);
        // Subtitles are never on by default: the system turns them on (accessibility settings, a foreign
        // language) and shows forced ones with their audio.
        fprintf(file, ",DEFAULT=NO,AUTOSELECT=YES,FORCED=%s", rendition->forced ? "YES" : "NO");
        if (rendition->hearing_impaired) {
            fprintf(file, ",CHARACTERISTICS=\"public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound\"");
        }
        fprintf(file, ",URI=\"%s.m3u8\"\n", rendition->base_name);
    }
    if (hls->closed_captions && hls->output.video_index >= 0) {
        fprintf(file, "#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID=\"cc\",NAME=\"CC\",DEFAULT=NO,AUTOSELECT=YES,INSTREAM-ID=\"CC1\"\n");
    }

    int64_t bandwidth = session->input->bit_rate > 0 ? session->input->bit_rate : 4000000;
    fprintf(file, "#EXT-X-STREAM-INF:BANDWIDTH=%lld", (long long)bandwidth);
    if (hls->output.video_index >= 0) {
        const AVCodecParameters *video = hls->output.context->streams[hls->output.video_index]->codecpar;
        if (video->width > 0 && video->height > 0) {
            fprintf(file, ",RESOLUTION=%dx%d", video->width, video->height);
        }
    }
    char codecs[192];
    if (fluxo_hls_codecs(session, codecs, sizeof(codecs))) {
        fprintf(file, ",CODECS=\"%s\"", codecs);
    }
    if (has_audio_group) {
        fprintf(file, ",AUDIO=\"audio\"");
    }
    if (has_subtitles) {
        fprintf(file, ",SUBTITLES=\"subs\"");
    }
    if (hls->output.video_index >= 0) {
        // Without the attribute AVPlayer offers a "CC" option even when the video has no captions.
        fprintf(file, hls->closed_captions ? ",CLOSED-CAPTIONS=\"cc\"" : ",CLOSED-CAPTIONS=NONE");
    }
    fprintf(file, "\n%s.m3u8\n", hls->segment_base_name);

    int ret = fluxo_publish_file(file, hls->master_tmp_path, hls->master_path);
    if (ret < 0) {
        return ret;
    }
    hls->master_written = 1;
    return 0;
}
