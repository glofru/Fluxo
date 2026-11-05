//
//  churn.c
//  EngineSmokeTest
//
//  Memory check of the remux engine: starts and destroys many sessions in a row (some cancelled
//  while opening, some while recording), converts a recording, and prints the resident memory after
//  every cycle. Run it under `leaks --atExit` (see leaks.sh): every FFmpeg context, packet and buffer
//  must be released by fluxo_remux_destroy / fluxo_remux_convert_file.
//  On-demand inputs given after the live one are played as VOD playlists: segments are requested in
//  order, then far ahead and back (seeks), and some sessions are destroyed in the middle of a segment. Inputs with
//  several audio tracks or subtitles get their renditions (master playlist), and HTTP inputs the engine's own
//  AVIOContext.
//
//  Usage: engine-churn <input-url> <output-dir> <cycles> <seconds-per-cycle> [<on-demand-input> ...]
//

#include "FluxoRemuxEngine.h"

#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int segments;

static void on_event(void *context, const FluxoRemuxEvent *event) {
    (void)context;
    if (event->kind == FluxoRemuxEventSegmentWritten) {
        segments++;
    }
}

// Requests segment `index` of an on-demand session and waits (at most 10 s) until it is on disk.
static int request_segment(FluxoRemuxSession *session, int64_t index) {
    for (int attempt = 0; attempt < 200; attempt++) {
        int32_t result = fluxo_remux_request_segment(session, index, 0);
        if (result != 0) {
            return result;
        }
        usleep(50000);
    }
    return 0;
}

static void churn_on_demand(const char *input, const char *directory, int cycle) {
    char playlist[1024], prefix[1024], master[1024];
    snprintf(playlist, sizeof(playlist), "%s/stream-vod.m3u8", directory);
    snprintf(master, sizeof(master), "%s/stream-vod-master.m3u8", directory);
    snprintf(prefix, sizeof(prefix), "%s/stream-vod", directory);
    FluxoRemuxConfig config;
    memset(&config, 0, sizeof(config));
    config.input_url = input;
    config.io_timeout_us = 5 * 1000000LL;
    config.is_live = 0;
    config.read_ahead_duration = 12;
    config.hls.playlist_path = playlist;
    config.hls.segment_path_prefix = prefix;
    config.hls.segment_duration = 4;
    // Inputs with several audio tracks or subtitles also get their renditions.
    config.hls.master_playlist_path = master;
    // A small cache, so that segments are evicted and produced again.
    config.hls.max_window_bytes = 2 * 1024 * 1024;
    FluxoRemuxSession *session = fluxo_remux_create(&config, on_event, NULL);
    if (session == NULL || fluxo_remux_start(session) != 0) {
        fprintf(stderr, "unable to start %s\n", input);
        exit(1);
    }
    if (cycle % 3 != 0) {
        // In order, a jump ahead, a jump back, then reading on.
        const int64_t order[] = {0, 1, 2, 9, 10, 4, 5, 13};
        int results[8];
        for (int i = 0; i < 8; i++) {
            results[i] = request_segment(session, order[i]);
        }
        printf("[churn] on-demand cycle=%d %s requests=%d,%d,%d,%d,%d,%d,%d,%d\n", cycle, strrchr(input, '/') ? strrchr(input, '/') + 1 : input,
               results[0], results[1], results[2], results[3], results[4], results[5], results[6], results[7]);
        if (cycle % 2 == 0) {
            // Destroyed while it reads ahead.
            usleep(300000);
        }
    }
    // cycle % 3 == 0: destroyed while opening.
    fluxo_remux_destroy(session);
}

static double footprint_megabytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return -1;
    }
    return (double)info.phys_footprint / (1024.0 * 1024.0);
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <input-url> <output-dir> <cycles> <seconds-per-cycle> [<on-demand-input> ...]\n", argv[0]);
        return 2;
    }
    const char *input = argv[1];
    const char *directory = argv[2];
    int cycles = atoi(argv[3]);
    int seconds = atoi(argv[4]);

    char playlist[1024], prefix[1024], recording[1024], mp4[1024];
    snprintf(playlist, sizeof(playlist), "%s/stream-churn.m3u8", directory);
    snprintf(prefix, sizeof(prefix), "%s/stream-churn", directory);
    snprintf(recording, sizeof(recording), "%s/churn-recording.ts", directory);
    snprintf(mp4, sizeof(mp4), "%s/churn-recording.mp4", directory);

    printf("[churn] start footprint=%.1f MB\n", footprint_megabytes());
    for (int cycle = 1; cycle <= cycles; cycle++) {
        FluxoRemuxConfig config;
        memset(&config, 0, sizeof(config));
        config.input_url = input;
        config.io_timeout_us = 5 * 1000000LL;
        config.is_live = 1;
        config.max_reconnect_attempts = 2;
        config.hls.playlist_path = playlist;
        config.hls.segment_path_prefix = prefix;
        config.hls.segment_duration = 1;
        config.hls.max_window_duration = 6;
        config.hls.max_window_bytes = 4 * 1024 * 1024;
        config.hls.min_window_segments = 3;

        FluxoRemuxSession *session = fluxo_remux_create(&config, on_event, NULL);
        if (session == NULL || fluxo_remux_start(session) != 0) {
            fprintf(stderr, "unable to start\n");
            return 1;
        }
        if (cycle % 4 == 0) {
            // Cancelled while opening, with a recording request that is never opened.
            fluxo_remux_start_recording(session, recording);
        } else {
            sleep((unsigned int)seconds);
            if (cycle % 2 == 0) {
                // Destroyed while recording: the recording must be finalized and freed.
                fluxo_remux_start_recording(session, recording);
                sleep(2);
            }
        }
        fluxo_remux_destroy(session);
        printf("[churn] cycle=%d segments=%d footprint=%.1f MB\n", cycle, segments, footprint_megabytes());
        fflush(stdout);
    }

    for (int i = 5; i < argc; i++) {
        for (int cycle = 1; cycle <= cycles; cycle++) {
            churn_on_demand(argv[i], directory, cycle);
        }
        printf("[churn] on-demand %s footprint=%.1f MB\n", argv[i], footprint_megabytes());
        fflush(stdout);
    }

    double duration = 0;
    char error[512] = {0};
    int ret = fluxo_remux_convert_file(recording, mp4, &duration, error, sizeof(error));
    printf("[churn] convert ret=%d duration=%.2f %s\n", ret, duration, error);
    printf("[churn] end footprint=%.1f MB\n", footprint_megabytes());
    return 0;
}
