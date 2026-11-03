//
//  churn.c
//  EngineSmokeTest
//
//  Memory check of the remux engine: starts and destroys many sessions in a row (some cancelled
//  while opening, some while recording), converts a recording, and prints the resident memory after
//  every cycle. Run it under `leaks --atExit` (see leaks.sh): every FFmpeg context, packet and buffer
//  must be released by fluxo_remux_destroy / fluxo_remux_convert_file.
//
//  Usage: engine-churn <input-url> <output-dir> <cycles> <seconds-per-cycle>
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
        fprintf(stderr, "usage: %s <input-url> <output-dir> <cycles> <seconds-per-cycle>\n", argv[0]);
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

    double duration = 0;
    char error[512] = {0};
    int ret = fluxo_remux_convert_file(recording, mp4, &duration, error, sizeof(error));
    printf("[churn] convert ret=%d duration=%.2f %s\n", ret, duration, error);
    printf("[churn] end footprint=%.1f MB\n", footprint_megabytes());
    return 0;
}
