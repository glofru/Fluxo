//
//  FluxoEngineHTTP.h
//  Fluxo
//
//  Internal to the remux engine (see FluxoEngineInternal.h): HTTP and HTTPS connections through the system's URL
//  loading system (URLSession), for the engine's inputs (FluxoEngineInput.c). TLS 1.3, HTTP/2, the system proxy, App
//  Transport Security and the system trust store come with it; FFmpeg's own http protocol (TLS through the deprecated
//  Secure Transport, TLS 1.2 at most, no system proxy) is the fallback (FluxoRemuxConfig.http_input).
//
//  Each engine session has a client of its own (FluxoHTTPClient: one ephemeral URLSession), so its cookies and its
//  connections are its own, kept in memory only and dropped with the session, as FFmpeg's were: a cookie one panel sets
//  never goes with the requests of another playback, account or playlist.
//
//  One connection is one data task. It is read like a socket: fluxo_http_read blocks the engine thread until data
//  comes, the connection ends, the read times out or the interrupt callback asks to stop (checked every 100 ms, as
//  FFmpeg's network protocols do). The task's data waits in a bounded buffer: above FLUXO_HTTP_HIGH_WATER the task is
//  suspended (TCP or HTTP/2 flow control then holds the server back, as an unread socket does) and it resumes below
//  FLUXO_HTTP_LOW_WATER.
//
//  Errors are FFmpeg's codes, as its http protocol answers them, so that the engine decides its retries the same way:
//  the HTTP status (AVERROR_HTTP_*), ECONNREFUSED, ETIMEDOUT, ECONNRESET, ENETUNREACH, EIO for a failed name lookup;
//  and two of the engine's own for TLS (FLUXO_REMUX_ERROR_TLS_CERTIFICATE, FLUXO_REMUX_ERROR_TLS_HANDSHAKE), which the
//  first open does not try again (fluxo_first_open_retries; the reconnection of a live channel that played does).
//
//  An address that never answers fails after the timeout (15 s), not after FFmpeg's TCP connect timeout (5 s): the URL
//  loading system has no connect timeout of its own and tells nothing of the connection before the response.
//

#ifndef FLUXO_ENGINE_HTTP_H
#define FLUXO_ENGINE_HTTP_H

#include <stdint.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-html"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#include <libavformat/avio.h>
#include <libavutil/error.h>
#pragma clang diagnostic pop

// fluxo_http_open: the system cannot talk to this server, but FFmpeg's http protocol may (a response the URL loading
// system cannot parse, such as SHOUTcast's "ICY 200 OK" status line, or an address NSURL does not accept, such as one
// with an unclosed IPv6 bracket). The engine then opens the input with FFmpeg's http protocol (FluxoEngineInput.c).
// Never reported.
#define FLUXO_HTTP_ERROR_INCOMPATIBLE FFERRTAG('F', 'X', 'H', 'I')

// Flow control of a connection's buffer (bytes): the task is suspended above the high mark, resumed below the low one.
#define FLUXO_HTTP_HIGH_WATER (4 * 1024 * 1024)
#define FLUXO_HTTP_LOW_WATER (1024 * 1024)
// Redirections followed for one request (FFmpeg's http protocol: 8).
#define FLUXO_HTTP_MAX_REDIRECTS 8
// Connections of a client to one server at a time (the URL loading system's default is 4 to 6). An HLS input with
// several renditions has a playlist and a segment request of each open at once; past the limit a request would wait
// in the system's queue (FFmpeg's sockets had no limit).
#define FLUXO_HTTP_MAX_CONNECTIONS_PER_HOST 16

typedef struct FluxoHTTPClient FluxoHTTPClient;
typedef struct FluxoHTTPConnection FluxoHTTPConnection;

