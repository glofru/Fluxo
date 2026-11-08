//
//  FluxoTranscoderInternal.h
//  Fluxo
//
//  Internal to the converter of the remux engine (FluxoTranscoder.c, FluxoTranscoderVideo.c, FluxoTranscoderAudio.c):
//  its limits, the state of one converted stream, and the functions one file calls in another. The rest of the engine
//  uses FluxoTranscoder.h.
//

#ifndef FLUXO_TRANSCODER_INTERNAL_H
#define FLUXO_TRANSCODER_INTERNAL_H

#include "FluxoTranscoder.h"

#include <TargetConditionals.h>
#include <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-html"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#include <libavcodec/bsf.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/hwcontext.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#pragma clang diagnostic pop

// Most audio streams of one input that are converted (each costs a decoder and an encoder while the input plays).
#define FLUXO_MAX_CONVERTED_AUDIO 4
// A converted audio stream whose input timestamps move this far from the samples produced so far starts again
// at the new time (a cut in a live stream, a damaged file).
#define FLUXO_AUDIO_RESYNC (AV_TIME_BASE / 5)
// Two key times this close are one (index and picture times are rescaled from the same time base).
#define FLUXO_KEY_EPSILON 1000
// Consecutive frames the video encoder may refuse before it is opened again (VideoToolbox invalidates its
// sessions when the app moves between the foreground and the background).
#define FLUXO_ENCODER_RETRIES 3
// A file conversion (FluxoStreamsOptions.complete) tries this many times, this far apart, to open a video encoder
// that is refused before it gives up (it then runs again later).
#define FLUXO_ENCODER_WAITS 20
#define FLUXO_ENCODER_WAIT_US 250000
// Back-pressure of the video encoder. FFmpeg's VideoToolbox encoder gives back at most one packet for each picture it is
// sent and keeps the rest (and the pictures it has not encoded yet) until it is flushed: whenever the encoder is a
// little behind, the difference between pictures sent and packets received can only grow, and nothing else stops the
// reader from running ahead of the encoder (a movie is converted at full speed: the 60 s read-ahead of playback, or a
// whole download). So the encoder is flushed (which waits for VideoToolbox to finish every picture) and opened again:
// at a key frame the converter places anyway (a segment start) when more than FLUXO_ENCODER_DRAIN_AT_KEY pictures are
// in flight, or at once, with a key frame of its own, at FLUXO_ENCODER_MAX_IN_FLIGHT. Both are above what an encoder
// holds when it keeps up, its pipeline, so they cost nothing then: 1080p MPEG-2 converted at full speed had at most 12
// in flight with the hardware encoder of an M4 Mac, 17 with VideoToolbox's software encoder on the Mac and in the iOS
// Simulator.
// (The smoke tests can set others to measure, e.g. -DFLUXO_ENCODER_MAX_IN_FLIGHT=100000 for no bound.)
#ifndef FLUXO_ENCODER_DRAIN_AT_KEY
#define FLUXO_ENCODER_DRAIN_AT_KEY 24
#endif
#ifndef FLUXO_ENCODER_MAX_IN_FLIGHT
#define FLUXO_ENCODER_MAX_IN_FLIGHT 48
#endif
// Encoder statistics on stderr when FLUXO_ENCODER_TRACE is set (smoke test builds, -DFLUXO_ENGINE_TRACE).
#ifdef FLUXO_ENGINE_TRACE
#define FLUXO_ENCODER_TRACE(...) do { if (getenv("FLUXO_ENCODER_TRACE") != NULL) { fprintf(stderr, "[encoder] " __VA_ARGS__); fputc('\n', stderr); } } while (0)
#else
#define FLUXO_ENCODER_TRACE(...) do { } while (0)
#endif
// A picture whose time is this far behind the previous one's is a timestamp restart (a live source that starts
// its clock again, a restreamer that switches source, a spliced programme), not reordering jitter.
#define FLUXO_VIDEO_RESYNC (AV_TIME_BASE / 10)

