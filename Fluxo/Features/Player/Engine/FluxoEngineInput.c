//
//  FluxoEngineInput.c
//  Fluxo
//
//  Opening and closing the input: FFmpeg's demuxers, and the AVIOContext of on-demand HTTP files that
//  seeks with a single connection.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"

// MARK: - Input

// MARK: Input of on-demand HTTP files
//
// FFmpeg's HTTP protocol seeks by opening a connection at the new position before it closes the current one
// (it continues on the old one if the new one fails). IPTV panels often allow a single connection per account
// and refuse the second one, so every seek in a movie failed there. On-demand HTTP inputs are therefore read
// through this AVIOContext: a seek closes the connection first, then opens one at the position (with a Range
// request; only for servers that announced byte ranges), and short forward seeks read on.
typedef struct FluxoInputIO {
    FluxoRemuxSession *session;
    AVIOContext *inner;
    // Protocol options of every connection (timeouts, reconnection, user agent).
    AVDictionary *options;
    int64_t position;
    int64_t size;
    int seekable;
} FluxoInputIO;

static int fluxo_input_io_connect(FluxoInputIO *io, int64_t offset) {
    AVDictionary *options = NULL;
    av_dict_copy(&options, io->options, 0);
    if (offset > 0) {
        char value[32];
        snprintf(value, sizeof(value), "%lld", (long long)offset);
        av_dict_set(&options, "offset", value, 0);
    }
    AVIOInterruptCB interrupt = { fluxo_interrupt_callback, io->session };
    int ret = avio_open2(&io->inner, io->session->input_url, AVIO_FLAG_READ, &interrupt, &options);
    av_dict_free(&options);
    if (ret < 0) {
        return ret;
    }
    io->position = offset;
    return 0;
}

static int fluxo_input_io_read(void *opaque, uint8_t *buffer, int size) {
    FluxoInputIO *io = opaque;
    if (io->inner == NULL) {
        // After a seek past the end (the AVI demuxer looks for another RIFF chunk there): the end, not a failure.
        return io->size > 0 && io->position >= io->size ? AVERROR_EOF : AVERROR(EIO);
    }
    int ret = avio_read_partial(io->inner, buffer, size);
    if (ret == 0) {
        return avio_feof(io->inner) ? AVERROR_EOF : AVERROR(EAGAIN);
    }
    if (ret > 0) {
        io->position += ret;
    }
    return ret;
}

static int64_t fluxo_input_io_seek(void *opaque, int64_t offset, int whence) {
    FluxoInputIO *io = opaque;
    if (whence & AVSEEK_SIZE) {
        return io->size > 0 ? io->size : AVERROR(ENOSYS);
    }
    whence &= ~AVSEEK_FORCE;
    int64_t target;
    if (whence == SEEK_SET) {
        target = offset;
    } else if (whence == SEEK_CUR) {
        target = io->position + offset;
    } else if (whence == SEEK_END && io->size > 0) {
        target = io->size + offset;
    } else {
        return AVERROR(ENOSYS);
    }
    if (target < 0) {
        return AVERROR(EINVAL);
    }
    if (target == io->position && io->inner != NULL) {
        return target;
    }
    if (!io->seekable) {
        return AVERROR(ENOSYS);
    }
    if (io->size > 0 && target >= io->size) {
        // Past the end: nothing to read there, no connection needed.
        avio_closep(&io->inner);
        io->position = target;
        return target;
    }
    if (io->inner != NULL && target > io->position && target - io->position <= FLUXO_INPUT_IO_READ_ON) {
        uint8_t discard[4096];
        while (io->position < target) {
            int count = (int)(target - io->position < (int64_t)sizeof(discard) ? target - io->position : (int64_t)sizeof(discard));
            int ret = avio_read(io->inner, discard, count);
            if (ret <= 0) {
                break;
            }
            io->position += ret;
        }
        if (io->position == target) {
            return target;
        }
    }
    // The current connection closes before the next one opens. A server limited to one connection notices that
    // only a moment later (at its next write) and refuses the new one meanwhile: retried for about 4 s.
    avio_closep(&io->inner);
    int ret = fluxo_input_io_connect(io, target);
    for (int64_t delay = AV_TIME_BASE / 4; ret < 0 && fluxo_is_busy_server_error(ret) && delay <= 2 * AV_TIME_BASE && !fluxo_is_cancelled(io->session); delay *= 2) {
        fluxo_wait(io->session, delay);
        ret = fluxo_input_io_connect(io, target);
    }
    return ret < 0 ? ret : target;
}

static void fluxo_input_io_free(FluxoInputIO **pointer) {
    FluxoInputIO *io = *pointer;
    if (io == NULL) {
        return;
    }
    avio_closep(&io->inner);
    av_dict_free(&io->options);
    av_free(io);
    *pointer = NULL;
}

