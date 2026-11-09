//
//  FluxoEngineInput.c
//  Fluxo
//
//  Opening and closing the input: FFmpeg's demuxers, and the AVIOContext of HTTP inputs, which reads through the URL
//  loading system (FluxoEngineHTTP.h) or FFmpeg's http protocol and seeks on-demand files with a single connection.
//
//  Part of the remux engine (FluxoRemuxEngine.c), see FluxoEngineInternal.h.
//

#include "FluxoEngineInternal.h"
#include "FluxoEngineHTTP.h"

#include <stddef.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavutil/aes.h>
#pragma clang diagnostic pop

// MARK: - Input

// MARK: The AVIOContext of HTTP inputs
//
// http:// and https:// inputs are read through the URL loading system (FluxoRemuxHTTPInputSystem, the default): live
// ones, on-demand ones, and the requests the HLS demuxer makes for an HLS input (fluxo_io_open). With FFmpeg's http
// protocol (FluxoRemuxHTTPInputLibavformat, or once the URL loading system could not talk to the server), on-demand inputs
// are still read through this AVIOContext, and live ones by FFmpeg's demuxers directly, as before.
//
// Seeks: FFmpeg's HTTP protocol seeks by opening a connection at the new position before it closes the current one (it
// continues on the old one if the new one fails). IPTV panels often allow a single connection per account and refuse
// the second one, so every seek in a movie failed there. Here a seek closes the connection first, then opens one at the
// position (with a Range request; only for servers that announced byte ranges), and short forward seeks read on.
typedef struct FluxoInputIO {
    // First member: the class of the options below, which av_opt_get finds through the AVIOContext (its child, see
    // fluxo_input_avio_class) as it finds the same options of FFmpeg's http protocol: the format probe reads the MIME
    // type (an HLS playlist behind an address without .m3u8 is recognised by it), the HLS demuxer the address after
    // redirections (the base of the relative addresses of the segments), and the protocol options it gives every request
    // it leaves to FFmpeg (ffio_copy_url_options: the timeout and the user agent; see fluxo_io_open). With FFmpeg's http
    // protocol (`inner`), that context is the child of this one, and its own options come first (cookies included).
    const AVClass *av_class;
    char *mime_type;
    char *location;
    char *rw_timeout;
    char *user_agent;

    FluxoRemuxSession *session;
    char *url;
    // Read through the URL loading system (`connection`), or with FFmpeg's http protocol (`inner`, opened with the
    // protocol options `options`: timeouts, reconnection, user agent).
    int system;
    FluxoHTTPConnection *connection;
    AVIOContext *inner;
    AVDictionary *options;
    // URL loading system: a connection that drops is made again within the context, as FFmpeg's http protocol does with
    // `reconnect` (after 0, 1 and 3 s, FLUXO_HTTP_RECONNECT_DELAY_MAX): a live input (`live`) from where its server is
    // now, an on-demand one at the position when its server has byte ranges (one without them is reopened by the engine,
    // fluxo_vod_recover). Not the HLS demuxer's requests: FFmpeg never reconnected those (see
    // fluxo_enable_network_reconnect).
    int reconnect;
    int live;
    // The response is a playlist (it starts with #EXTM3U: an HLS input's main playlist), whose end is its end.
    int playlist;
    // Position in the resource, its size (-1 when unknown), the end of the byte range asked for (0: the end of the
    // resource), and whether the server has byte ranges.
    int64_t position;
    int64_t size;
    int64_t end_offset;
    int seekable;
    // An AES-128 HLS segment ("crypto+https://…", see fluxo_io_open), decrypted as FFmpeg's crypto protocol does it:
    // AES-128-CBC from `aes_iv`, PKCS#7 padding removed at the end. The buffer holds bytes read: the decrypted ones from
    // `crypt_ready` to `crypt_ready_end`, then the ones not decrypted yet up to `crypt_length` (the last whole block
    // waits for the end, whose padding it may hold).
    struct AVAES *aes;
    uint8_t aes_iv[16];
    uint8_t *crypt_buffer;
    int crypt_ready;
    int crypt_ready_end;
    int crypt_length;
    int crypt_eof;
} FluxoInputIO;

