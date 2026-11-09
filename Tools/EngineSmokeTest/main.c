//
//  main.c
//  EngineSmokeTest
//
//  Runs the shared remux engine (Fluxo/Features/Player/Engine) outside the app against a live
//  MPEG-TS URL: prints every event, starts and stops a recording, then converts the recording to
//  MP4. See run.sh.
//
//  Usage: engine-smoke-test <input-url> <output-dir> <seconds> <record-start> <record-stop> <window-seconds> [vod]
//         engine-smoke-test convert <input-file> <output.mp4>   (fluxo_remux_convert_file only)
//  With "vod" the input is treated as on-demand: no reconnection, unlimited window, EXT-X-ENDLIST at the end.
//  A master playlist (stream-test-master.m3u8) is written when the input has several audio tracks or text
//  subtitles (see run_tracks.sh).
//

#include "FluxoRemuxEngine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *state_name(FluxoRemuxState state) {
    switch (state) {
    case FluxoRemuxStateIdle: return "idle";
    case FluxoRemuxStateOpening: return "opening";
    case FluxoRemuxStateRunning: return "running";
    case FluxoRemuxStateReconnecting: return "reconnecting";
    case FluxoRemuxStateFinished: return "finished";
    case FluxoRemuxStateCancelled: return "cancelled";
    case FluxoRemuxStateFailed: return "failed";
    }
    return "?";
}

static void on_event(void *context, const FluxoRemuxEvent *event) {
    (void)context;
    switch (event->kind) {
    case FluxoRemuxEventStateChanged:
        printf("[event] state=%s attempt=%d message=%s\n", state_name(event->state), event->reconnect_attempt, event->message ? event->message : "-");
        break;
    case FluxoRemuxEventSegmentWritten:
        printf("[event] segment written=%lld window=%d segments %.1fs %lld bytes%s%s\n", (long long)event->segments_written,
               event->window_segment_count, event->window_duration, (long long)event->window_bytes,
               event->recording_path ? " recording=" : "", event->recording_path ? event->recording_path : "");
        if (event->segments_written == 1) {
            printf("[event] master playlist=%d audio renditions=%d subtitle renditions=%d\n", event->master_playlist_written,
                   event->audio_rendition_count, event->subtitle_rendition_count);
        }
        break;
    case FluxoRemuxEventRecordingStarted:
        printf("[event] recording started %s\n", event->recording_path);
        break;
    case FluxoRemuxEventRecordingStopped:
        printf("[event] recording stopped %s %.1fs %lld bytes\n", event->recording_path, event->recording_duration, (long long)event->recording_bytes);
        break;
    case FluxoRemuxEventRecordingFailed:
        printf("[event] recording failed %s: %s\n", event->recording_path ? event->recording_path : "-", event->message ? event->message : "-");
        break;
    case FluxoRemuxEventInputSuspended:
        printf("[event] input suspended after segment %lld\n", (long long)event->segment_index);
        break;
    }
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "convert") == 0) {
        double duration = 0;
        char error[512] = {0};
        int ret = fluxo_remux_convert_file(argv[2], argv[3], &duration, error, sizeof(error));
        printf("[test] convert ret=%d duration=%.2f %s\n", ret, duration, error);
        return ret == 0 ? 0 : 1;
    }
    if (argc < 7) {
        fprintf(stderr, "usage: %s <input-url> <output-dir> <seconds> <record-start> <record-stop> <window-seconds>\n", argv[0]);
        return 2;
    }
    const char *input = argv[1];
    const char *directory = argv[2];
    int seconds = atoi(argv[3]);
    int record_start = atoi(argv[4]);
    int record_stop = atoi(argv[5]);
    double window = atof(argv[6]);
    int is_vod = argc > 7 && strcmp(argv[7], "vod") == 0;

    char playlist[1024], prefix[1024], recording[1024], mp4[1024], master[1024];
    snprintf(playlist, sizeof(playlist), "%s/stream-test.m3u8", directory);
    snprintf(master, sizeof(master), "%s/stream-test-master.m3u8", directory);
    snprintf(prefix, sizeof(prefix), "%s/stream-test", directory);
    snprintf(recording, sizeof(recording), "%s/recording.ts", directory);
    snprintf(mp4, sizeof(mp4), "%s/recording.mp4", directory);

    FluxoRemuxConfig config;
    memset(&config, 0, sizeof(config));
    // FLUXO_HTTP_INPUT=ffmpeg: FFmpeg's http protocol instead of the URL loading system (the app's Legacy Networking).
    config.http_input = getenv("FLUXO_HTTP_INPUT") != NULL && strcmp(getenv("FLUXO_HTTP_INPUT"), "ffmpeg") == 0 ? FluxoRemuxHTTPInputLibavformat : FluxoRemuxHTTPInputSystem;
    config.input_url = input;
    config.io_timeout_us = 5 * 1000000LL;
    config.is_live = is_vod ? 0 : 1;
    config.max_reconnect_attempts = -1;
    config.hls.playlist_path = playlist;
    config.hls.segment_path_prefix = prefix;
    config.hls.segment_duration = 2;
    config.hls.max_window_duration = window;
    config.hls.max_window_bytes = 0;
    config.hls.min_window_segments = 3;
    config.hls.master_playlist_path = master;

    FluxoRemuxSession *session = fluxo_remux_create(&config, on_event, NULL);
    if (session == NULL || fluxo_remux_start(session) != 0) {
        fprintf(stderr, "unable to start\n");
        return 1;
    }
    for (int t = 1; t <= seconds; t++) {
        sleep(1);
        if (t == record_start) {
            printf("[test] t=%d start recording\n", t);
            fluxo_remux_start_recording(session, recording);
        }
        if (t == record_stop) {
            printf("[test] t=%d stop recording\n", t);
            fluxo_remux_stop_recording(session);
        }
    }
    printf("[test] destroy\n");
    fluxo_remux_destroy(session);

    double duration = 0;
    char error[512] = {0};
    int ret = fluxo_remux_convert_file(recording, mp4, &duration, error, sizeof(error));
    printf("[test] convert ret=%d duration=%.2f %s\n", ret, duration, error);
    return ret == 0 ? 0 : 1;
}
