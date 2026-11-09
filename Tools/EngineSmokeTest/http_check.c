//
//  http_check.c
//  EngineSmokeTest
//
//  The remux engine's HTTP connections through the URL loading system (Fluxo/Features/Player/Engine/FluxoEngineHTTP.h),
//  driven directly against the local test servers of run_http.sh:
//
//  http_check get <url> <file> [<offset> [<end>]]
//      Reads the resource from <offset> (to the byte before <end>) and compares every byte with <file>. Prints the
//      status, the size, whether it is seekable, where the body starts, the MIME type, the address after redirections
//      and the throughput. With HTTP_CHECK_EXPECT="status=206 seekable=1 size=…" those must match too.
//  http_check error <url> <name>
//      Opening (or else reading) must fail with that error: refused, timeout, eio, unreachable, reset, 400, 401, 403,
//      404, 429, 4xx, 5xx, certificate, handshake, incompatible; several separated by "|" (any of them).
//  http_check timeout <url> <timeout-ms>
//      A connection with that timeout to a server that stops sending: the read must fail with ETIMEDOUT, no sooner than
//      the timeout and within half a second of it. With HTTP_CHECK_WHOLE=1, the whole check (open included) must too
//      (a server that sends its headers and then nothing fails after one timeout, not two).
//  http_check cancel <url> <after-ms>
//      A read waiting for a server that stops sending is interrupted after <after-ms>: it must end with AVERROR_EXIT
//      within 0.3 s.
//  http_check flow <url> <file>
//      Reads 1 MB, then nothing for 3 s (a local server sends hundreds of MB meanwhile), then the rest: the memory must
//      stay bounded by the flow control (the task is suspended above FLUXO_HTTP_HIGH_WATER) and every byte must match.
//  http_check pause <url> <file> <timeout-ms> <pause-ms> [<end>]
//      A connection with that timeout (to the byte before <end>): reads 1 MB, then nothing for <pause-ms> (longer than
//      the timeout: the task is suspended by the flow control meanwhile), then the rest, which must come whole and
//      without an error. The timeout limits waiting for data only, as FFmpeg's rw_timeout: a connection the engine does
//      not read (its read-ahead reached, a paused movie) must not time out.
//  http_check cookies <url> <cookie>
//      Reads <url> (which sets the cookie "<cookie>", e.g. fluxo-token=1) with one client: that client must have it for
//      <url> (fluxo_http_client_cookies), another client must not, and the first one no longer once it is freed and
//      made again (the cookies of one engine session never go with another's requests).
//
//  Exit status 0 when the check passes.
//

#include "FluxoEngineHTTP.h"
#include "FluxoRemuxEngine.h"

#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavutil/error.h>
#include <libavutil/mem.h>
#pragma clang diagnostic pop

static atomic_int interrupted;
// The client of every check's connections (an engine session's).
static FluxoHTTPClient *client;

static int interrupt_callback(void *opaque) {
    (void)opaque;
    return atomic_load(&interrupted);
}

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static double footprint_mb(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return -1;
    }
    return info.phys_footprint / 1048576.0;
}

static const char *error_name(int error) {
    static char buffer[128];
    if (error == AVERROR(ECONNREFUSED)) return "refused";
    if (error == AVERROR(ETIMEDOUT)) return "timeout";
    if (error == AVERROR(EIO)) return "eio";
    if (error == AVERROR(ENETUNREACH) || error == AVERROR(EHOSTUNREACH)) return "unreachable";
    if (error == AVERROR(ECONNRESET)) return "reset";
    if (error == AVERROR_HTTP_BAD_REQUEST) return "400";
    if (error == AVERROR_HTTP_UNAUTHORIZED) return "401";
    if (error == AVERROR_HTTP_FORBIDDEN) return "403";
    if (error == AVERROR_HTTP_NOT_FOUND) return "404";
    if (error == AVERROR_HTTP_TOO_MANY_REQUESTS) return "429";
    if (error == AVERROR_HTTP_OTHER_4XX) return "4xx";
    if (error == AVERROR_HTTP_SERVER_ERROR) return "5xx";
    if (error == FLUXO_REMUX_ERROR_TLS_CERTIFICATE) return "certificate";
    if (error == FLUXO_REMUX_ERROR_TLS_HANDSHAKE) return "handshake";
    if (error == FLUXO_HTTP_ERROR_INCOMPATIBLE) return "incompatible";
    if (error == AVERROR_EXIT) return "exit";
    if (error == AVERROR_EOF) return "eof";
    char reason[64] = {0};
    av_strerror(error, reason, sizeof(reason));
    snprintf(buffer, sizeof(buffer), "%d (%s)", error, reason);
    return buffer;
}