#define FLUXO_AES_BLOCK 16
#define FLUXO_CRYPT_BUFFER (64 * 1024)

static const AVOption fluxo_input_io_options[] = {
    { .name = "mime_type", .help = "the Content-Type of the response", .offset = offsetof(FluxoInputIO, mime_type),
      .type = AV_OPT_TYPE_STRING, .flags = AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY },
    { .name = "location", .help = "the address the data come from, after redirections", .offset = offsetof(FluxoInputIO, location),
      .type = AV_OPT_TYPE_STRING, .flags = AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY },
    { .name = "rw_timeout", .help = "the engine's timeout of network reads (microseconds)", .offset = offsetof(FluxoInputIO, rw_timeout),
      .type = AV_OPT_TYPE_STRING, .flags = AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY },
    { .name = "user_agent", .help = "the engine's User-Agent", .offset = offsetof(FluxoInputIO, user_agent),
      .type = AV_OPT_TYPE_STRING, .flags = AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY },
    { .name = NULL },
};

// The child of a FluxoInputIO read with FFmpeg's http protocol: that AVIOContext (whose child is the protocol's context).
static void *fluxo_input_io_child_next(void *object, void *previous) {
    FluxoInputIO *io = object;
    return previous == NULL ? io->inner : NULL;
}

static const AVClass fluxo_input_io_class = {
    .class_name = "FluxoInputIO",
    .item_name = av_default_item_name,
    .option = fluxo_input_io_options,
    .version = LIBAVUTIL_VERSION_INT,
    .child_next = fluxo_input_io_child_next,
};

// The AVIOContext's only child is its FluxoInputIO (its opaque), as an AVIOContext of FFmpeg's has its URLContext.
static void *fluxo_input_avio_child_next(void *object, void *previous) {
    AVIOContext *context = object;
    return previous == NULL ? context->opaque : NULL;
}

static const AVClass *fluxo_input_avio_child_class_iterate(void **iterator) {
    const AVClass *child = *iterator == NULL ? &fluxo_input_io_class : NULL;
    *iterator = (void *)&fluxo_input_io_class;
    return child;
}

static const AVClass fluxo_input_avio_class = {
    .class_name = "AVIOContext",
    .item_name = av_default_item_name,
    .version = LIBAVUTIL_VERSION_INT,
    .child_next = fluxo_input_avio_child_next,
    .child_class_iterate = fluxo_input_avio_child_class_iterate,
};

static int fluxo_input_io_connected(const FluxoInputIO *io) {
    return io->connection != NULL || io->inner != NULL;
}

static void fluxo_input_io_disconnect(FluxoInputIO *io) {
    fluxo_http_close(&io->connection);
    avio_closep(&io->inner);
}

static void fluxo_input_io_set_string(char **field, const char *value) {
    av_freep(field);
    if (value != NULL && value[0] != '\0') {
        *field = av_strdup(value);
    }
}

// The end of what a connection gives: the end of the byte range asked for, or of the resource (-1 when unknown).
static int64_t fluxo_input_io_end(const FluxoInputIO *io) {
    if (io->end_offset > 0) {
        return io->size > 0 && io->size < io->end_offset ? io->size : io->end_offset;
    }
    return io->size;
}

// The session's client of the URL loading system (its cookies and connections), made at its first connection.
static int fluxo_session_http_client(FluxoRemuxSession *session) {
    return session->http_client != NULL ? 0 : fluxo_http_client_create(&session->http_client);
}

