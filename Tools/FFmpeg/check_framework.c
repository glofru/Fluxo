// Checks the bundled FFmpeg build (see check.sh): version, license, the components the remux
// engine needs and, for every URL given on the command line, that it opens and probes (this is
// how https through Secure Transport is verified).
//
// Exit status: 0 when every check passes, 1 otherwise.

#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

static int failures = 0;

static void expect(int condition, const char *what, const char *name) {
    if (!condition) {
        fprintf(stderr, "missing %s: %s\n", what, name);
        failures++;
    }
}

static int has_protocol(const char *name) {
    void *opaque = NULL;
    const char *protocol;
    while ((protocol = avio_enum_protocols(&opaque, 0)) != NULL) {
        if (strcmp(protocol, name) == 0) {
            return 1;
        }
    }
    return 0;
}

static void probe(const char *url) {
    AVFormatContext *input = NULL;
    AVDictionary *options = NULL;
    av_dict_set(&options, "rw_timeout", "15000000", 0);
    int ret = avformat_open_input(&input, url, NULL, &options);
    av_dict_free(&options);
    if (ret >= 0) {
        ret = avformat_find_stream_info(input, NULL);
    }
    if (ret < 0) {
        fprintf(stderr, "cannot open %s: %s\n", url, av_err2str(ret));
        failures++;
    } else {
        printf("opened %s: %s, %u streams\n", url, input->iformat->name, input->nb_streams);
        for (unsigned int i = 0; i < input->nb_streams; i++) {
            const AVCodecParameters *codec = input->streams[i]->codecpar;
            printf("  stream %u: %s %s\n", i, av_get_media_type_string(codec->codec_type), avcodec_get_name(codec->codec_id));
        }
    }
    avformat_close_input(&input);
}

int main(int argc, char **argv) {
    avformat_network_init();
    av_log_set_level(AV_LOG_ERROR);

    printf("FFmpeg %s\n", av_version_info());
    printf("license: %s\n", avformat_license());
    expect(strstr(avformat_license(), "LGPL") != NULL, "LGPL license", avformat_license());

    const char *demuxers[] = {"mpegts", "hls", "webvtt", "mov", "flv", "live_flv", "matroska", "mpeg", "rtsp", "sdp", "aac", "mp3", "h264", "hevc"};
    for (size_t i = 0; i < sizeof(demuxers) / sizeof(*demuxers); i++) {
        expect(av_find_input_format(demuxers[i]) != NULL, "demuxer", demuxers[i]);
    }
    const char *muxers[] = {"mpegts", "mp4", "mov"};
    for (size_t i = 0; i < sizeof(muxers) / sizeof(*muxers); i++) {
        expect(av_guess_format(muxers[i], NULL, NULL) != NULL, "muxer", muxers[i]);
    }
    expect(av_guess_format(NULL, "recording.mp4", NULL) != NULL, "muxer for", "recording.mp4");
    const char *protocols[] = {"file", "http", "https", "tcp", "tls", "udp", "rtp", "rtmp", "rtmps", "crypto"};
    for (size_t i = 0; i < sizeof(protocols) / sizeof(*protocols); i++) {
        expect(has_protocol(protocols[i]), "protocol", protocols[i]);
    }
    const char *bsfs[] = {"aac_adtstoasc", "h264_mp4toannexb", "hevc_mp4toannexb", "extract_extradata"};
    for (size_t i = 0; i < sizeof(bsfs) / sizeof(*bsfs); i++) {
        expect(av_bsf_get_by_name(bsfs[i]) != NULL, "bitstream filter", bsfs[i]);
    }
    const enum AVCodecID decoders[] = {AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_MP3,
                                       AV_CODEC_ID_MP2, AV_CODEC_ID_MPEG2VIDEO};
    for (size_t i = 0; i < sizeof(decoders) / sizeof(*decoders); i++) {
        expect(avcodec_find_decoder(decoders[i]) != NULL, "decoder", avcodec_get_name(decoders[i]));
    }
    printf("components: %s\n", failures == 0 ? "ok" : "MISSING");

    for (int i = 1; i < argc; i++) {
        probe(argv[i]);
    }

    avformat_network_deinit();
    return failures == 0 ? 0 : 1;
}
