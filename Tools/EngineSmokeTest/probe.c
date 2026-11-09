//
//  probe.c
//  EngineSmokeTest
//
//  Drives the remux engine directly, without AVPlayer (see run_probe.sh):
//
//  engine-probe vod <input-url> <output-dir> <position>...
//      Plays the input on demand and requests the segments at the given positions in order, like a player that seeks:
//      a segment index, or a percentage of the planned playlist ("30%": segments are as long as the GOPs of an
//      indexed input). Each request must be served (1) within 30 s. Prints the result and the time of each one. Exit
//      status 1 when a request fails.
//  engine-probe dead <input-url> <output-dir> <max-seconds>
//      Opens the input as a live channel and measures how long the engine takes to fail. Exit status 0 when it fails
//      within <max-seconds> with a message, 1 when it fails later, plays, or ends otherwise.
//  engine-probe finished <input-url> <output-dir>
//      Plays a short input on demand, cancels the session, then requests a segment that is not on disk: the engine
//      must answer -2 (it will never come), not 0.
//  engine-probe ended <input-url> <output-dir> <index|percent%> <max-seconds>
//      Plays an input on demand whose duration is estimated too long and requests a segment past its real end: the
//      engine must answer -2 (the input ended) within <max-seconds>, without reading the input again from its start.
//  engine-probe suspend <live-input-url> <output-dir>
//      Plays a live input, suspends it (fluxo_remux_set_input_suspended, a long pause) and resumes it: no segment may
//      be written while it is suspended, segments must come again within 5 s of the resume, after an
//      EXT-X-DISCONTINUITY, and the state must stay Running throughout. The engine reports the pause once
//      (FluxoRemuxEventInputSuspended) with the last segment written before it, and the playlist has EXT-X-ENDLIST
//      while suspended only. Every segment's EXT-X-PROGRAM-DATE-TIME is the previous one's plus its EXTINF, across the
//      discontinuity too (the dates follow the media timeline).
//  engine-probe convert <input-file> <output.mp4>
//      Converts a file like a download (fluxo_remux_convert_file).
//  engine-probe read <input-url> <output-dir>
//      Plays the input on demand and requests every segment in order, each once the one before is on disk: the whole
//      input read as fast as the network and the engine allow (run_http.sh compares the inputs' CPU time and memory with it).
//  engine-probe live <input-url> <output-dir> <seconds> <min-segments>
//      Plays a live input for <seconds>: at least <min-segments> segments must be written and the session must not fail.
//  engine-probe play <input-url> <output-dir> <seconds> <speed>
//      Plays the input on demand from its start at <speed> times real time for <seconds>, like a player: requests each
//      segment once the one before has played (its EXTINF / <speed>). The engine reads 60 s ahead and then stops
//      reading until it is 30 s ahead, so its connection stays unread for 30 s / <speed> at a time. Every request must
//      be served within 30 s and the session must never go to Reconnecting (run_http.sh: a connection left unread for
//      longer than the I/O timeout must not fail, as FFmpeg's socket did not).
//  FLUXO_HTTP_INPUT=ffmpeg reads http:// and https:// inputs with FFmpeg's http protocol instead of the URL loading
//  system; FLUXO_PROBE_IO_TIMEOUT_MS sets the engine's network timeout (the app's 15 s otherwise). Every mode prints the peak memory footprint and the CPU time of the process at the end ("[probe] footprint",
//  also in the iOS Simulator, xcrun simctl spawn, where the encoder's memory is in the process).
//

#include "FluxoRemuxEngine.h"

#include <mach/mach.h>
#include <math.h>
#include <sys/resource.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static atomic_int last_state = FluxoRemuxStateIdle;
static atomic_int segments_written;
static atomic_int state_changes;
static atomic_int reconnecting_states;
// FluxoRemuxEventInputSuspended: how many, and the last segment before the pause; the last segment written.
static atomic_int suspended_events;
static atomic_llong suspended_after = -1;
static atomic_llong last_segment = -1;
static char last_message[512];