static int fluxo_input_io_connect(FluxoInputIO *io, int64_t offset) {
    if (io->system) {
        int ret = fluxo_session_http_client(io->session);
        if (ret < 0) {
            return ret;
        }
        FluxoHTTPRequest request = {
            .client = io->session->http_client,
            .url = io->url,
            .user_agent = io->session->user_agent,
            .offset = offset,
            .end_offset = io->end_offset,
            .timeout_us = io->session->io_timeout_us,
            .interrupt = { fluxo_interrupt_callback, io->session },
        };
        FluxoHTTPConnection *connection = NULL;
        ret = fluxo_http_open(&request, &connection);
        if (ret < 0) {
            return ret;
        }
        if (fluxo_http_start(connection) != offset) {
            // A server that ignored the byte range sends the resource from its start: this connection is not at the position.
            FLUXO_TRACE("byte range at %lld ignored (HTTP %d)", (long long)offset, fluxo_http_status(connection));
            fluxo_http_close(&connection);
            return AVERROR(ESPIPE);
        }
        io->connection = connection;
        fluxo_input_io_set_string(&io->mime_type, fluxo_http_mime_type(connection));
        fluxo_input_io_set_string(&io->location, fluxo_http_location(connection));
    } else {
        AVDictionary *options = NULL;
        av_dict_copy(&options, io->options, 0);
        if (offset > 0) {
            char value[32];
            snprintf(value, sizeof(value), "%lld", (long long)offset);
            av_dict_set(&options, "offset", value, 0);
        }
        AVIOInterruptCB interrupt = { fluxo_interrupt_callback, io->session };
        int ret = avio_open2(&io->inner, io->url, AVIO_FLAG_READ, &interrupt, &options);
        av_dict_free(&options);
        if (ret < 0) {
            return ret;
        }
        uint8_t *value = NULL;
        if (av_opt_get(io->inner, "mime_type", AV_OPT_SEARCH_CHILDREN, &value) >= 0) {
            fluxo_input_io_set_string(&io->mime_type, (const char *)value);
        }
        av_freep(&value);
        if (av_opt_get(io->inner, "location", AV_OPT_SEARCH_CHILDREN, &value) >= 0) {
            fluxo_input_io_set_string(&io->location, (const char *)value);
        }
        av_freep(&value);
    }
    if (io->location == NULL) {
        fluxo_input_io_set_string(&io->location, io->url);
    }
    io->position = offset;
    return 0;
}

// One read of the URL loading system's connection. An end before the end of the response's range is a dropped
// connection (FFmpeg's http protocol: "Stream ends prematurely", EIO), and so is the end of a live stream of no known
// length: FFmpeg's http protocol takes it for one too (the end is before the unknown size; the URL loading system does
// not tell a chunked response its server stopped sending from a finished one) and connects again within the input, so
// a server that restarts within seconds is not a reconnection of the engine. Not a playlist's end: that is the end.
static int fluxo_input_io_read_connection(FluxoInputIO *io, uint8_t *buffer, int size) {
    int ret = fluxo_http_read(io->connection, buffer, size);
    if (ret > 0 && io->position == 0 && ret >= 7 && memcmp(buffer, "#EXTM3U", 7) == 0) {
        io->playlist = 1;
    }
    if (ret == AVERROR_EOF) {
        int64_t end = fluxo_input_io_end(io);
        if ((end > 0 && io->position < end) || (io->live && end <= 0 && !io->playlist)) {
            return AVERROR(EIO);
        }
    }
    return ret;
}