typedef enum FluxoAction {
    FluxoActionCopy = 0,
    FluxoActionConvert = 1,
    FluxoActionDrop = 2,
} FluxoAction;

// Packets produced by a converter, waiting to be read.
typedef struct FluxoPacketQueue {
    AVPacket **items;
    int head;
    int count;
    int capacity;
} FluxoPacketQueue;

struct FluxoTranscoder {
    enum AVMediaType type;
    // Time base of the input stream: converted packets use it too.
    AVRational time_base;
    FluxoStreamsOptions options;
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    // The encoder received something since it was opened (a reset must open a fresh one).
    int encoder_used;
    // Codec parameters of the converted stream.
    AVCodecParameters *parameters;
    AVFrame *frame;
    AVFrame *converted;
    AVFrame *software;
    AVPacket *encoded;
    FluxoPacketQueue queue;

    // Video.
    AVBufferRef *hw_device;
    // Pixel aspect ratio of the picture (anamorphic DVD and DVB video), and the filter that writes it into the H.264
    // stream: VideoToolbox gives it to the format description only, which MPEG-TS segments do not carry.
    AVRational aspect;
    AVBSFContext *aspect_filter;
    struct SwsContext *scaler;
    enum AVPixelFormat encoder_format;
    int width;
    int height;
    AVRational frame_rate;
    int64_t bit_rate;
    int64_t last_pts;
    const int64_t *key_times;
    int key_count;
    // Next key time to place (-1: to be found from the next picture's time).
    int key_cursor;
    int64_t key_interval;
    int64_t last_key_time;
    int encoder_failures;
    // Pictures sent to the current video encoder and packets received from it (see FLUXO_ENCODER_MAX_IN_FLIGHT), the
    // most in flight so far, and the flushes made for the bound.
    int64_t frames_in;
    int64_t packets_out;
    int64_t most_in_flight;
    int64_t drains;
    // Input time (AV_TIME_BASE units) of the latest picture: the test refusals of FLUXO_TEST_REFUSE_ENCODER apply
    // to opening an encoder too, at that time (0 before the first picture).
    int64_t clock;
    uint8_t *line;
    size_t line_size;

    // Audio.
    // Output sample rate and channel layout (the encoder is opened again with them after a reset).
    int audio_rate;
    AVChannelLayout audio_layout;
    struct SwrContext *resampler;
    AVChannelLayout resampler_layout;
    enum AVSampleFormat resampler_format;
    int resampler_rate;
    AVAudioFifo *fifo;
    uint8_t **samples;
    int samples_capacity;
    // Time of the first sample in the FIFO, in 1 / sample rate units; AV_NOPTS_VALUE until the first frame.
    int64_t next_pts;
};

// MARK: - Functions shared by the converter's files

// Not exported from the binary that links the engine.
#pragma GCC visibility push(hidden)

// FluxoTranscoder.c
int fluxo_test_refused(int64_t time);
int fluxo_drain_encoder(FluxoTranscoder *t, AVRational from);

// FluxoTranscoderVideo.c
int fluxo_video_open_encoder(FluxoTranscoder *t);
int fluxo_video_open(FluxoTranscoder *t, AVFormatContext *input, AVStream *stream);
int fluxo_video_encode(FluxoTranscoder *t, AVFrame *frame);

// FluxoTranscoderAudio.c
int fluxo_audio_open_encoder(FluxoTranscoder *t, int sample_rate, const AVChannelLayout *layout);
int fluxo_audio_open(FluxoTranscoder *t, AVStream *stream);
int fluxo_audio_push(FluxoTranscoder *t, AVFrame *frame);
int fluxo_audio_finish(FluxoTranscoder *t);

#pragma GCC visibility pop

#endif /* FLUXO_TRANSCODER_INTERNAL_H */