static void print_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        printf("[probe] footprint now=%.1f MB peak=%.1f MB\n", info.phys_footprint / 1048576.0, info.ledger_phys_footprint_peak / 1048576.0);
    }
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        printf("[probe] cpu user=%.2f s system=%.2f s\n", usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6,
               usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6);
    }
}

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void on_event(void *context, const FluxoRemuxEvent *event) {
    (void)context;
    if (event->kind == FluxoRemuxEventSegmentWritten) {
        atomic_store(&last_segment, event->segment_index);
        atomic_fetch_add(&segments_written, 1);
    }
    if (event->kind == FluxoRemuxEventInputSuspended) {
        atomic_store(&suspended_after, event->segment_index);
        atomic_fetch_add(&suspended_events, 1);
    }
    if (event->kind == FluxoRemuxEventStateChanged) {
        atomic_fetch_add(&state_changes, 1);
        if (event->message != NULL) {
            snprintf(last_message, sizeof(last_message), "%s", event->message);
        }
        atomic_store(&last_state, (int)event->state);
        if (event->state == FluxoRemuxStateReconnecting) {
            atomic_fetch_add(&reconnecting_states, 1);
        }
        printf("[probe] state=%d attempt=%d message=%s\n", event->state, event->reconnect_attempt, event->message ? event->message : "-");
        fflush(stdout);
    }
}

static FluxoRemuxSession *make_session(const char *input, const char *directory, int is_live) {
    static char playlist[1024], prefix[1024], master[1024];
    snprintf(playlist, sizeof(playlist), "%s/stream-probe.m3u8", directory);
    snprintf(master, sizeof(master), "%s/stream-probe-master.m3u8", directory);
    snprintf(prefix, sizeof(prefix), "%s/stream-probe", directory);
    FluxoRemuxConfig config;
    memset(&config, 0, sizeof(config));
    // FLUXO_HTTP_INPUT=ffmpeg: FFmpeg's http protocol instead of the URL loading system (the app's Legacy Networking).
    config.http_input = getenv("FLUXO_HTTP_INPUT") != NULL && strcmp(getenv("FLUXO_HTTP_INPUT"), "ffmpeg") == 0 ? FluxoRemuxHTTPInputLibavformat : FluxoRemuxHTTPInputSystem;
    config.input_url = input;
    // FLUXO_PROBE_IO_TIMEOUT_MS: another timeout than the app's 15 s (the stalled-segment cases of run_http.sh).
    const char *timeout_ms = getenv("FLUXO_PROBE_IO_TIMEOUT_MS");
    config.io_timeout_us = timeout_ms != NULL && atoll(timeout_ms) > 0 ? atoll(timeout_ms) * 1000LL : 15 * 1000000LL;
    config.is_live = is_live;
    // As the app: StreamRemuxer.Configuration / AVPlayerViewModel.
    config.read_ahead_duration = 60;
    config.quick_open = 1;
    config.hls.playlist_path = playlist;
    config.hls.segment_path_prefix = prefix;
    config.hls.segment_duration = is_live ? 2 : 4;
    config.hls.max_window_duration = is_live ? 1800 : 0;
    config.hls.max_window_bytes = 512LL * 1024 * 1024;
    config.hls.min_window_segments = 3;
    config.hls.master_playlist_path = master;
    FluxoRemuxSession *session = fluxo_remux_create(&config, on_event, NULL);
    if (session == NULL || fluxo_remux_start(session) != 0) {
        fprintf(stderr, "[probe] unable to start\n");
        exit(2);
    }
    return session;
}

// Requests segment `index` until the engine answers something other than 0 (at most `limit` seconds).
static int32_t request(FluxoRemuxSession *session, int64_t index, double limit, double *elapsed) {
    double begin = now_seconds();
    int32_t result = 0;
    while (now_seconds() - begin < limit) {
        result = fluxo_remux_request_segment(session, index, 0);
        if (result != 0) {
            break;
        }
        usleep(20000);
    }
    *elapsed = now_seconds() - begin;
    return result;
}