static int fluxo_input_io_read_plain(FluxoInputIO *io, uint8_t *buffer, int size) {
    if (!fluxo_input_io_connected(io)) {
        // After a seek past the end (the AVI demuxer looks for another RIFF chunk there): the end, not a failure.
        int64_t end = fluxo_input_io_end(io);
        return end > 0 && io->position >= end ? AVERROR_EOF : AVERROR(EIO);
    }
    int ret;
    if (io->inner != NULL) {
        ret = avio_read_partial(io->inner, buffer, size);
        if (ret == 0) {
            return avio_feof(io->inner) ? AVERROR_EOF : AVERROR(EAGAIN);
        }
    } else {
        ret = fluxo_input_io_read_connection(io, buffer, size);
        int reconnects = io->reconnect && (io->live || io->seekable);
        for (int delay = 0; reconnects && ret < 0 && ret != AVERROR_EOF && ret != AVERROR_EXIT && ret != AVERROR(ESPIPE) &&
                            delay <= FLUXO_HTTP_RECONNECT_DELAY_MAX && !fluxo_is_cancelled(io->session);
             delay = 2 * delay + 1) {
            FLUXO_TRACE("connection dropped at %lld (%d): connecting again in %d s", (long long)io->position, ret, delay);
            fluxo_http_close(&io->connection);
            fluxo_wait(io->session, (int64_t)delay * AV_TIME_BASE);
            if (fluxo_is_cancelled(io->session)) {
                ret = AVERROR_EXIT;
                break;
            }
            // A live input continues from where its server is now; an on-demand one at the position.
            int connected = fluxo_input_io_connect(io, io->live ? 0 : io->position);
            ret = connected < 0 ? connected : fluxo_input_io_read_connection(io, buffer, size);
        }
    }
    if (ret > 0) {
        io->position += ret;
    }
    return ret;
}

// An AES-128 segment: as FFmpeg's crypto protocol (crypto_read), except that a failed read of the connection is that
// failure (crypto_read takes it for the end, and would take what came for the whole segment).
static int fluxo_input_io_read_decrypted(FluxoInputIO *io, uint8_t *buffer, int size) {
    for (;;) {
        if (io->crypt_ready < io->crypt_ready_end) {
            int count = FFMIN(size, io->crypt_ready_end - io->crypt_ready);
            memcpy(buffer, io->crypt_buffer + io->crypt_ready, count);
            io->crypt_ready += count;
            return count;
        }
        // Everything decrypted was read: what was not decrypted yet goes to the start of the buffer.
        int pending = io->crypt_length - io->crypt_ready_end;
        memmove(io->crypt_buffer, io->crypt_buffer + io->crypt_ready_end, pending);
        io->crypt_length = pending;
        io->crypt_ready = io->crypt_ready_end = 0;
        if (io->crypt_eof) {
            // (A last block cut short is not decrypted, as in crypto_read.)
            return AVERROR_EOF;
        }
        // At least two blocks, or the end: the last one is kept until the end is known.
        do {
            int ret = fluxo_input_io_read_plain(io, io->crypt_buffer + io->crypt_length, FLUXO_CRYPT_BUFFER - io->crypt_length);
            if (ret == AVERROR_EOF) {
                io->crypt_eof = 1;
                break;
            }
            if (ret < 0) {
                return ret;
            }
            io->crypt_length += ret;
        } while (io->crypt_length < 2 * FLUXO_AES_BLOCK);
        int blocks = io->crypt_length / FLUXO_AES_BLOCK - (io->crypt_eof ? 0 : 1);
        if (blocks <= 0) {
            continue;
        }
        av_aes_crypt(io->aes, io->crypt_buffer, io->crypt_buffer, blocks, io->aes_iv, 1);
        io->crypt_ready_end = blocks * FLUXO_AES_BLOCK;
        if (io->crypt_eof) {
            // PKCS#7: the last byte is the length of the padding (only when it is one; FFmpeg takes it as it is).
            int padding = io->crypt_buffer[io->crypt_ready_end - 1];
            if (padding >= 1 && padding <= FLUXO_AES_BLOCK) {
                io->crypt_ready_end -= padding;
            }
        }
    }
}

static int fluxo_input_io_read(void *opaque, uint8_t *buffer, int size) {
    FluxoInputIO *io = opaque;
    return io->aes != NULL ? fluxo_input_io_read_decrypted(io, buffer, size) : fluxo_input_io_read_plain(io, buffer, size);
}

// Reads and drops `count` bytes on the current connection (a short forward seek). Returns 0 once done.
static int fluxo_input_io_skip(FluxoInputIO *io, int64_t count) {
    uint8_t discard[4096];
    while (count > 0) {
        int chunk = (int)(count < (int64_t)sizeof(discard) ? count : (int64_t)sizeof(discard));
        int ret = io->inner != NULL ? avio_read(io->inner, discard, chunk) : fluxo_http_read(io->connection, discard, chunk);
        if (ret <= 0) {
            return ret < 0 ? ret : AVERROR_EOF;
        }
        io->position += ret;
        count -= ret;
    }
    return 0;
}