// Opens the first connection of an on-demand HTTP input and the AVIOContext the demuxer reads. `options` are the
// protocol options; the context goes to `pb`.
static int fluxo_input_io_open(FluxoRemuxSession *session, const AVDictionary *options, AVIOContext **pb, FluxoInputIO **result) {
    FluxoInputIO *io = av_mallocz(sizeof(FluxoInputIO));
    if (io == NULL) {
        return AVERROR(ENOMEM);
    }
    io->session = session;
    av_dict_copy(&io->options, options, 0);
    int ret = fluxo_input_io_connect(io, 0);
    if (ret < 0) {
        fluxo_input_io_free(&io);
        return ret;
    }
    io->size = avio_size(io->inner);
    io->seekable = (io->inner->seekable & AVIO_SEEKABLE_NORMAL) != 0;
    uint8_t *buffer = av_malloc(FLUXO_INPUT_IO_BUFFER);
    AVIOContext *context = buffer != NULL ? avio_alloc_context(buffer, FLUXO_INPUT_IO_BUFFER, 0, io, fluxo_input_io_read, NULL, fluxo_input_io_seek) : NULL;
    if (context == NULL) {
        av_free(buffer);
        fluxo_input_io_free(&io);
        return AVERROR(ENOMEM);
    }
    context->seekable = io->seekable ? AVIO_SEEKABLE_NORMAL : 0;
    *pb = context;
    *result = io;
    return 0;
}

static void fluxo_input_io_close(AVIOContext **pb, FluxoInputIO **io) {
    if (*pb != NULL) {
        av_freep(&(*pb)->buffer);
        avio_context_free(pb);
    }
    fluxo_input_io_free(io);
}

static int fluxo_is_http_url(const char *url) {
    return url != NULL && (strncmp(url, "http://", 7) == 0 || strncmp(url, "https://", 8) == 0);
}

// After a quick first open (FluxoRemuxConfig.quick_open): FFmpeg's HTTP layer reconnects on network errors inside
// the open connection again, and so do the later connections of an on-demand input, as without quick_open.
// An HLS input opened by FFmpeg's own hls demuxer is not affected either way: it opens its playlist reloads and
// segments with the options ffio_copy_url_options copies (headers, user agent, cookies, proxy, referer, rw_timeout,
// icy; FFmpeg 9.0.2), never the reconnect ones, so its segments never had them, with or without quick_open.
static void fluxo_enable_network_reconnect(FluxoRemuxSession *session) {
    if (session->input_io != NULL) {
        av_dict_set(&session->input_io->options, "reconnect_on_network_error", "1", 0);
        if (session->input_io->inner != NULL) {
            av_opt_set(session->input_io->inner, "reconnect_on_network_error", "1", AV_OPT_SEARCH_CHILDREN);
        }
    } else if (session->input != NULL && session->input->pb != NULL) {
        // The AVIOContext of the http protocol; its child is the protocol's context, which has the option.
        av_opt_set(session->input->pb, "reconnect_on_network_error", "1", AV_OPT_SEARCH_CHILDREN);
    }
}

int fluxo_open_input(FluxoRemuxSession *session) {
    AVFormatContext *input = avformat_alloc_context();
    if (input == NULL) {
        return AVERROR(ENOMEM);
    }
    input->interrupt_callback.callback = fluxo_interrupt_callback;
    input->interrupt_callback.opaque = session;

    char timeout[32];
    snprintf(timeout, sizeof(timeout), "%lld", (long long)session->io_timeout_us);

    AVDictionary *options = NULL;
    av_dict_set(&options, "rw_timeout", timeout, 0);
    // HTTP specific options; ignored by other protocols. They cover short drops inside a connection,
    // longer outages are handled by the reconnection loop of the engine.
    av_dict_set(&options, "reconnect", "1", 0);
    if (session->is_live) {
        // A live stream has no position: after a drop it simply continues. A file served without byte
        // ranges would restart from its first byte instead (corrupting the demuxer's view of it), so
        // on-demand inputs are reopened by the engine itself (fluxo_vod_recover).
        av_dict_set(&options, "reconnect_streamed", "1", 0);
    }
    // Not during a quick first open (FluxoRemuxConfig.quick_open): the engine's attempts are the retries there, and
    // the option is turned on once the input is open (fluxo_enable_network_reconnect).
    int quick = session->quick_open && session->is_first_open;
    av_dict_set(&options, "reconnect_on_network_error", quick ? "0" : "1", 0);
    av_dict_set(&options, "reconnect_delay_max", "4", 0);
    if (session->user_agent != NULL) {
        av_dict_set(&options, "user_agent", session->user_agent, 0);
    }

    AVIOContext *pb = NULL;
    FluxoInputIO *io = NULL;
    if (!session->is_live && fluxo_is_http_url(session->input_url)) {
        int ret = fluxo_input_io_open(session, options, &pb, &io);
        if (ret < 0) {
            av_dict_free(&options);
            avformat_free_context(input);
            return ret;
        }
        input->pb = pb;
        input->flags |= AVFMT_FLAG_CUSTOM_IO;
        // The protocol options went to the connections.
        av_dict_free(&options);
    }
    // Keep the start-up latency low: live inputs rarely need more than 3 seconds of probing.
    av_dict_set(&options, "analyzeduration", "3000000", 0);

    int ret = avformat_open_input(&input, session->input_url, NULL, &options);
    av_dict_free(&options);
    if (ret < 0) {
        // avformat_open_input frees the context on failure (not a custom AVIOContext).
        fluxo_input_io_close(&pb, &io);
        return ret;
    }
    session->input = input;
    session->input_io = io;
    if (quick) {
        fluxo_enable_network_reconnect(session);
    }

    ret = avformat_find_stream_info(input, NULL);
    if (ret < 0) {
        fluxo_close_input(session);
        return ret;
    }
    // Streams AVPlayer cannot decode are converted as they are read (FluxoTranscoder.c).
    FluxoStreamsOptions streams_options = {
        .is_live = session->is_live,
        .global_header = 0,
        .key_interval = session->hls.segment_duration,
    };
    ret = fluxo_streams_open(&session->streams, input, &streams_options);
    if (ret < 0) {
        fluxo_close_input(session);
        return ret;
    }
    if (session->plan.starts != NULL) {
        // Reopened on demand: converted video starts its segments with key frames again.
        fluxo_streams_set_key_times(&session->streams, session->plan.starts, session->plan.count);
    }
    return 0;
}