typedef struct FluxoHTTPRequest {
    // The client whose cookies and connections the request uses (fluxo_http_client_create).
    FluxoHTTPClient *client;
    // http:// or https:// address. User and password in it answer the Basic or Digest challenge of its server only (the
    // same scheme, host and port; not another server a redirection leads to, unless the new address has its own).
    const char *url;
    // User-Agent header; NULL sends FFmpeg's ("Lavf/<version>"), as the engine did before.
    const char *user_agent;
    // First byte wanted. Every request asks for a byte range from it (also from 0, as FFmpeg does: a server that has
    // byte ranges then says so with a 206).
    int64_t offset;
    // 0, or the byte after the last one wanted (the byte ranges of HLS segments, EXT-X-BYTERANGE).
    int64_t end_offset;
    // Longest wait for the response, and for data during a read (FFmpeg's rw_timeout). Only while the engine waits: a
    // connection it does not read for longer (its read-ahead reached, a paused movie) stays open.
    int64_t timeout_us;
    // Checked while waiting; non-zero stops the wait with AVERROR_EXIT. May be NULL.
    AVIOInterruptCB interrupt;
} FluxoHTTPRequest;

#pragma GCC visibility push(hidden)

// The client of one engine session: its URLSession, cookie storage and connections. 0, or AVERROR(ENOMEM).
int fluxo_http_client_create(FluxoHTTPClient **client);
// Cancels what still runs and frees the client and its cookies; NULL is ignored. Every connection of the client must be
// closed before.
void fluxo_http_client_free(FluxoHTTPClient **client);
// The cookies of the client for `url` (http:// or https://), one per line in the syntax of a Set-Cookie header (name,
// value, domain and path), as FFmpeg's http protocol takes them (its "cookies" option): for the requests the engine
// leaves to FFmpeg. NULL when there are none; free with av_free.
char *fluxo_http_client_cookies(FluxoHTTPClient *client, const char *url);

// Sends the request and waits for the response. 0 with a connection whose body can be read (a 2xx response), or a
// negative error: the HTTP status as AVERROR_HTTP_* for 4xx and 5xx, AVERROR(EIO) for other statuses (a redirection
// that was not followed), a network error, AVERROR_EXIT when interrupted, FLUXO_HTTP_ERROR_INCOMPATIBLE.
int fluxo_http_open(const FluxoHTTPRequest *request, FluxoHTTPConnection **connection);

// Reads up to `size` bytes, waiting at most `timeout_us` (the request's) for the first one. The number of bytes,
// AVERROR_EOF when the server ended the response, AVERROR(ETIMEDOUT), AVERROR_EXIT when interrupted, or the error
// that ended the connection. A connection that ended keeps answering the same.
int fluxo_http_read(FluxoHTTPConnection *connection, uint8_t *buffer, int size);

// The HTTP status of the response (200, 206).
int fluxo_http_status(const FluxoHTTPConnection *connection);
// Where the body starts in the resource: the start of the Content-Range of a 206, 0 for a 200 (a server that ignored
// the range sends the whole resource).
int64_t fluxo_http_start(const FluxoHTTPConnection *connection);
// The size of the whole resource (the total of the Content-Range, or the Content-Length of a 200), -1 when unknown.
int64_t fluxo_http_size(const FluxoHTTPConnection *connection);
// Whether the server has byte ranges (a 206, or Accept-Ranges: bytes), as FFmpeg decides it.
int fluxo_http_seekable(const FluxoHTTPConnection *connection);
// The Content-Type of the response (NULL without one), and the address the body came from after redirections. Valid
// until the connection is closed.
const char *fluxo_http_mime_type(const FluxoHTTPConnection *connection);
const char *fluxo_http_location(const FluxoHTTPConnection *connection);

// Cancels the task if it still runs and waits a moment (at most 1 s) until it has ended, so that a server that allows
// one connection per account sees this one closed before the next one opens. Frees the connection; NULL is ignored.
void fluxo_http_close(FluxoHTTPConnection **connection);

// FFmpeg's error code for a URL loading error (an NSURLErrorDomain code) and, when known, the POSIX error under it
// (0 otherwise); and for an HTTP status that is not 2xx. Exposed for the checks under Tools/EngineSmokeTest.
int fluxo_http_error_from_url_error(long code, long posix_error);
int fluxo_http_error_from_status(int status);

#pragma GCC visibility pop

#endif /* FLUXO_ENGINE_HTTP_H */