static int count_in_file(const char *path, const char *needle) {
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        return -1;
    }
    char line[4096];
    int count = 0;
    while (fgets(line, sizeof(line), file) != NULL) {
        count += strstr(line, needle) != NULL;
    }
    fclose(file);
    return count;
}

static int run_vod(const char *input, const char *directory, int count, char **indexes) {
    FluxoRemuxSession *session = make_session(input, directory, 0);
    int failures = 0;
    // The plan exists once the engine runs.
    double begin = now_seconds();
    while (atomic_load(&last_state) != FluxoRemuxStateRunning && atomic_load(&last_state) != FluxoRemuxStateFailed && now_seconds() - begin < 30) {
        usleep(20000);
    }
    char playlist[1024];
    snprintf(playlist, sizeof(playlist), "%s/stream-probe.m3u8", directory);
    // An input without a plan (no byte ranges, no index) lists its segments as they are written: wait for the first.
    int planned = count_in_file(playlist, "#EXTINF");
    while (planned <= 0 && atomic_load(&last_state) == FluxoRemuxStateRunning && now_seconds() - begin < 30) {
        usleep(20000);
        planned = count_in_file(playlist, "#EXTINF");
    }
    for (int i = 0; i < count; i++) {
        int64_t index = atoll(indexes[i]);
        if (strchr(indexes[i], '%') != NULL) {
            index = planned > 0 ? (int64_t)(atof(indexes[i]) / 100.0 * planned) : 0;
            if (index >= planned) {
                index = planned - 1;
            }
        }
        double elapsed = 0;
        int32_t result = request(session, index, 30, &elapsed);
        printf("[probe] request %lld (%s of %d) => %d after %.2f s%s\n", (long long)index, indexes[i], planned, result, elapsed, result == 1 ? "" : " FAIL");
        fflush(stdout);
        failures += result != 1;
    }
    fluxo_remux_destroy(session);
    printf("[probe] vod %s\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}

static int run_ended(const char *input, const char *directory, const char *argument, double max_seconds) {
    FluxoRemuxSession *session = make_session(input, directory, 0);
    double begin = now_seconds();
    while (atomic_load(&last_state) != FluxoRemuxStateRunning && atomic_load(&last_state) != FluxoRemuxStateFailed && now_seconds() - begin < 30) {
        usleep(20000);
    }
    char playlist[1024];
    snprintf(playlist, sizeof(playlist), "%s/stream-probe.m3u8", directory);
    int planned = count_in_file(playlist, "#EXTINF");
    int64_t index = strchr(argument, '%') != NULL && planned > 0 ? (int64_t)(atof(argument) / 100.0 * planned) : atoll(argument);
    double elapsed = 0;
    int32_t result = request(session, index, max_seconds + 30, &elapsed);
    fluxo_remux_destroy(session);
    int ok = result == -2 && elapsed <= max_seconds;
    printf("[probe] ended request %lld (%s of %d) => %d after %.2f s (limit %.1f s) => %s\n", (long long)index, argument, planned, result, elapsed,
           max_seconds, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static int run_dead(const char *input, const char *directory, double max_seconds) {
    double begin = now_seconds();
    FluxoRemuxSession *session = make_session(input, directory, 1);
    while (atomic_load(&last_state) != FluxoRemuxStateFailed && atomic_load(&last_state) != FluxoRemuxStateRunning && now_seconds() - begin < 60) {
        usleep(10000);
    }
    double elapsed = now_seconds() - begin;
    int state = atomic_load(&last_state);
    fluxo_remux_destroy(session);
    int ok = state == FluxoRemuxStateFailed && elapsed <= max_seconds && last_message[0] != '\0';
    printf("[probe] dead failed=%d after %.2f s (limit %.1f s) message=\"%s\" => %s\n", state == FluxoRemuxStateFailed, elapsed, max_seconds, last_message,
           ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static int run_finished(const char *input, const char *directory) {
    FluxoRemuxSession *session = make_session(input, directory, 0);
    double begin = now_seconds();
    while (atomic_load(&last_state) != FluxoRemuxStateRunning && atomic_load(&last_state) != FluxoRemuxStateFailed && now_seconds() - begin < 30) {
        usleep(20000);
    }
    double elapsed = 0;
    int32_t first = request(session, 0, 30, &elapsed);
    fluxo_remux_cancel(session);
    // Wait for the engine thread to end (its final state).
    begin = now_seconds();
    while (atomic_load(&last_state) != FluxoRemuxStateCancelled && now_seconds() - begin < 10) {
        usleep(10000);
    }
    int32_t on_disk = fluxo_remux_request_segment(session, 0, 0);
    // Far past the read-ahead (60 s of 4 s segments) of a movie of 2 minutes: not on disk.
    int32_t missing = fluxo_remux_request_segment(session, 25, 0);
    fluxo_remux_destroy(session);
    int ok = first == 1 && on_disk == 1 && missing == -2;
    printf("[probe] finished first=%d on-disk=%d missing=%d => %s\n", first, on_disk, missing, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// The segments of a live playlist whose EXT-X-PROGRAM-DATE-TIME is not the previous segment's plus its EXTINF (the
// engine's dates follow its media timeline, across discontinuities: PausedTimeShiftPolicy.MediaClock); -1 without dates.
// `dated`: how many segments have a date.
static int date_gaps(const char *path, int *dated) {
    *dated = 0;
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        return -1;
    }
    char line[1024];
    long long previous_date = -1;
    long long previous_duration = -1;
    long long date = -1;
    int gaps = 0;
    while (fgets(line, sizeof(line), file) != NULL) {
        if (strncmp(line, "#EXT-X-PROGRAM-DATE-TIME:", 25) == 0) {
            struct tm utc = {0};
            const char *rest = strptime(line + 25, "%Y-%m-%dT%H:%M:%S", &utc);
            int milliseconds = 0;
            if (rest == NULL || sscanf(rest, ".%3dZ", &milliseconds) != 1) {
                fclose(file);
                return -1;
            }
            date = (long long)timegm(&utc) * 1000 + milliseconds;
        } else if (strncmp(line, "#EXTINF:", 8) == 0) {
            if (date < 0) {
                fclose(file);
                return -1;
            }
            if (previous_date >= 0 && date != previous_date + previous_duration) {
                gaps++;
            }
            previous_date = date;
            previous_duration = llround(atof(line + 8) * 1000);
            date = -1;
            (*dated)++;
        }
    }
    fclose(file);
    return *dated > 0 ? gaps : -1;
}

static int run_suspend(const char *input, const char *directory) {
    FluxoRemuxSession *session = make_session(input, directory, 1);
    double begin = now_seconds();
    while (atomic_load(&segments_written) < 3 && now_seconds() - begin < 30) {
        usleep(50000);
    }
    char playlist[1024];
    snprintf(playlist, sizeof(playlist), "%s/stream-probe.m3u8", directory);
    int before = atomic_load(&segments_written);
    int discontinuities = count_in_file(playlist, "#EXT-X-DISCONTINUITY");
    int ended_before = count_in_file(playlist, "#EXT-X-ENDLIST") == 0;
    int changes = atomic_load(&state_changes);
    fluxo_remux_set_input_suspended(session, 1);
    sleep(1);
    int at_suspend = atomic_load(&segments_written);
    long long last_before = atomic_load(&last_segment);
    sleep(6);
    int during = atomic_load(&segments_written) - at_suspend;
    // Marked as ended while suspended (players do not reload it), not before nor after.
    int ended_during = count_in_file(playlist, "#EXT-X-ENDLIST") == 1;
    fluxo_remux_set_input_suspended(session, 0);
    double resumed = now_seconds();
    while (atomic_load(&segments_written) <= at_suspend + during + 1 && now_seconds() - resumed < 10) {
        usleep(50000);
    }
    double latency = now_seconds() - resumed;
    int after = atomic_load(&segments_written) - at_suspend - during;
    int discontinuities_after = count_in_file(playlist, "#EXT-X-DISCONTINUITY");
    int ended_after = count_in_file(playlist, "#EXT-X-ENDLIST") == 0;
    int dated = 0;
    int gaps = date_gaps(playlist, &dated);
    int state = atomic_load(&last_state);
    int quiet = atomic_load(&state_changes) == changes;
    fluxo_remux_destroy(session);
    // The engine reports the pause once, with the last segment before it (the app replaces its item after it).
    int reported = atomic_load(&suspended_events) == 1 && atomic_load(&suspended_after) == last_before && last_before >= 0;
    int ended_marks = ended_before && ended_during && ended_after;
    int ok = before >= 3 && during == 0 && after >= 2 && latency < 5 && discontinuities_after > discontinuities && state == FluxoRemuxStateRunning && quiet &&
             reported && ended_marks && gaps == 0;
    printf("[probe] suspend before=%d during=%d after=%d (%.2f s after the resume) discontinuities %d -> %d state=%d quiet=%d reported=%d (after segment %lld, "
           "last %lld) endlist only while suspended=%d dates following the durations, across the discontinuity: %d gaps in %d => %s\n", before, during,
           after, latency, discontinuities, discontinuities_after, state, quiet, atomic_load(&suspended_events), atomic_load(&suspended_after), last_before,
           ended_marks, gaps, dated, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static int run_read(const char *input, const char *directory) {
    FluxoRemuxSession *session = make_session(input, directory, 0);
    double begin = now_seconds();
    while (atomic_load(&last_state) != FluxoRemuxStateRunning && atomic_load(&last_state) != FluxoRemuxStateFailed && now_seconds() - begin < 30) {
        usleep(20000);
    }
    char playlist[1024];
    snprintf(playlist, sizeof(playlist), "%s/stream-probe.m3u8", directory);
    int planned = count_in_file(playlist, "#EXTINF");
    int served = 0;
    double slowest = 0;
    for (int64_t index = 0; index < planned; index++) {
        double elapsed = 0;
        int32_t result = request(session, index, 60, &elapsed);
        if (result != 1) {
            printf("[probe] request %lld => %d after %.2f s FAIL\n", (long long)index, result, elapsed);
            break;
        }
        slowest = elapsed > slowest ? elapsed : slowest;
        served++;
    }
    double total = now_seconds() - begin;
    fluxo_remux_destroy(session);
    int ok = planned > 0 && served == planned;
    printf("[probe] read %d of %d segments in %.2f s (slowest request %.2f s) => %s\n", served, planned, total, slowest, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

// The duration of segment `index` in the playlist (its EXTINF), -1 when it is not listed (yet).
static double segment_duration(const char *path, int64_t index) {
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        return -1;
    }
    char line[4096];
    int64_t seen = 0;
    double duration = -1;
    while (fgets(line, sizeof(line), file) != NULL) {
        if (strncmp(line, "#EXTINF:", 8) == 0 && seen++ == index) {
            duration = atof(line + 8);
            break;
        }
    }
    fclose(file);
    return duration;
}

static int run_play(const char *input, const char *directory, double seconds, double speed) {
    FluxoRemuxSession *session = make_session(input, directory, 0);
    double begin = now_seconds();
    while (atomic_load(&last_state) != FluxoRemuxStateRunning && atomic_load(&last_state) != FluxoRemuxStateFailed && now_seconds() - begin < 30) {
        usleep(20000);
    }
    char playlist[1024];
    snprintf(playlist, sizeof(playlist), "%s/stream-probe.m3u8", directory);
    double started = now_seconds();
    double played = 0;
    double slowest = 0;
    int64_t index = 0;
    int failed = 0;
    while (now_seconds() - started < seconds) {
        double elapsed = 0;
        int32_t result = request(session, index, 30, &elapsed);
        if (result != 1) {
            printf("[probe] request %lld => %d after %.2f s FAIL\n", (long long)index, result, elapsed);
            failed = 1;
            break;
        }
        slowest = elapsed > slowest ? elapsed : slowest;
        double duration = segment_duration(playlist, index);
        if (duration <= 0) {
            duration = 4;
        }
        played += duration;
        index++;
        // The segment plays: the next one is requested once it has.
        double until = now_seconds() + duration / speed;
        while (now_seconds() < until && now_seconds() - started < seconds) {
            usleep(20000);
        }
    }
    int reconnecting = atomic_load(&reconnecting_states);
    int state = atomic_load(&last_state);
    fluxo_remux_destroy(session);
    int ok = !failed && index > 0 && reconnecting == 0 && (state == FluxoRemuxStateRunning || state == FluxoRemuxStateFinished);
    printf("[probe] play %lld segments (%.0f s of media) in %.0f s at %.1fx (slowest request %.2f s), Reconnecting %d times, state=%d => %s\n",
           (long long)index, played, now_seconds() - started, speed, slowest, reconnecting, state, ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static int run_live(const char *input, const char *directory, double seconds, int min_segments) {
    FluxoRemuxSession *session = make_session(input, directory, 1);
    double begin = now_seconds();
    int failed = 0;
    while (now_seconds() - begin < seconds) {
        failed |= atomic_load(&last_state) == FluxoRemuxStateFailed;
        usleep(100000);
    }
    int segments = atomic_load(&segments_written);
    int state = atomic_load(&last_state);
    fluxo_remux_destroy(session);
    int ok = !failed && segments >= min_segments && (state == FluxoRemuxStateRunning || state == FluxoRemuxStateReconnecting);
    printf("[probe] live %d segments in %.0f s (at least %d) state=%d message=\"%s\" => %s\n", segments, seconds, min_segments, state, last_message,
           ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static int run_convert(const char *input, const char *output) {
    double begin = now_seconds();
    double duration = 0;
    char error[512] = {0};
    int ret = fluxo_remux_convert_file(input, output, &duration, error, sizeof(error));
    printf("[probe] convert ret=%d duration=%.2f s in %.2f s %s => %s\n", ret, duration, now_seconds() - begin, error, ret == 0 ? "PASS" : "FAIL");
    return ret == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    int status = -1;
    if (argc >= 5 && strcmp(argv[1], "vod") == 0) {
        status = run_vod(argv[2], argv[3], argc - 4, argv + 4);
    } else if (argc == 5 && strcmp(argv[1], "dead") == 0) {
        status = run_dead(argv[2], argv[3], atof(argv[4]));
    } else if (argc == 4 && strcmp(argv[1], "finished") == 0) {
        status = run_finished(argv[2], argv[3]);
    } else if (argc == 6 && strcmp(argv[1], "ended") == 0) {
        status = run_ended(argv[2], argv[3], argv[4], atof(argv[5]));
    } else if (argc == 4 && strcmp(argv[1], "suspend") == 0) {
        status = run_suspend(argv[2], argv[3]);
    } else if (argc == 4 && strcmp(argv[1], "convert") == 0) {
        status = run_convert(argv[2], argv[3]);
    } else if (argc == 4 && strcmp(argv[1], "read") == 0) {
        status = run_read(argv[2], argv[3]);
    } else if (argc == 6 && strcmp(argv[1], "live") == 0) {
        status = run_live(argv[2], argv[3], atof(argv[4]), atoi(argv[5]));
    } else if (argc == 6 && strcmp(argv[1], "play") == 0 && atof(argv[5]) > 0) {
        status = run_play(argv[2], argv[3], atof(argv[4]), atof(argv[5]));
    }
    if (status >= 0) {
        print_footprint();
        return status;
    }
    fprintf(stderr, "usage: %s vod <input-url> <output-dir> <index>... | dead <input-url> <output-dir> <max-seconds> | finished <input-url> <output-dir> | ended <input-url> <output-dir> <index> <max-seconds> | suspend <live-url> <output-dir> | convert <input> <output.mp4> | read <input-url> <output-dir> | live <input-url> <output-dir> <seconds> <min-segments> | play <input-url> <output-dir> <seconds> <speed>\n", argv[0]);
    return 2;
}
