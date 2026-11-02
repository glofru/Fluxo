//
//  FluxoRemuxEngine.h
//  Fluxo
//
//  A small libavformat based remux engine shared by iOS and macOS.
//  It reads a live (or on-demand) input such as an MPEG-TS stream, copies the
//  audio/video packets without re-encoding and writes them to an HLS playlist
//  on disk so that AVPlayer can play them through the loopback HTTP server.
//
//  The header intentionally does not expose any libav* type so that Swift only
//  sees plain C types through the bridging header.
//

#ifndef FLUXO_REMUX_ENGINE_H
#define FLUXO_REMUX_ENGINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Lifecycle states reported by a remux session.
typedef enum __attribute__((enum_extensibility(closed))) FluxoRemuxState {
    FluxoRemuxStateIdle = 0,
    /// Connecting to the input and probing its streams.
    FluxoRemuxStateOpening = 1,
    /// The output header has been written and packets are flowing.
    FluxoRemuxStateRunning = 2,
    /// The input reached its end; the HLS playlist was finalized with EXT-X-ENDLIST.
    FluxoRemuxStateFinished = 3,
    /// The session was cancelled through fluxo_remux_cancel.
    FluxoRemuxStateCancelled = 4,
    /// The session stopped because of an error (see error code and message).
    FluxoRemuxStateFailed = 5,
} FluxoRemuxState;

/// Called from the engine thread whenever the session state changes.
/// `message` is only valid for the duration of the call and may be NULL.
typedef void (*FluxoRemuxStateCallback)(void *context, FluxoRemuxState state, int32_t error_code, const char *message);

/// Options for the HLS output.
typedef struct FluxoRemuxHLSOptions {
    /// Absolute path of the .m3u8 playlist to write.
    const char *playlist_path;
    /// Absolute path pattern for segments, e.g. "/tmp/hls/stream-%05d.ts". NULL lets FFmpeg derive it.
    const char *segment_path_pattern;
    /// Target segment duration in seconds (segments are cut on key frames).
    double segment_duration;
    /// Number of segments kept in the playlist. 0 keeps every segment.
    int32_t playlist_size;
    /// Non-zero deletes segments that fell out of the playlist window.
    int32_t delete_old_segments;
} FluxoRemuxHLSOptions;

/// Configuration of a remux session. All strings are copied by fluxo_remux_create.
typedef struct FluxoRemuxConfig {
    /// Input URL (http, https, udp, file, ...).
    const char *input_url;
    /// Optional User-Agent header for HTTP inputs. May be NULL.
    const char *user_agent;
    /// Maximum time in microseconds a single read/connect may block. 0 uses the engine default.
    int64_t io_timeout_us;
    /// HLS output description.
    FluxoRemuxHLSOptions hls;
} FluxoRemuxConfig;

/// Opaque session handle.
typedef struct FluxoRemuxSession FluxoRemuxSession;

/// Creates a session. Returns NULL on invalid configuration or allocation failure.
/// The callback may be NULL. `context` is passed back unchanged to the callback.
FluxoRemuxSession *fluxo_remux_create(const FluxoRemuxConfig *config, FluxoRemuxStateCallback callback, void *context);

/// Starts remuxing on a dedicated background thread. Returns 0 on success, a negative value otherwise.
/// A session can only be started once.
int32_t fluxo_remux_start(FluxoRemuxSession *session);

/// Requests cancellation. Never blocks; blocking network I/O is aborted through the interrupt callback.
void fluxo_remux_cancel(FluxoRemuxSession *session);

/// Cancels the session, waits for the engine thread to exit and frees every resource.
/// After it returns no further callback is delivered. Must not be called from the state callback.
void fluxo_remux_destroy(FluxoRemuxSession *session);

#ifdef __cplusplus
}
#endif

#endif /* FLUXO_REMUX_ENGINE_H */