static int64_t fluxo_input_io_seek(void *opaque, int64_t offset, int whence) {
    FluxoInputIO *io = opaque;
    if (whence & AVSEEK_SIZE) {
        // (Of an AES-128 segment: the encrypted size, as FFmpeg's crypto protocol answers.)
        return io->size > 0 ? io->size : AVERROR(ENOSYS);
    }
    if (io->aes != NULL) {
        // A segment is read from its start to its end (the HLS demuxer never seeks one read over HTTP).
        return AVERROR(ENOSYS);
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
    if (target == io->position && fluxo_input_io_connected(io)) {
        return target;
    }
    if (!io->seekable) {
        return AVERROR(ENOSYS);
    }
    if (io->size > 0 && target >= io->size) {
        // Past the end: nothing to read there, no connection needed.
        fluxo_input_io_disconnect(io);
        io->position = target;
        return target;
    }
    if (fluxo_input_io_connected(io) && target > io->position && target - io->position <= FLUXO_INPUT_IO_READ_ON &&
        fluxo_input_io_skip(io, target - io->position) == 0) {
        return target;
    }
    // The current connection closes before the next one opens. A server limited to one connection notices that
    // only a moment later (at its next write) and refuses the new one meanwhile: retried for about 4 s.
    fluxo_input_io_disconnect(io);
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
    fluxo_input_io_disconnect(io);
    av_dict_free(&io->options);
    av_freep(&io->url);
    av_freep(&io->mime_type);
    av_freep(&io->location);
    av_freep(&io->rw_timeout);
    av_freep(&io->user_agent);
    av_freep(&io->aes);
    av_freep(&io->crypt_buffer);
    av_free(io);
    *pointer = NULL;
}

// Opens the first connection of an HTTP input at `offset` (up to `end_offset`, 0 for the end) and the AVIOContext that
// reads it (into `pb`). `system`: through the URL loading system, `live` and `reconnect` as in FluxoInputIO; otherwise
// with FFmpeg's http protocol and the protocol options `options`. `aes_key` and `aes_iv` (16 bytes each, or NULL): an
// AES-128 segment, read decrypted (through the URL loading system only).
static int fluxo_input_io_open(FluxoRemuxSession *session, const char *url, int system, int live, int reconnect, int64_t offset,
                               int64_t end_offset, const AVDictionary *options, const uint8_t *aes_key, const uint8_t *aes_iv,
                               AVIOContext **pb, FluxoInputIO **result) {
    FluxoInputIO *io = av_mallocz(sizeof(FluxoInputIO));
    if (io == NULL) {
        return AVERROR(ENOMEM);
    }
    io->av_class = &fluxo_input_io_class;
    io->session = session;
    io->url = av_strdup(url);
    io->system = system;
    io->live = live;
    io->reconnect = reconnect;
    io->end_offset = end_offset;
    io->size = -1;
    io->rw_timeout = av_asprintf("%lld", (long long)session->io_timeout_us);
    fluxo_input_io_set_string(&io->user_agent, session->user_agent);
    if (io->url == NULL || io->rw_timeout == NULL || (session->user_agent != NULL && session->user_agent[0] != '\0' && io->user_agent == NULL)) {
        fluxo_input_io_free(&io);
        return AVERROR(ENOMEM);
    }
    if (aes_key != NULL) {
        io->aes = av_aes_alloc();
        io->crypt_buffer = av_malloc(FLUXO_CRYPT_BUFFER);
        if (io->aes == NULL || io->crypt_buffer == NULL) {
            fluxo_input_io_free(&io);
            return AVERROR(ENOMEM);
        }
        av_aes_init(io->aes, aes_key, 128, 1);
        memcpy(io->aes_iv, aes_iv, sizeof(io->aes_iv));
    }
    av_dict_copy(&io->options, options, 0);
    int ret = fluxo_input_io_connect(io, offset);
    if (ret < 0) {
        fluxo_input_io_free(&io);
        return ret;
    }
    if (system) {
        io->size = fluxo_http_size(io->connection);
        // A live input is not seeked (its demuxer only goes back within what it read), nor an AES-128 segment.
        io->seekable = !live && io->aes == NULL && fluxo_http_seekable(io->connection);
    } else {
        io->size = avio_size(io->inner);
        io->seekable = (io->inner->seekable & AVIO_SEEKABLE_NORMAL) != 0;
    }
    uint8_t *buffer = av_malloc(FLUXO_INPUT_IO_BUFFER);
    AVIOContext *context = buffer != NULL ? avio_alloc_context(buffer, FLUXO_INPUT_IO_BUFFER, 0, io, fluxo_input_io_read, NULL, fluxo_input_io_seek) : NULL;
    if (context == NULL) {
        av_free(buffer);
        fluxo_input_io_free(&io);
        return AVERROR(ENOMEM);
    }
    context->av_class = &fluxo_input_avio_class;
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
    return url != NULL && (av_strncasecmp(url, "http://", 7) == 0 || av_strncasecmp(url, "https://", 8) == 0);
}

// The 16 bytes of a key or IV the HLS demuxer gives the crypto protocol (32 hexadecimal digits). 0, or -1.
static int fluxo_parse_aes_value(const AVDictionary *options, const char *name, uint8_t value[16]) {
    const AVDictionaryEntry *entry = av_dict_get(options, name, NULL, 0);
    if (entry == NULL || strlen(entry->value) != 32) {
        return -1;
    }
    for (int i = 0; i < 16; i++) {
        int byte = 0;
        for (int j = 0; j < 2; j++) {
            char c = entry->value[2 * i + j];
            int digit = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
            if (digit < 0) {
                return -1;
            }
            byte = byte * 16 + digit;
        }
        value[i] = (uint8_t)byte;
    }
    return 0;
}

// MARK: Requests of the demuxer
//
// The HLS demuxer requests its playlist again, the segments and the keys itself (AVFormatContext.io_open). When the
// input is read through the URL loading system, so are those (their byte ranges included, EXT-X-BYTERANGE), AES-128
// segments too ("crypto+https://…", decrypted by the engine as FFmpeg's crypto protocol does); a request the system
// cannot make (FLUXO_HTTP_ERROR_INCOMPATIBLE) and anything else (data:, crypto: without http) goes to FFmpeg's own
// io_open, with the session's timeout, user agent and cookies (the HLS demuxer gives its requests the options of the
// input's AVIOContext, which has no cookies here: they are the URL loading system's). Each is a connection of its own:
// the HLS demuxer's persistent connections need FFmpeg's http protocol (it turns them off itself with a custom io_open),
// and the URL loading system reuses connections anyway.

// The session of the input context (its interrupt callback's; the context's opaque is FluxoStreams').
static FluxoRemuxSession *fluxo_session_of(const AVFormatContext *context) {
    return context->interrupt_callback.opaque;
}

static int fluxo_io_open(AVFormatContext *context, AVIOContext **pb, const char *url, int flags, AVDictionary **options) {
    FluxoRemuxSession *session = fluxo_session_of(context);
    const char *address = url;
    uint8_t key[16];
    uint8_t iv[16];
    int encrypted = 0;
    if (url != NULL && av_strncasecmp(url, "crypto+", 7) == 0 && fluxo_is_http_url(url + 7)) {
        // An AES-128 segment: decrypted here, when the HLS demuxer gave the key and the IV as usual.
        encrypted = options != NULL && fluxo_parse_aes_value(*options, "key", key) == 0 && fluxo_parse_aes_value(*options, "iv", iv) == 0;
        if (encrypted) {
            address = url + 7;
        }
    }
    int system = !session->http_ffmpeg && (flags & AVIO_FLAG_WRITE) == 0 && fluxo_is_http_url(address);
#ifdef FLUXO_ENGINE_TESTING
    // Tools/EngineSmokeTest only: every request of the demuxer goes to FFmpeg (the options it then gets, see below).
    if (getenv("FLUXO_TEST_DEMUXER_REQUESTS") != NULL && strcmp(getenv("FLUXO_TEST_DEMUXER_REQUESTS"), "ffmpeg") == 0) {
        system = 0;
    }
#endif
    if (system) {
        int64_t offset = 0;
        int64_t end_offset = 0;
        const AVDictionaryEntry *entry = options != NULL ? av_dict_get(*options, "offset", NULL, 0) : NULL;
        if (entry != NULL) {
            offset = strtoll(entry->value, NULL, 10);
        }
        entry = options != NULL ? av_dict_get(*options, "end_offset", NULL, 0) : NULL;
        if (entry != NULL) {
            end_offset = strtoll(entry->value, NULL, 10);
        }
        FluxoInputIO *io = NULL;
        int ret = fluxo_input_io_open(session, address, 1, 0, 0, offset > 0 ? offset : 0, end_offset > 0 ? end_offset : 0, NULL,
                                      encrypted ? key : NULL, encrypted ? iv : NULL, pb, &io);
        if (ret != FLUXO_HTTP_ERROR_INCOMPATIBLE) {
            return ret;
        }
    }
    // FFmpeg's io_open: with the engine's timeout (without it a read of a server that stops sending would wait until the
    // session is cancelled) and user agent, when the demuxer has not given them (it gives what the input's AVIOContext
    // exports, see FluxoInputIO), and the cookies of the URL loading system for that address.
    if (options != NULL) {
        char timeout[32];
        snprintf(timeout, sizeof(timeout), "%lld", (long long)session->io_timeout_us);
        av_dict_set(options, "rw_timeout", timeout, AV_DICT_DONT_OVERWRITE);
        if (session->user_agent != NULL && session->user_agent[0] != '\0') {
            av_dict_set(options, "user_agent", session->user_agent, AV_DICT_DONT_OVERWRITE);
        }
        char *cookies = av_dict_get(*options, "cookies", NULL, 0) == NULL ? fluxo_http_client_cookies(session->http_client, address) : NULL;
        if (cookies != NULL) {
            av_dict_set(options, "cookies", cookies, AV_DICT_DONT_STRDUP_VAL);
        }
    }
    return session->default_io_open(context, pb, url, flags, options);
}

static int fluxo_io_close2(AVFormatContext *context, AVIOContext *pb) {
    if (pb != NULL && pb->read_packet == fluxo_input_io_read) {
        FluxoInputIO *io = pb->opaque;
        fluxo_input_io_close(&pb, &io);
        return 0;
    }
    return fluxo_session_of(context)->default_io_close2(context, pb);
}

// MARK: Opening the input

// After a quick first open (FluxoRemuxConfig.quick_open): FFmpeg's HTTP layer reconnects on network errors inside
// the open connection again, and so do the later connections of an on-demand input, as without quick_open.
// An HLS input opened by FFmpeg's own hls demuxer is not affected either way: it opens its playlist reloads and
// segments with the options ffio_copy_url_options copies (headers, user agent, cookies, proxy, referer, rw_timeout,
// icy; FFmpeg 9.0.2), never the reconnect ones, so its segments never had them, with or without quick_open.
// (Through the URL loading system an open makes one connection anyway, and a connection that drops later is made
// again within the input: nothing to change.)
static void fluxo_enable_network_reconnect(FluxoRemuxSession *session) {
    if (session->input_io != NULL) {
        if (session->input_io->system) {
            return;
        }
        av_dict_set(&session->input_io->options, "reconnect_on_network_error", "1", 0);
        if (session->input_io->inner != NULL) {
            av_opt_set(session->input_io->inner, "reconnect_on_network_error", "1", AV_OPT_SEARCH_CHILDREN);
        }
    } else if (session->input != NULL && session->input->pb != NULL) {
        // The AVIOContext of the http protocol; its child is the protocol's context, which has the option.
        av_opt_set(session->input->pb, "reconnect_on_network_error", "1", AV_OPT_SEARCH_CHILDREN);
    }
}

static int fluxo_open_input_attempt(FluxoRemuxSession *session) {
    AVFormatContext *input = avformat_alloc_context();
    if (input == NULL) {
        return AVERROR(ENOMEM);
    }
    input->interrupt_callback.callback = fluxo_interrupt_callback;
    input->interrupt_callback.opaque = session;

    char timeout[32];
    snprintf(timeout, sizeof(timeout), "%lld", (long long)session->io_timeout_us);

    // FFmpeg's protocol options (its http protocol's, for inputs it reads).
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
#ifdef FLUXO_ENGINE_TESTING
    // Tools/EngineSmokeTest only, never the app: FFmpeg's TLS checks the local test servers' certificates against their
    // authority (the URL loading system's side is in FluxoEngineHTTP.m).
    if (getenv("FLUXO_TEST_CA_FILE") != NULL) {
        av_dict_set(&options, "ca_file", getenv("FLUXO_TEST_CA_FILE"), 0);
        // Secure Transport's TLS reads that file through the file protocol, which a connection does not allow by default.
        av_dict_set(&options, "protocol_whitelist", "file,http,https,tls,tcp,crypto,data", 0);
    }
#endif

    AVIOContext *pb = NULL;
    FluxoInputIO *io = NULL;
    int http = fluxo_is_http_url(session->input_url);
    int system = http && !session->http_ffmpeg;
    if (system) {
        int ret = fluxo_input_io_open(session, session->input_url, 1, session->is_live, 1, 0, 0, NULL, NULL, NULL, &pb, &io);
        if (ret < 0) {
            av_dict_free(&options);
            avformat_free_context(input);
            return ret;
        }
    }
    if (!system && http && !session->is_live) {
        int ret = fluxo_input_io_open(session, session->input_url, 0, 0, 0, 0, 0, options, NULL, NULL, &pb, &io);
        if (ret < 0) {
            av_dict_free(&options);
            avformat_free_context(input);
            return ret;
        }
    }
    if (pb != NULL) {
        input->pb = pb;
        input->flags |= AVFMT_FLAG_CUSTOM_IO;
        // The protocol options went to the connections (and the HLS demuxer finds the timeout and the user agent on the
        // AVIOContext, see FluxoInputIO).
        av_dict_free(&options);
    }
    if (system) {
        // The demuxer's own requests (an HLS input's playlist reloads and segments) go through the URL loading system too.
        session->default_io_open = input->io_open;
        session->default_io_close2 = input->io_close2;
        input->io_open = fluxo_io_open;
        input->io_close2 = fluxo_io_close2;
        // The HLS demuxer turns these off itself for a custom io_open (they need FFmpeg's http protocol); set here, so
        // that it does not say so in the log.
        av_dict_set(&options, "http_persistent", "0", 0);
        av_dict_set(&options, "http_multiple", "0", 0);
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

int fluxo_open_input(FluxoRemuxSession *session) {
    int ret = fluxo_open_input_attempt(session);
    if (ret == FLUXO_HTTP_ERROR_INCOMPATIBLE) {
        // The URL loading system cannot talk to this server (a response it cannot parse, such as SHOUTcast's
        // "ICY 200 OK", or an address it does not accept): FFmpeg's http protocol, for the rest of the session once it
        // opens the input. When it cannot either, the next open tries the URL loading system again (what it refused
        // may have been a passing failure of the server) and this one fails with FFmpeg's error.
        FLUXO_TRACE("the URL loading system cannot open %s: FFmpeg's http protocol", session->input_url);
        session->http_ffmpeg = 1;
        ret = fluxo_open_input_attempt(session);
        if (ret < 0) {
            session->http_ffmpeg = 0;
        }
    }
    return ret;
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