// Errors of a server that may accept the connection a moment later, when an on-demand input connects again for a
// seek (fluxo_input_io_seek; the first open has fluxo_first_open_retries): refused for the number of connections of
// the account (403, 429 and other 4xx IPTV panels use, 5xx), or a connection refused, reset or closed (EIO) while the
// server still holds the previous one. Each costs little to try again. Not a missing stream (404) or bad credentials
// (401), and not a connection that timed out: it has already waited FFmpeg's 5 s to connect, so four more attempts
// would keep a seek of a server that went away waiting for half a minute.
int fluxo_is_busy_server_error(int error) {
    return error == AVERROR_HTTP_FORBIDDEN || error == AVERROR_HTTP_TOO_MANY_REQUESTS || error == AVERROR_HTTP_OTHER_4XX ||
           error == AVERROR_HTTP_SERVER_ERROR || error == AVERROR(ECONNRESET) || error == AVERROR(ECONNREFUSED) ||
           error == AVERROR(EIO);
}

// How often the engine opens the input again after the first open failed with `error` (FFmpeg's own retries are off
// then with FluxoRemuxConfig.quick_open, so these are the only ones; a dead channel fails in about 0.5 s, a refusing
// account in about 4 s):
// - a server refusing the connection for the number of connections of the account (403, 429, other 4xx IPTV panels
//   use, 5xx), until it notices the previous one closed (the channel played before, or AVPlayer's own connections to
//   a movie the engine takes over): 3 times, over 3.5 s;
// - a refused or reset TCP connection, or a failed name lookup (EIO): once, 0.5 s later (IPTV servers often refuse
//   the very first connection of a burst);
// - nothing else: a connection that timed out has already waited (5 s to connect, FFmpeg's TCP default), a missing
//   stream (404), bad credentials (401), a missing protocol (srt://, which needs libsrt) or a format that cannot be
//   played do not change a moment later.
int fluxo_first_open_retries(int error) {
    if (error == AVERROR_HTTP_FORBIDDEN || error == AVERROR_HTTP_TOO_MANY_REQUESTS || error == AVERROR_HTTP_OTHER_4XX ||
        error == AVERROR_HTTP_SERVER_ERROR) {
        return 3;
    }
    if (error == AVERROR(ECONNREFUSED) || error == AVERROR(ECONNRESET) || error == AVERROR(EIO)) {
        return 1;
    }
    return 0;
}

// True when the input has a known size and everything up to it was read. Live inputs have no
// size (or an unreachable placeholder size), so an EOF there means the connection was lost.
int fluxo_input_reached_end_of_file(FluxoRemuxSession *session) {
    if (session->input == NULL || session->input->pb == NULL) {
        return 0;
    }
    int64_t size = avio_size(session->input->pb);
    return size > 0 && avio_tell(session->input->pb) >= size;
}

void fluxo_close_input(FluxoRemuxSession *session) {
    AVIOContext *pb = session->input != NULL && session->input_io != NULL ? session->input->pb : NULL;
    fluxo_streams_close(&session->streams);
    if (session->input != NULL) {
        avformat_close_input(&session->input);
    }
    // A custom AVIOContext is not closed by avformat_close_input.
    fluxo_input_io_close(&pb, &session->input_io);
}