static FluxoHTTPRequest make_request(const char *url, int64_t offset, int64_t end, int64_t timeout_us) {
    FluxoHTTPRequest request = {
        .client = client,
        .url = url,
        .user_agent = getenv("HTTP_CHECK_USER_AGENT"),
        .offset = offset,
        .end_offset = end,
        .timeout_us = timeout_us,
        .interrupt = { interrupt_callback, NULL },
    };
    return request;
}

static void print_connection(const FluxoHTTPConnection *connection) {
    printf("[http] status=%d size=%lld seekable=%d start=%lld mime=%s location=%s\n", fluxo_http_status(connection),
           (long long)fluxo_http_size(connection), fluxo_http_seekable(connection), (long long)fluxo_http_start(connection),
           fluxo_http_mime_type(connection) ? fluxo_http_mime_type(connection) : "-", fluxo_http_location(connection) ? fluxo_http_location(connection) : "-");
}

// HTTP_CHECK_EXPECT="status=206 seekable=1 size=123 start=0 location-suffix=/h264.mkv mime=video/x-matroska"
static int check_expectations(const FluxoHTTPConnection *connection) {
    const char *expect = getenv("HTTP_CHECK_EXPECT");
    if (expect == NULL || expect[0] == '\0') {
        return 1;
    }
    char copy[1024];
    snprintf(copy, sizeof(copy), "%s", expect);
    int ok = 1;
    for (char *save = NULL, *word = strtok_r(copy, " ", &save); word != NULL; word = strtok_r(NULL, " ", &save)) {
        char *equals = strchr(word, '=');
        if (equals == NULL) {
            continue;
        }
        *equals = '\0';
        const char *value = equals + 1;
        int match = 1;
        if (strcmp(word, "status") == 0) {
            match = fluxo_http_status(connection) == atoi(value);
        } else if (strcmp(word, "seekable") == 0) {
            match = fluxo_http_seekable(connection) == atoi(value);
        } else if (strcmp(word, "size") == 0) {
            match = fluxo_http_size(connection) == atoll(value);
        } else if (strcmp(word, "start") == 0) {
            match = fluxo_http_start(connection) == atoll(value);
        } else if (strcmp(word, "mime") == 0) {
            match = fluxo_http_mime_type(connection) != NULL && strcmp(fluxo_http_mime_type(connection), value) == 0;
        } else if (strcmp(word, "location-suffix") == 0) {
            const char *location = fluxo_http_location(connection);
            size_t length = location != NULL ? strlen(location) : 0;
            match = location != NULL && length >= strlen(value) && strcmp(location + length - strlen(value), value) == 0;
        }
        if (!match) {
            printf("[http] expected %s=%s\n", word, value);
            ok = 0;
        }
    }
    return ok;
}

// Reads the connection to its end and compares the bytes with `file` from `offset`. `pause_after`: bytes after which
// it waits `pause_ms` once (0: never). Returns 1 when everything matched.
static int read_and_compare(FluxoHTTPConnection *connection, const char *file, int64_t offset, int64_t expected, int64_t pause_after,
                            int pause_ms, double *peak_footprint) {
    int fd = open(file, O_RDONLY);
    if (fd < 0) {
        perror(file);
        return 0;
    }
    static uint8_t buffer[256 * 1024];
    static uint8_t reference[256 * 1024];
    int64_t total = 0;
    int ok = 1;
    int paused = 0;
    double begin = now_seconds();
    for (;;) {
        int want = sizeof(buffer);
        if (pause_after > 0 && !paused && total < pause_after && pause_after - total < want) {
            want = (int)(pause_after - total);
        }
        int ret = fluxo_http_read(connection, buffer, want);
        if (ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            printf("[http] read failed after %lld bytes: %s\n", (long long)total, error_name(ret));
            ok = 0;
            break;
        }
        ssize_t got = pread(fd, reference, (size_t)ret, offset + total);
        if (got != ret || memcmp(buffer, reference, (size_t)ret) != 0) {
            printf("[http] bytes differ at %lld\n", (long long)(offset + total));
            ok = 0;
            break;
        }
        total += ret;
        if (pause_after > 0 && !paused && total >= pause_after) {
            paused = 1;
            double before = footprint_mb();
            usleep((useconds_t)pause_ms * 1000);
            double after = footprint_mb();
            printf("[http] paused %.1f s after %lld bytes: footprint %.1f MB -> %.1f MB\n", pause_ms / 1000.0, (long long)total, before, after);
            if (peak_footprint != NULL) {
                *peak_footprint = after - before;
            }
        }
    }
    close(fd);
    double elapsed = now_seconds() - begin;
    printf("[http] read %lld bytes in %.2f s (%.1f MB/s)\n", (long long)total, elapsed, elapsed > 0 ? total / 1048576.0 / elapsed : 0);
    if (expected >= 0 && total != expected) {
        printf("[http] expected %lld bytes\n", (long long)expected);
        ok = 0;
    }
    return ok;
}

