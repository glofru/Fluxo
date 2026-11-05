//
//  FluxoRemuxEngine.h
//  Fluxo
//
//  A small libavformat based remux engine shared by iOS and macOS.
//  It reads a live (or on-demand) input such as an MPEG-TS stream, copies the
//  audio/video packets without re-encoding and writes them to an HLS playlist
//  on disk so that AVPlayer can play them through the loopback HTTP server.
//
//  The engine has its own HLS segmenter so that it can:
//  - keep a bounded time-shift (DVR) window, capped by duration and by disk usage,
//    and delete the segments that leave the window;
//  - report every completed segment, so the player attaches only once media exists;
//  - reconnect to live inputs after network drops while keeping the playlist continuous;
//  - record the stream to a second output (an MPEG-TS file) at the same time;
//  - make the extra audio tracks and the text subtitles of the input selectable (see
//    FluxoRemuxHLSOptions.master_playlist_path): each becomes an HLS rendition of a master playlist,
//    audio as audio-only MPEG-TS segments, subtitles as WebVTT segments cut with the video;
//  - play on-demand inputs (movies, episodes) as a complete VOD playlist: the segments are planned
//    from the duration and the key frame index of the input before playback starts, and produced
//    on request (fluxo_remux_request_segment). A request far from what is being read seeks the
//    input there, so the player can jump anywhere at once; the engine reads only a bounded
//    distance ahead of the player and keeps a bounded number of segments on disk. Their renditions
//    are complete VOD playlists of the same segments, produced with them.
//
//  Segments are MPEG-TS, or fragmented MP4 (with an EXT-X-MAP initialization segment) when the video
//  is HEVC: AVPlayer only decodes HEVC from fMP4 HLS (in MPEG-TS it plays the audio over black video).
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
    /// Packets are flowing to the HLS output.
    FluxoRemuxStateRunning = 2,
    /// The live input dropped; the engine is reconnecting. The playlist stays available.
    FluxoRemuxStateReconnecting = 3,
    /// The input reached its end; the HLS playlist was finalized with EXT-X-ENDLIST.
    FluxoRemuxStateFinished = 4,
    /// The session was cancelled through fluxo_remux_cancel.
    FluxoRemuxStateCancelled = 5,
    /// The session stopped because of an error (see error code and message).
    FluxoRemuxStateFailed = 6,
} FluxoRemuxState;

/// Kind of a FluxoRemuxEvent.
typedef enum __attribute__((enum_extensibility(closed))) FluxoRemuxEventKind {
    /// `state` changed. `error_code` / `message` describe failures; `reconnect_attempt` is set while reconnecting.
    FluxoRemuxEventStateChanged = 0,
    /// A new HLS segment was completed and the playlist was rewritten.
    FluxoRemuxEventSegmentWritten = 1,
    /// A recording started writing to `recording_path`.
    FluxoRemuxEventRecordingStarted = 2,
    /// A recording was closed and its file is complete. Also reported, with nothing written, for a
    /// requested recording that was stopped, replaced or left queued when the session ended before
    /// the engine could open it: every started request gets exactly one Stopped or Failed event.
    FluxoRemuxEventRecordingStopped = 3,
    /// A recording could not be started or stopped because of an error. The partial file may exist.
    FluxoRemuxEventRecordingFailed = 4,
} FluxoRemuxEventKind;

/// Event delivered to the session callback. Pointers are only valid for the duration of the call.
typedef struct FluxoRemuxEvent {
    FluxoRemuxEventKind kind;
    /// Current session state.
    FluxoRemuxState state;
    int32_t error_code;
    /// Human readable error, or NULL.
    const char *message;
    /// Consecutive reconnection attempt (1-based) while the state is Reconnecting, 0 otherwise.
    int32_t reconnect_attempt;

    /// Total number of segments completed since the session started.
    int64_t segments_written;
    /// Segments currently listed in the playlist (the time-shift window).
    int32_t window_segment_count;
    /// Duration in seconds of the time-shift window.
    double window_duration;
    /// Size in bytes of the segments of the window.
    int64_t window_bytes;
    /// SegmentWritten: the media sequence number of the segment (its index in an on-demand playlist).
    int64_t segment_index;

    /// Path of the active (or just closed) recording, or NULL.
    const char *recording_path;
    /// Duration in seconds written to the recording so far.
    double recording_duration;
    /// Bytes written to the recording so far.
    int64_t recording_bytes;

    /// Non-zero once the master playlist (FluxoRemuxHLSOptions.master_playlist_path) is written: the input has
    /// alternative audio tracks or text subtitles, and the player should open the master playlist rather than
    /// the media playlist. It is written with the first segment (its video tells whether the stream carries
    /// CEA-608 closed captions, which the master playlist then declares) and never changes afterwards.
    int32_t master_playlist_written;
    /// Audio tracks offered by the master playlist (0 without one).
    int32_t audio_rendition_count;
    /// Subtitle tracks offered by the master playlist (0 without one).
    int32_t subtitle_rendition_count;
} FluxoRemuxEvent;

/// Called from the engine thread for every event. Must return quickly and must not call fluxo_remux_destroy.
typedef void (*FluxoRemuxEventCallback)(void *context, const FluxoRemuxEvent *event);

/// Options for the HLS output.
typedef struct FluxoRemuxHLSOptions {
    /// Absolute path of the .m3u8 playlist to write.
    const char *playlist_path;
    /// Absolute path prefix of the segments. Segment n is written to "<prefix>-<n>.ts" and the
    /// playlist references it by its file name, so it must be in the playlist's directory.
    const char *segment_path_prefix;
    /// Target segment duration in seconds (segments are cut on video key frames).
    double segment_duration;
    /// Maximum duration in seconds of the time-shift window. 0 means no duration limit.
    /// Not used by on-demand inputs.
    double max_window_duration;
    /// Maximum size in bytes of the segments of the window. 0 means no size limit.
    /// On-demand inputs: the most segment bytes kept on disk (the farthest from the player are deleted).
    int64_t max_window_bytes;
    /// The window never shrinks below this number of segments (default 3).
    int32_t min_window_segments;
    /// Optional absolute path of an HLS master playlist, in the playlist's directory. When it is set and the
    /// input has two audio streams or more, or text subtitles (SubRip, ASS / SSA, WebVTT, timed text), the
    /// engine writes it with one EXT-X-MEDIA rendition per track:
    /// - the media playlist (`playlist_path`) carries the video and the default audio track, which is the
    ///   rendition without a URI; every other audio track gets its own playlist of audio-only segments
    ///   ("<prefix>-a<n>.m3u8", segments "<prefix>-a<n>-<sequence>.ts");
    /// - every text subtitle stream gets a WebVTT playlist ("<prefix>-s<n>.m3u8", segments
    ///   "<prefix>-s<n>-<sequence>.vtt"), cut at the same times as the video.
    /// The renditions carry the language, title, default / forced flags and the accessibility
    /// characteristics (audio description, subtitles for the deaf and hard of hearing) of the input streams.
    /// Bitmap subtitles (DVB, PGS, DVD) and teletext cannot be converted and are not offered.
    /// NULL (or an input with nothing to choose) writes the media playlist only.
    const char *master_playlist_path;
} FluxoRemuxHLSOptions;

/// Configuration of a remux session. All strings are copied by fluxo_remux_create.
typedef struct FluxoRemuxConfig {
    /// Input URL (http, https, udp, file, ...).
    const char *input_url;
    /// Optional User-Agent header for HTTP inputs. May be NULL.
    const char *user_agent;
    /// Maximum time in microseconds a single read/connect may block. 0 uses the engine default.
    int64_t io_timeout_us;
    /// Non-zero for live inputs: the engine reconnects when the input ends or fails.
    /// Zero for on-demand inputs: they are played as a VOD playlist (see fluxo_remux_request_segment).
    int32_t is_live;
    /// On-demand inputs: seconds of media produced ahead of the latest requested segment before the engine
    /// pauses reading (it resumes at half of it). 0 uses the default (60 s).
    double read_ahead_duration;
    /// Consecutive reconnection attempts before giving up. 0 uses the default (10), negative is unlimited.
    int32_t max_reconnect_attempts;
    /// HLS output description.
    FluxoRemuxHLSOptions hls;
} FluxoRemuxConfig;

/// Opaque session handle.
typedef struct FluxoRemuxSession FluxoRemuxSession;

/// Creates a session. Returns NULL on invalid configuration or allocation failure.
/// The callback may be NULL. `context` is passed back unchanged to the callback.
FluxoRemuxSession *fluxo_remux_create(const FluxoRemuxConfig *config, FluxoRemuxEventCallback callback, void *context);

/// Starts remuxing on a dedicated background thread. Returns 0 on success, a negative value otherwise.
/// A session can only be started once.
int32_t fluxo_remux_start(FluxoRemuxSession *session);

/// Requests cancellation. Never blocks; blocking network I/O is aborted through the interrupt callback.
void fluxo_remux_cancel(FluxoRemuxSession *session);

/// Asks the engine to record the stream to `path` (an MPEG-TS file), starting at the next key frame.
/// A running recording is closed first. Never blocks; the result is reported with a Recording event.
/// Returns 0 when the request was queued.
int32_t fluxo_remux_start_recording(FluxoRemuxSession *session, const char *path);

/// Asks the engine to close the active recording, or to drop a queued one that is not open yet.
/// Never blocks; RecordingStopped is reported when done.
void fluxo_remux_stop_recording(FluxoRemuxSession *session);

/// On-demand inputs: tells the engine that the player wants segment `index` of the playlist (the number in
/// its file name). The engine produces it next, seeking the input when it is far from what is being read.
/// `is_rendition`: the segment of an audio or subtitle rendition of the master playlist, which the engine writes
/// with the main segment of the same number; such requests wait for it but never move the reader.
/// Never blocks. Returns 1 when the segment is on disk, 0 when it will be reported by a SegmentWritten
/// event, and a negative value when it will not be produced (no such segment, the input ended before it,
/// or the playlist of this session is not planned on demand).
int32_t fluxo_remux_request_segment(FluxoRemuxSession *session, int64_t index, int32_t is_rendition);

/// Cancels the session, waits for the engine thread to exit and frees every resource.
/// An active recording is closed and its file is complete when this returns.
/// After it returns no further callback is delivered. Must not be called from the callback.
void fluxo_remux_destroy(FluxoRemuxSession *session);

/// Synchronously remuxes a local media file (for example a recording) into another container,
/// chosen from the output file extension (e.g. ".mp4"). Video and audio are copied, timestamps
/// start at zero. On failure the output file is removed and a negative value is returned with a
/// description in `error_message`. `duration_seconds` may be NULL.
int32_t fluxo_remux_convert_file(const char *input_path, const char *output_path, double *duration_seconds,
                                 char *error_message, int32_t error_message_size);

/// Version of the FFmpeg libraries the engine is linked against (e.g. "8.0.1"), for the About screen.
/// The returned string is static and must not be freed.
const char *fluxo_remux_library_version(void);

#ifdef __cplusplus
}
#endif

#endif /* FLUXO_REMUX_ENGINE_H */