static int64_t file_size(const char *file) {
    FILE *handle = fopen(file, "rb");
    if (handle == NULL) {
        return -1;
    }
    fseeko(handle, 0, SEEK_END);
    int64_t size = ftello(handle);
    fclose(handle);
    return size;
}

static int run_get(const char *url, const char *file, int64_t offset, int64_t end) {
    FluxoHTTPRequest request = make_request(url, offset, end, 15 * 1000000LL);
    FluxoHTTPConnection *connection = NULL;
    double begin = now_seconds();
    int ret = fluxo_http_open(&request, &connection);
    if (ret < 0) {
        printf("[http] get open failed: %s => FAIL\n", error_name(ret));
        return 1;
    }
    printf("[http] response after %.3f s\n", now_seconds() - begin);
    print_connection(connection);
    int64_t size = file_size(file);
    int64_t expected = (end > 0 ? (end < size ? end : size) : size) - offset;
    int ok = check_expectations(connection) && read_and_compare(connection, file, offset, expected, 0, 0, NULL);
    fluxo_http_close(&connection);
    printf("[http] get %s => %s\n", url, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static int run_error(const char *url, const char *name) {
    FluxoHTTPRequest request = make_request(url, 0, 0, 15 * 1000000LL);
    FluxoHTTPConnection *connection = NULL;
    double begin = now_seconds();
    int ret = fluxo_http_open(&request, &connection);
    if (ret == 0) {
        uint8_t buffer[65536];
        do {
            ret = fluxo_http_read(connection, buffer, sizeof(buffer));
        } while (ret > 0);
        fluxo_http_close(&connection);
    }
    // `name` may list several ("eio|reset").
    const char *got = error_name(ret);
    char names[128];
    snprintf(names, sizeof(names), "|%s|", name);
    char wanted[160];
    snprintf(wanted, sizeof(wanted), "|%s|", got);
    int ok = strstr(names, wanted) != NULL;
    printf("[http] error %s after %.2f s (expected %s) => %s\n", got, now_seconds() - begin, name, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static int run_timeout(const char *url, int timeout_ms) {
    FluxoHTTPRequest request = make_request(url, 0, 0, (int64_t)timeout_ms * 1000);
    FluxoHTTPConnection *connection = NULL;
    double begin = now_seconds();
    int ret = fluxo_http_open(&request, &connection);
    double waited = 0;
    if (ret == 0) {
        uint8_t buffer[65536];
        double last = now_seconds();
        do {
            last = now_seconds();
            ret = fluxo_http_read(connection, buffer, sizeof(buffer));
        } while (ret > 0);
        waited = now_seconds() - last;
        fluxo_http_close(&connection);
    } else {
        waited = now_seconds() - begin;
    }
    double limit = timeout_ms / 1000.0;
    double whole = now_seconds() - begin;
    int ok = ret == AVERROR(ETIMEDOUT) && waited >= limit - 0.05 && waited <= limit + 0.5;
    if (getenv("HTTP_CHECK_WHOLE") != NULL && strcmp(getenv("HTTP_CHECK_WHOLE"), "1") == 0) {
        ok = ok && whole <= limit + 0.5;
    }
    printf("[http] timeout %s after waiting %.2f s for data, %.2f s in all (timeout %.2f s) => %s\n", error_name(ret), waited, whole, limit,
           ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static void *interrupter(void *argument) {
    usleep((useconds_t)(*(int *)argument) * 1000);
    atomic_store(&interrupted, 1);
    return NULL;
}

static int run_cancel(const char *url, int after_ms) {
    FluxoHTTPRequest request = make_request(url, 0, 0, 60 * 1000000LL);
    FluxoHTTPConnection *connection = NULL;
    pthread_t thread;
    double begin = now_seconds();
    pthread_create(&thread, NULL, interrupter, &after_ms);
    int ret = fluxo_http_open(&request, &connection);
    if (ret == 0) {
        uint8_t buffer[65536];
        do {
            ret = fluxo_http_read(connection, buffer, sizeof(buffer));
        } while (ret > 0);
    }
    double stopped = now_seconds() - begin - after_ms / 1000.0;
    fluxo_http_close(&connection);
    double closed = now_seconds() - begin - after_ms / 1000.0;
    pthread_join(thread, NULL);
    int ok = ret == AVERROR_EXIT && stopped >= -0.01 && stopped <= 0.3 && closed <= 1.2;
    printf("[http] cancel %s %.3f s after the interrupt, closed after %.3f s => %s\n", error_name(ret), stopped, closed, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static int run_flow(const char *url, const char *file) {
    FluxoHTTPRequest request = make_request(url, 0, 0, 15 * 1000000LL);
    FluxoHTTPConnection *connection = NULL;
    int ret = fluxo_http_open(&request, &connection);
    if (ret < 0) {
        printf("[http] flow open failed: %s => FAIL\n", error_name(ret));
        return 1;
    }
    double growth = 0;
    int ok = read_and_compare(connection, file, 0, file_size(file), 1024 * 1024, 3000, &growth);
    fluxo_http_close(&connection);
    // The buffer holds at most FLUXO_HTTP_HIGH_WATER plus what the system delivers while it suspends the task.
    int bounded = growth < 3.0 * FLUXO_HTTP_HIGH_WATER / 1048576.0;
    printf("[http] flow memory growth while paused %.1f MB (limit %.1f MB) => %s\n", growth, 3.0 * FLUXO_HTTP_HIGH_WATER / 1048576.0,
           ok && bounded ? "PASS" : "FAIL");
    return ok && bounded ? 0 : 1;
}

static int run_pause(const char *url, const char *file, int timeout_ms, int pause_ms, int64_t end) {
    FluxoHTTPRequest request = make_request(url, 0, end, (int64_t)timeout_ms * 1000);
    FluxoHTTPConnection *connection = NULL;
    int ret = fluxo_http_open(&request, &connection);
    if (ret < 0) {
        printf("[http] pause open failed: %s => FAIL\n", error_name(ret));
        return 1;
    }
    int64_t size = file_size(file);
    int64_t expected = end > 0 && end < size ? end : size;
    int ok = read_and_compare(connection, file, 0, expected, 1024 * 1024, pause_ms, NULL);
    fluxo_http_close(&connection);
    printf("[http] pause %.1f s with a timeout of %.1f s, then read on => %s\n", pause_ms / 1000.0, timeout_ms / 1000.0, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static int has_cookie(FluxoHTTPClient *of, const char *url, const char *cookie) {
    char *cookies = fluxo_http_client_cookies(of, url);
    int found = cookies != NULL && strstr(cookies, cookie) != NULL;
    printf("[http] cookies %s\n", cookies != NULL ? cookies : "(none)");
    av_free(cookies);
    return found;
}

static int run_cookies(const char *url, const char *cookie) {
    FluxoHTTPRequest request = make_request(url, 0, 0, 15 * 1000000LL);
    FluxoHTTPConnection *connection = NULL;
    int ret = fluxo_http_open(&request, &connection);
    if (ret == 0) {
        uint8_t buffer[65536];
        do {
            ret = fluxo_http_read(connection, buffer, sizeof(buffer));
        } while (ret > 0);
        fluxo_http_close(&connection);
    }
    int read = ret == AVERROR_EOF;
    int kept = has_cookie(client, url, cookie);
    FluxoHTTPClient *other = NULL;
    int isolated = fluxo_http_client_create(&other) == 0 && !has_cookie(other, url, cookie);
    fluxo_http_client_free(&other);
    fluxo_http_client_free(&client);
    int dropped = fluxo_http_client_create(&client) == 0 && !has_cookie(client, url, cookie);
    int ok = read && kept && isolated && dropped;
    printf("[http] cookies read=%d kept=%d other-client-without=%d dropped-with-client=%d => %s\n", read, kept, isolated, dropped,
           ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static int run(int argc, char **argv) {
    if (argc >= 4 && strcmp(argv[1], "get") == 0) {
        return run_get(argv[2], argv[3], argc > 4 ? atoll(argv[4]) : 0, argc > 5 ? atoll(argv[5]) : 0);
    }
    if (argc == 4 && strcmp(argv[1], "error") == 0) {
        return run_error(argv[2], argv[3]);
    }
    if (argc == 4 && strcmp(argv[1], "timeout") == 0) {
        return run_timeout(argv[2], atoi(argv[3]));
    }
    if (argc == 4 && strcmp(argv[1], "cancel") == 0) {
        return run_cancel(argv[2], atoi(argv[3]));
    }
    if (argc == 4 && strcmp(argv[1], "flow") == 0) {
        return run_flow(argv[2], argv[3]);
    }
    if ((argc == 6 || argc == 7) && strcmp(argv[1], "pause") == 0) {
        return run_pause(argv[2], argv[3], atoi(argv[4]), atoi(argv[5]), argc > 6 ? atoll(argv[6]) : 0);
    }
    if (argc == 4 && strcmp(argv[1], "cookies") == 0) {
        return run_cookies(argv[2], argv[3]);
    }
    fprintf(stderr, "usage: %s get <url> <file> [<offset> [<end>]] | error <url> <name> | timeout <url> <ms> | cancel <url> <ms> | flow <url> <file> | pause <url> <file> <timeout-ms> <pause-ms> [<end>] | cookies <url> <cookie>\n",
            argv[0]);
    return 2;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (fluxo_http_client_create(&client) < 0) {
        fprintf(stderr, "[http] no client\n");
        return 2;
    }
    int status = run(argc, argv);
    fluxo_http_client_free(&client);
    return status;
}
